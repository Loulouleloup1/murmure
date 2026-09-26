import Foundation

/// La mesure du critère 9 de la SPEC : « la couverture cumulée des segments est **≥ 97 %** de la
/// durée audio et les horodatages sont **strictement croissants** (début < fin, aucune régression),
/// avec **≥ 1 segment pour 30 s** ». Trois verdicts, un calcul.
///
/// **C'est la mesure, pas la case du document.** ``TranscriptDocument/Coverage`` est la valeur
/// rangée dans le JSON (`coveredSeconds`, `ratio`) ; ce type-ci est le calcul qui la produit, et
/// qui produit en plus les deux autres verdicts du critère. Le seuil (97 %, 1 par 30 s) n'est pas
/// ici : c'est l'appelant (lot 8) qui décide, à partir de ces trois nombres.
///
/// **La couverture est une union d'intervalles, pas une somme de durées.** Deux segments qui se
/// chevauchent couvrent **une fois** la même seconde : les additionner ferait passer le seuil avec
/// deux copies de la moitié de l'audio, c'est-à-dire un faux vert sur le seul critère qui dit si
/// l'audio a été transcrit en entier. Chaque intervalle est borné à `[0, duration]` (un segment qui
/// dépasse la fin de l'audio ne couvre pas plus que l'audio) et `ratio` reste dans `[0, 1]`.
public struct TranscriptCoverage: Equatable {
    /// Secondes effectivement couvertes, divisées par la durée audio. Dans `[0, 1]` ; `0` quand la
    /// durée est nulle (aucune division par zéro).
    public let ratio: Double

    /// Vrai si, **dans l'ordre du document**, chaque segment a `start < end` et si aucun segment ne
    /// commence avant la fin du précédent (`start[i] >= end[i-1]` : deux segments jointifs sont
    /// croissants, un chevauchement est une régression). Une liste vide est vraie **par vacuité** —
    /// rien ne régresse — et c'est `ratio` qui dit alors qu'il n'y a rien à couvrir.
    public let isMonotonic: Bool

    /// Nombre de segments par tranche de 30 s : `segments.count / (duration / 30)`. `0` quand la
    /// durée est nulle. Le critère 9 demande **≥ 1**, c'est-à-dire au moins un segment par demi-
    /// minute sur toute la durée.
    public let segmentsPer30s: Double

    public init(ratio: Double, isMonotonic: Bool, segmentsPer30s: Double) {
        self.ratio = ratio
        self.isMonotonic = isMonotonic
        self.segmentsPer30s = segmentsPer30s
    }

    /// Mesure un transcript : les segments du document et la durée annoncée de l'audio source.
    ///
    /// L'ordre des segments compte pour ``isMonotonic`` (c'est l'ordre du document, tel qu'il est
    /// écrit sur disque) et **ne compte pas** pour `ratio` ni pour `segmentsPer30s`, qui sont des
    /// propriétés de l'ensemble.
    public static func of(segments: [TranscriptSegment], duration: Double) -> TranscriptCoverage {
        // Les deux verdicts qui ne dépendent pas de la durée sont calculés d'abord : une durée
        // nulle rend `0` pour les mesures, jamais `NaN`, mais un document sans audio n'est pas
        // pour autant un document croissant.
        let croissant = estCroissant(segments)
        guard duration > 0 else {
            return TranscriptCoverage(ratio: 0, isMonotonic: croissant, segmentsPer30s: 0)
        }
        // Borné à `[0, 1]` : la mesure est ce que l'appelant (lot 8) compare à 97 %, elle ne doit
        // pas pouvoir sortir de l'intervalle qu'elle prétend mesurer.
        let ratio = min(max(couvert(segments, sur: duration) / duration, 0), 1)
        return TranscriptCoverage(
            ratio: ratio,
            isMonotonic: croissant,
            segmentsPer30s: Double(segments.count) / (duration / 30))
    }

    /// Vrai si **dans l'ordre du document** chaque segment a `start < end` et si aucun ne commence
    /// avant la fin du précédent. Une liste vide passe par vacuité.
    private static func estCroissant(_ segments: [TranscriptSegment]) -> Bool {
        var finPrecedente = -Double.infinity
        for segment in segments {
            // `start >= finPrecedente` et non `>` : deux segments **jointifs** ne régressent pas —
            // c'est le cas normal d'un découpage en unités, et le refuser ferait échouer le
            // critère 9 sur toute transcription un peu longue.
            guard segment.start < segment.end, segment.start >= finPrecedente else { return false }
            finPrecedente = segment.end
        }
        return true
    }

    /// La longueur de l'**union** des intervalles, chacun borné à `[0, borne]`.
    ///
    /// Le tri par début puis la fusion sont ce qui fait la différence entre cette fonction et une
    /// somme de durées : une seconde couverte par deux segments est comptée une fois. Un segment
    /// qui commence après la fin de l'audio ne couvre rien du tout (intervalle vide, écarté).
    private static func couvert(_ segments: [TranscriptSegment], sur borne: Double) -> Double {
        let intervalles =
            segments
            .map { (debut: max($0.start, 0), fin: min($0.end, borne)) }
            .filter { $0.debut < $0.fin }
            .sorted { $0.debut < $1.debut }

        var total = 0.0
        var debutCourant = 0.0
        var finCourante = 0.0
        var ouvert = false
        for intervalle in intervalles {
            guard ouvert else {
                (debutCourant, finCourante, ouvert) = (intervalle.debut, intervalle.fin, true)
                continue
            }
            if intervalle.debut > finCourante {
                // Trou : l'intervalle précédent est clos, celui-ci en ouvre un autre.
                total += finCourante - debutCourant
                (debutCourant, finCourante) = (intervalle.debut, intervalle.fin)
            } else {
                // Chevauchement (ou jointure) : l'intervalle courant étend le précédent, sans
                // compter deux fois la partie commune.
                finCourante = max(finCourante, intervalle.fin)
            }
        }
        if ouvert { total += finCourante - debutCourant }
        return total
    }
}
