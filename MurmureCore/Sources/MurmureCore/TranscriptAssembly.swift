import Foundation

/// Une unité transcrite : sa frontière **absolue** (celle que le plan de morceaux a produite) et
/// ses segments **locaux**, horodatés depuis le début de l'unité — c'est la forme sous laquelle
/// WhisperKit les rend, puisque chaque unité est un appel `transcribe` séparé sur son propre WAV.
///
/// Ce type est le seul transport entre le moteur (lot 8) et l'assemblage : il ne porte aucune
/// décision, il transporte.
public struct TranscribedUnit: Equatable {
    /// La frontière de l'unité, telle que ``VideoTranscriptionPlan`` l'a calculée.
    public var boundary: UnitBoundary
    /// Les segments **locaux** de cette unité (0 = début de l'unité).
    public var segments: [TranscriptSegment]

    public init(boundary: UnitBoundary, segments: [TranscriptSegment]) {
        self.boundary = boundary
        self.segments = segments
    }
}

/// L'assemblage des unités transcrites en un seul flux **absolu** (plan §2.1 et §4 lot 3).
///
/// **Pourquoi ce type existe.** Chaque unité est transcrite séparément, donc horodatée depuis son
/// propre début ; et à la frontière, WhisperKit rend au début d'une unité la phrase qu'il vient de
/// rendre à la fin de la précédente (il n'a plus le contexte de l'unité d'avant, il repart de son
/// chevauchement). Sans ce recollage, le JSON livré à l'agent aurait des horodatages qui repartent
/// de zéro toutes les 5 min et des phrases en double.
///
/// **Règles gelées par le contrat (carte QA L3)** :
///
/// 1. `horodatage absolu = début de l'unité + horodatage local` (règle du plan §2.1). Le début
///    d'unité vient de ``VideoTranscriptionPlan``, il est donc échantillon-exact.
/// 2. La sortie est **triée par début absolu** et **strictement croissante** : chaque segment
///    vérifie `start < end`, et le `start` d'un segment est strictement supérieur à celui du
///    précédent. Aucune régression, donc : c'est l'invariant du critère 9.
/// 3. **Dédoublonnage aux frontières, avec une tolérance mesurée.** Deux segments dont les
///    intervalles absolus se chevauchent (`a.start < b.end && b.start < a.end`) ne sont *la même
///    phrase rendue deux fois* **que si le chevauchement atteint la tolérance**
///    (``chevauchementEcartMinimal``, `1,0 s`) : au-delà, le premier est gardé et le second est
///    écarté **dans son entier** (aucun rognage du texte, aucune concaténation). En deçà, ce n'est
///    pas un doublon mais un **raccord** — WhisperKit horodate deux segments voisins à quelques
///    microsecondes près — et écarter le second jette tout son contenu. Le second est alors
///    **gardé** et **rogné à `dernier.end`** : le texte reste entier, seul le début se décale de
///    moins que la tolérance ; s'il ne reste rien (`start >= end`), il n'est pas rendu (règle 4).
///    Le résultat ne contient donc **aucune paire de segments qui se chevauchent**.
///
///    *Amendement de la règle (carte QA `t_f53c4c72`, 2026-09-23), levé par la mesure.* Le texte
///    précédent, **gelé par le contrat du lot 3** (blob git `edfb0eedac1e8e353598a85459d978970119e994`,
///    sha256 `068e391bda337a0aa3a683d647dea142658a20f0fa2819954f59559789377bca`), disait : « Deux
///    segments dont les intervalles absolus se chevauchent sont la même phrase rendue deux fois :
///    **le premier est gardé, le second est écarté**, dans son entier (aucun rognage, aucune
///    concaténation de textes). » Sur les **cinq** passes **lien** de la vidéo A du plan
///    (`NwGHNdbw1Ts`, 2 292,544 s, `openai_whisper-large-v3-v20240930_turbo` — les quatre de la
///    carte `t_435e50b8` et `f53-p1`, rejouée par cette carte), cette règle **écartait 13
///    segments** par passe sur des chevauchements de **3,8 × 10⁻⁶ à 3,1 × 10⁻⁵ s** et laissait
///    **13 trous ≥ 1,0 s**, aux **mêmes bornes** dans les cinq passes, pour **45,939812 s** en
///    tout. Le rognage prescrit ci-dessous en récupère **45,099831 s** et la couverture passe de
///    0,967310 / 0,967327 / 0,967449 / 0,967458 / 0,966394 à
///    0,986982089 / 0,986999540 / 0,987121677 / 0,987130403 / 0,986066082 — ≈ **1,97 point**.
///    Les **0,839981 s** qui restent ouverts sont le bord droit de chaque trou, que le raccord ne
///    couvre pas : c'est pourquoi ces cinq couvertures ne sont pas celles qu'on obtiendrait « tous
///    les trous refermés » (2,004 points). Les **5 autres** segments écartés (chevauchements de
///    1,82 à 4,50 s) ne coûtaient **rien** : leur intervalle était **entièrement contenu** dans le
///    segment gardé. La tolérance
///    sépare donc deux populations mesurées, séparées d'un facteur ≈ 58 000, et elle ne change
///    **pas** le dédoublonnage des frontières, qui reste intact au-dessus d'elle (le texte d'une
///    phrase rendue deux fois n'est jamais dupliqué).
/// 4. **Cas dégénérés.** Un segment de durée nulle ou négative n'est pas rendu : il ne peut pas
///    satisfaire `start < end`. Un segment dont le texte est vide *est* rendu (c'est une pause, pas
///    une erreur). Une liste d'unités vide rend une liste vide — un travail interrompu avant sa
///    première unité reste assemblable.
public enum TranscriptAssembly {
    /// La **tolérance de la règle 3** : en deçà, un recouvrement n'est pas un doublon mais un
    /// **raccord** (deux segments voisins que WhisperKit horodate à quelques microsecondes près).
    /// Le segment est alors gardé et rogné, jamais écarté en entier.
    ///
    /// **Valeur mesurée, pas choisie** (carte QA `t_f53c4c72`) : sur les cinq passes **lien** de
    /// la vidéo A, les chevauchements réellement écartés par la règle 3 se répartissent en deux
    /// populations séparées d'un facteur ≈ 58 000 — **13** chevauchements de 3,8 × 10⁻⁶ à
    /// 3,1 × 10⁻⁵ s (ils laissaient **13 trous ≥ 1,0 s**, **45,939812 s** au total, dont le raccord
    /// récupère **45,099831 s**) et **5** de 1,82 à 4,50 s (ils ne coûtaient **rien** : segment
    /// entièrement contenu dans le segment gardé). `1,0 s` tombe entre les deux, et c'est elle qui
    /// fait repasser la couverture du critère 9 (97 %) au-dessus du seuil : après correction, le
    /// **plus grand trou** vaut **0,800003 s** dans quatre passes et **1,040000 s** dans `f53-p1`
    /// (son trou **naturel** de `[13,120000 → 14,160000)`, que cette correction ne referme pas).
    public static let chevauchementEcartMinimal: Double = 1.0

    /// Les segments **absolus** de toutes les unités, recollés dans l'ordre.
    ///
    /// - Parameter units: les unités transcrites, dans l'ordre du plan.
    /// - Returns: les segments absolus, strictement croissants, sans chevauchement (règles 2 et 3).
    public static func merge(units: [TranscribedUnit]) -> [TranscriptSegment] {
        // 1. Passage en absolu : `début d'unité + horodatage local` (règle 1). Un segment de durée
        //    nulle ou négative ne peut pas satisfaire `start < end` : il n'est pas rendu (règle 4).
        var absolus: [TranscriptSegment] = []
        for unite in units {
            for segment in unite.segments {
                let debut = unite.boundary.start + segment.start
                let fin = unite.boundary.start + segment.end
                guard fin > debut else { continue }
                absolus.append(TranscriptSegment(start: debut, end: fin, text: segment.text))
            }
        }

        // 2. Tri par début absolu (règle 2), puis un seul passage : le premier arrivé gagne.
        absolus.sort { $0.start < $1.start }

        var rendus: [TranscriptSegment] = []
        for segment in absolus {
            if let dernier = rendus.last {
                // Débuts strictement croissants : deux segments au même début sont la même phrase.
                guard segment.start > dernier.start else { continue }
                guard segment.start >= dernier.end else {
                    let chevauchement = dernier.end - segment.start
                    guard chevauchement < chevauchementEcartMinimal else { continue }

                    // Raccord temporel : le texte reste entier, seul le début est rogné pour
                    // conserver l'invariant « aucune paire de segments qui se chevauchent ».
                    guard segment.end > dernier.end else { continue }
                    rendus.append(
                        TranscriptSegment(start: dernier.end, end: segment.end, text: segment.text))
                    continue
                }
            }
            rendus.append(segment)
        }
        return rendus
    }
}
