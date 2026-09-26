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
/// 3. **Dédoublonnage aux frontières.** Deux segments dont les intervalles absolus se chevauchent
///    (`a.start < b.end && b.start < a.end`) sont la même phrase rendue deux fois : **le premier
///    est gardé, le second est écarté**, dans son entier (aucun rognage, aucune concaténation de
///    textes). Le résultat ne contient donc **aucune paire de segments qui se chevauchent**.
/// 4. **Cas dégénérés.** Un segment de durée nulle ou négative n'est pas rendu : il ne peut pas
///    satisfaire `start < end`. Un segment dont le texte est vide *est* rendu (c'est une pause, pas
///    une erreur). Une liste d'unités vide rend une liste vide — un travail interrompu avant sa
///    première unité reste assemblable.
public enum TranscriptAssembly {
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
                // Dédoublonnage à la frontière (règle 3) — le premier gardé, le second écarté.
                guard segment.start >= dernier.end else { continue }
            }
            rendus.append(segment)
        }
        return rendus
    }
}
