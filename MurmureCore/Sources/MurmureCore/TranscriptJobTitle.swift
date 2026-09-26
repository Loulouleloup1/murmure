import Foundation

/// **La décision pure qui fait que le titre de la source atteint le document** (plan §2.4 et §4 lot
/// 8-T, révision 11 ; défaut **constaté** par la carte DEV L10 `t_c17a5c14`, suivi `t_5870ffb6`).
///
/// **Le défaut constaté, et ce qu'il coûte.** `AcquisitionService.Acquired.metadata` porte le titre
/// `yt-dlp` (lot 4 : « le titre tel qu'il a été écrit — celui des tuiles et de l'en-tête Markdown »)
/// et **rien ne le lit** : `TranscriptJobRunner` écrit le document avec le titre que l'**appelant**
/// lui a donné, et pour un lien l'appelant n'en a aucun — il passe la chaîne vide, parce qu'au
/// moment où la file reçoit le travail, l'acquisition n'a pas encore tourné. Conséquences : la
/// **tuile** n'a pas de titre (critère 16), le corps de la notification de fin est **vide**
/// (critère 18), et la tige tombe sur le repli « identité » du §2.4 au lieu du slug du titre. Le
/// trou est resté invisible parce que **toutes** les passes du chantier ont tourné sur un **fichier
/// local**, où le titre de l'appelant *est* le titre de la source.
///
/// **La décision, et ce qu'elle n'est pas.** Le titre est celui de la **source**, lu **là où elle le
/// porte**, et il est décidé **une seule fois** : ce type ne connaît ni le disque, ni `yt-dlp`, ni la
/// file, ni la date, ni le journal — il prend trois titres candidats et en rend un. C'est ce qui le
/// rend testable, et c'est pour cela que la carte `qa` le gèle avant que la carte `dev` ne
/// l'implémente (règles 1 à 5 du §7.1).
///
/// **L'ordre est un contrat** (§2.4, révision 10) :
/// 1. `resumed` — le titre du **document reprisable** quand il en porte un : une reprise garde son
///    titre (c'est l'ancre du §2.4, et la règle 1 de « Collisions » fige la tige de toute façon) ;
/// 2. `acquisition` — `YtDlpMetadata.title` : c'est la source qui porte le titre d'un **lien** ;
/// 3. `caller` — le titre de l'appelant : c'est la source qui porte le titre d'un **fichier local**
///    (son nom).
///
/// **Un titre vide ou blanc n'est pas un titre** : il vaut **absent** (même règle que `stem`, §2.4),
/// donc une reprise dont le document porte un titre blanc **le remplit** — sans changer de tige —, et
/// un titre d'acquisition blanc laisse la main à l'appelant. Si aucun des trois n'en porte, le titre
/// est la **chaîne vide** : on n'invente aucun mot (règle du lot 10), le repli nomme le fichier et la
/// notification reste sans corps. Le titre rendu n'est **pas rogné** : c'est le texte de la source,
/// tel quel.
///
/// **Contrat gelé** (carte QA L8-T `t_ddc71a45`) :
/// 1. l'ordre (1) (2) (3) est **strict** : un titre d'acquisition prime sur un titre d'appelant, même
///    quand les deux sont présents et **différents**
///    (`(resumed: nil, acquisition: "Titre officiel", caller: "Autre titre")` → `"Titre officiel"`) ;
/// 2. `nil` et une chaîne vide **ou blanche** sont **la même absence**, et cela vaut pour les trois
///    paramètres : un candidat absent ne fait pas écran au suivant
///    (`(resumed: nil, acquisition: " ", caller: "ma-réunion")` → `"ma-réunion"`) ;
/// 3. aucun des trois ne porte de titre → la **chaîne vide**
///    (`(resumed: nil, acquisition: " ", caller: "")` → `""`) : aucun mot n'est inventé ici, et le
///    repli (nom du fichier, notification sans corps) reste la décision de l'appelant ;
/// 4. le titre rendu est **exactement** la chaîne retenue, espaces compris — il n'est ni rogné, ni
///    normalisé, ni replié.
public enum TranscriptJobTitle {
    /// Le titre du document, tel que la **source** le porte.
    ///
    /// Voir le contrat du type pour l'ordre (reprise → acquisition → appelant), pour le titre vide ou
    /// blanc qui vaut absent, et pour la chaîne vide quand aucun des trois n'en porte. L'appelant du
    /// lot 8-T (`TranscriptJobRunner`) résout le titre **une seule fois**, après
    /// `AcquisitionService.acquire`, et le passe aux écritures du document.
    ///
    /// - Parameters:
    ///   - resumed: le titre du document reprisable de la même identité canonique — `nil` quand il n'y
    ///     a pas de reprise, ou quand le document reprisable n'a pas de titre.
    ///   - acquisition: `YtDlpMetadata.title` de l'acquisition — `nil` pour un **fichier local**, qui
    ///     n'a pas de métadonnée de source.
    ///   - caller: le titre de l'appelant — le nom du fichier pour un **local**, la chaîne vide pour
    ///     un **lien** (la surface de lancement ne connaît pas encore le titre de la source).
    /// - Returns: le titre de la source, ou la chaîne vide si aucun des trois n'en porte.
    public static func resolve(resumed: String?, acquisition: String?, caller: String) -> String {
        // Les trois candidats dans l'ordre du contrat, et **un seul** parcours : l'absence d'un
        // candidat (nil, vide, ou blanc) ne fait pas écran au suivant, et le premier qui porte un
        // titre est celui qui est rendu. Le test de blancheur est fait sur une copie rognée — le
        // titre **rendu**, lui, ne l'est pas : rogner réécrirait le titre de la source, donc la
        // tuile (critère 16) et l'en-tête Markdown ne porteraient plus ce que `yt-dlp` a écrit.
        for candidat in [resumed, acquisition, caller] {
            guard let candidat else { continue }
            if !candidat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidat
            }
        }
        // Aucun des trois n'en porte : la chaîne vide. On n'invente aucun mot — le repli (le nom du
        // fichier, la notification sans corps) est la décision de l'appelant.
        return ""
    }
}
