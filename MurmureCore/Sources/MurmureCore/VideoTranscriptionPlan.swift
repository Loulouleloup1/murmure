import Foundation

/// La frontière d'une unité transcrite : le type déjà gelé par le document JSON
/// (`boundaries[{start,duration,quality}]`, plan §2.4) est **réutilisé tel quel** plutôt que
/// redupliqué. Il n'existe donc qu'une seule forme de frontière dans le module — ce que le plan de
/// morceaux produit est exactement ce que le fichier écrit, et `quality` garde les deux valeurs
/// brutes (`silence`, `forced`) que le plan nomme.
public typealias UnitBoundary = TranscriptDocument.Boundary

/// Le plan de morceaux d'une transcription longue (plan §2.1 et §4 lot 3).
///
/// **Pourquoi ce type existe.** WhisperKit n'a **aucune** API de pause/reprise, et `clipTimestamps`
/// est explicitement refusé sous `.incremental` : on ne peut pas chercher dans un flux. La reprise
/// se fait donc sur des **unités** découpées par Murmure et transcrites une par une — c'est ce qui
/// borne la mémoire (critère 10) et ce qui rend un travail interrompu reprenable (critère 9). Où
/// couper est une décision **pure**, sans entrée/sortie : elle vit ici, pas dans le moteur (lot 8),
/// et c'est précisément ce qui la rend testable.
///
/// **Règles gelées par le contrat (carte QA L3)** :
///
/// 1. **Pas nominal.** Une unité vise `nominal` secondes — 300 s par défaut, les 5 min du plan
///    §2.1, mesurées au lot 0. `nominal` est un paramètre : le lot 0 doit pouvoir re-mesurer le pas
///    sans qu'une signature change.
/// 2. **Où sont les coupes.** Une coupe est cherchée à **chaque multiple du pas strictement
///    inférieur à `duration`** (300, 600, … pour 4 h). Le multiple égal à `duration` n'est pas une
///    coupe : c'est la fin du fichier.
/// 3. **Coupe dans un silence.** Parmi les silences à **au plus `silenceTolerance`** (30 s) du
///    multiple, le plus proche — à égalité de distance, celui qui commence le plus tôt. La coupe
///    est le point de ce silence **le plus proche du multiple**, c'est-à-dire le multiple lui-même
///    s'il tombe dans le silence : la coupe est déplacée du minimum nécessaire, jamais posée à
///    l'aveugle sur un bord. `quality` vaut alors `.silence`.
///    Un silence est un intervalle **fermé** `[début, fin]` en secondes de l'audio décodé ; le lot
///    7 (`SilenceMap`) en est la source, et le lot 7 détecte ces silences sur le WAV 16 kHz mono.
/// 4. **Sinon, coupe forcée.** Exactement au multiple, `quality` = `.forced`, et c'est la
///    dégradation assumée du plan : aucune seconde n'est perdue, la coupe tombe au mauvais endroit,
///    et `forced` la rend trouvable après coup par un contrôle qualité.
/// 5. **Échantillon-exactitude.** Toute coupe est ramenée à l'**échantillon le plus proche** de la
///    grille `sampleRate` (16 kHz mono : le plan §2.1 coupe le WAV décodé, jamais la source
///    compressée, sinon la dérive s'accumulerait sur 48 unités). Conséquence, et c'est la
///    propriété que le lot 8 utilisera pour recoller les horodatages : `start` et `duration` sont
///    des multiples entiers de `1 / sampleRate`, et le `start` d'une unité vaut **la somme des
///    durées précédentes**, à l'échantillon près.
/// 6. **Qualité d'une unité = qualité de sa fin.** La dernière unité se termine sur la fin du
///    fichier et non sur une coupe : elle est donc marquée `.forced`. Un audio de 4 h **sans aucun
///    silence** donne ainsi 48 unités, **toutes** `forced`, et aucune seconde perdue.
/// 7. **Cas courts.** `duration <= 0` → aucun morceau. Durée inférieure au pas → **un seul**
///    morceau, de 0 à `duration`, forcé (il n'y a pas de coupe à chercher).
public enum VideoTranscriptionPlan {
    /// Le pas nominal par défaut, en secondes : 5 min (plan §2.1, mesuré au lot 0).
    public static let nominalStep: Double = 300

    /// La tolérance de recherche d'un silence autour d'un multiple du pas, en secondes : ± 30 s.
    public static let silenceTolerance: Double = 30

    /// La fréquence du WAV décodé sur lequel la coupe est faite : 16 kHz mono (plan §2.1), donc
    /// 1/16 000 s est la plus petite frontière représentable.
    public static let sampleRate: Double = 16_000

    /// Les morceaux d'un audio de `duration` secondes, dans l'ordre, contigus et complets.
    ///
    /// - Parameters:
    ///   - duration: la durée de l'audio **décodé**, en secondes.
    ///   - silences: les intervalles `[début, fin]` sans parole, en secondes, dans n'importe quel
    ///     ordre (lot 7).
    ///   - nominal: le pas visé, en secondes (voir règle 1).
    /// - Returns: les frontières des unités, dans l'ordre : `start = 0` pour la première, et
    ///   `start` de chacune égal à `start + duration` de la précédente (règle 5).
    public static func units(
        duration: Double,
        silences: [ClosedRange<Double>],
        nominal: Double = VideoTranscriptionPlan.nominalStep
    ) -> [UnitBoundary] {
        guard duration > 0, nominal > 0 else { return [] }

        // Chaque frontière est ramenée à la grille d'échantillons (règle 5). `duration` n'est
        // jamais arrondie : c'est la dernière unité qui absorbe l'écart, donc la somme des durées
        // vaut la durée totale **exactement**, pas à un échantillon près.
        func surLaGrille(_ temps: Double) -> Double {
            (temps * sampleRate).rounded() / sampleRate
        }

        // Les coupes visées : les multiples du pas **strictement** inférieurs à la durée (règle 2).
        var cibles: [Double] = []
        var multiple = nominal
        while multiple < duration {
            cibles.append(multiple)
            multiple += nominal
        }

        let tries = silences.sorted { $0.lowerBound < $1.lowerBound }
        let unEchantillon = 1 / sampleRate

        var unites: [UnitBoundary] = []
        var debut = 0.0
        for cible in cibles {
            // Le silence le plus proche de la cible, à `silenceTolerance` près (règle 3).
            var meilleur: (distance: Double, coupe: Double)? = nil
            for silence in tries {
                let distance: Double
                let point: Double
                if cible < silence.lowerBound {
                    point = silence.lowerBound
                    distance = silence.lowerBound - cible
                } else if cible > silence.upperBound {
                    point = silence.upperBound
                    distance = cible - silence.upperBound
                } else {
                    point = cible
                    distance = 0
                }
                guard distance <= silenceTolerance else { continue }
                let coupe = surLaGrille(point)
                // Une coupe doit être un vrai point de séparation : après le début de l'unité en
                // cours et avant la fin du fichier. Un silence qui déborde de la fin est écarté,
                // pas rabattu sur la fin (cela produirait une unité de durée nulle).
                guard coupe > debut, coupe < duration else { continue }
                // À distance égale, le silence qui commence le plus tôt : `tries` est trié par
                // début et on ne remplace que sur une distance **strictement** plus petite.
                if meilleur == nil || distance < meilleur!.distance {
                    meilleur = (distance, coupe)
                }
            }

            let fin: Double
            let quality: UnitBoundary.Quality
            if let meilleur {
                fin = meilleur.coupe
                quality = .silence
            } else {
                // Aucun silence à portée : coupe forcée exactement au multiple (règle 4), et
                // marquée, pour rester trouvable après coup.
                fin = surLaGrille(cible)
                guard fin > debut, fin < duration else { continue }
                quality = .forced
            }
            unites.append(UnitBoundary(start: debut, duration: fin - debut, quality: quality))
            debut = fin
        }

        // La dernière unité va du dernier point de séparation à la fin du fichier : elle ne coupe
        // rien, donc elle est `.forced` (règle 6).
        if duration - debut > unEchantillon / 2 {
            unites.append(
                UnitBoundary(start: debut, duration: duration - debut, quality: .forced))
        }
        return unites
    }
}
