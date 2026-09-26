import XCTest
@testable import MurmureCore

/// Contrat rouge du lot **8-T** : **le titre de la source atteint le document** (plan §2.4 et §4 lot
/// 8-T, révision 11 ; suivi `t_5870ffb6`, défaut constaté par la carte DEV L10 `t_c17a5c14`).
///
/// **Le défaut constaté que ce fichier rend impossible.** `AcquisitionService.Acquired.metadata` porte
/// le titre `yt-dlp` (lot 4 : « le titre tel qu'il a été écrit — celui des tuiles et de l'en-tête
/// Markdown ») et **rien ne le lit** : `TranscriptJobRunner` écrit le document avec le titre que
/// l'**appelant** lui a donné — vide pour un lien, parce qu'au moment où la file reçoit le travail,
/// l'acquisition n'a pas encore tourné. Conséquences mesurées sur la chaîne : tuile sans titre
/// (critère 16), corps de la notification de fin **vide** (critère 18), tige tombée sur le repli
/// « identité » du §2.4. Le trou est resté invisible parce que **toutes** les passes du chantier ont
/// tourné sur un **fichier local**, où le titre de l'appelant *est* le titre de la source. La décision
/// est **pure** et vit dans le cœur (`TranscriptJobTitle`, cible testable) ; la cible app n'a pas de
/// bundle de tests.
///
/// **Ce que ces cas gèlent, un par point du contrat** (a → g) :
/// - **(a)** un **lien** prend le titre de l'**acquisition** — c'est la source qui le porte, et la
///   chaîne vide de l'appelant ne doit pas l'emporter ;
/// - **(b)** l'ordre **(2) acquisition avant (3) appelant** est **strict** : quand les deux portent un
///   titre différent, c'est celui de l'acquisition — jamais « le dernier qui parle » ;
/// - **(c)** un **fichier local** garde le titre de son **appelant** (son nom) : aucun `yt-dlp` n'a
///   tourné, il n'y a pas de métadonnée de source ;
/// - **(d)** une **reprise garde le titre de son document** — c'est l'ancre du §2.4, et la règle 1 de
///   « Collisions » fige la tige de toute façon ;
/// - **(e)** un titre de reprise **blanc** vaut absent : la reprise **se remplit** (de la vidéo, sinon
///   de l'appelant) **sans changer de tige** — c'est ce qui distingue « absent » de « présent » ;
/// - **(f)** un titre d'acquisition **blanc** ne fait pas écran au candidat suivant, et quand **aucun**
///   des trois n'en porte, la fonction rend la **chaîne vide** : on n'invente aucun mot (règle du
///   lot 10), le repli reste la décision de l'appelant ;
/// - **(g)** le titre rendu **n'est pas rogné** : c'est le texte de la source, tel quel (§2.4 :
///   « Le titre rendu n'est pas rogné »). Cas **ajouté** par la carte QA L8-T — les six cas de la
///   carte sont obligatoires, celui-ci gèle la dernière clause du contrat du point 1, qui n'aurait
///   sinon aucun test (le rognage est l'implémentation naturelle et fausse).
///
/// **Chaque cas porte au moins un contrôle positif.** Un cas dont la seule assertion attendue est
/// `""` serait **vert** sur le corps sentinelle (`return ""`) : le cas (f) est exactement celui-là, et
/// ses deux contrôles positifs sont écrits dans le même test (un titre réel rendu, et le passage au
/// candidat suivant après un titre blanc).
///
/// **Forme (règles 1 à 4 du §7.1).** Le rouge est prouvé par des **assertions explicites avec
/// message** — jamais par une erreur de compilation (un fichier de tests non compilable casserait la
/// gate `swift test` de *toutes* les cartes), jamais par un `skip`, jamais par un
/// `expectedFailure`. La carte `dev` remplace le corps sentinelle de
/// ``TranscriptJobTitle/resolve(resumed:acquisition:caller:)`` **sans toucher à la signature**
/// (règle 5) : si la signature ne va pas, le contrat revient au `qa`.
final class TranscriptJobTitleTests: XCTestCase {
    private let contrat = "contrat lot 8-T : non implémenté"

    /// Le titre réel de la source de la vidéo A du plan, tel que `yt-dlp` le rend (le m4a du dépôt le
    /// porte dans son nom : `Apple doit arrêter ça. [NwGHNdbw1Ts].m4a`) — le cas mesuré du lot.
    private let titreDeLaVideoA = "Apple doit arrêter ça."

    /// Le nom de fichier d'un local, avec son date-stamp : c'est le titre de l'appelant d'un fichier
    /// local, et il **diffère** du titre de source d'un lien (c'est ce qui a masqué le défaut).
    private let titreDUnLocal = "ma-réunion-2026-09-22"

    // MARK: - (a) Un lien prend le titre de l'acquisition

    /// Le cas du défaut : pour un lien, l'appelant n'a **aucun** titre et passe la chaîne vide. Le
    /// titre que le document doit porter est celui que l'acquisition a lu dans la **même** invocation
    /// que l'audio — sans quoi la tuile est sans titre (critère 16) et la notification est muette
    /// (critère 18).
    func testUnLienPrendLeTitreDeLAcquisition() {
        XCTAssertEqual(
            TranscriptJobTitle.resolve(
                resumed: nil, acquisition: titreDeLaVideoA, caller: ""),
            titreDeLaVideoA,
            "\(contrat) — le titre d'un lien est celui de l'acquisition, jamais la chaîne vide de l'appelant")
    }

    // MARK: - (b) Le titre de l'appelant ne prime jamais sur l'acquisition d'un lien

    /// L'ordre **(2) avant (3)** est un contrat, pas une commodité : quand l'appelant porte un titre
    /// (par exemple le nom d'un fichier téléchargé, ou une surface qui croit connaître la source) et
    /// que l'acquisition en porte un autre, c'est **celui de la source** qui est écrit.
    func testLeTitreDeLAppelantNePrimeJamaisSurLAcquisitionDUnLien() {
        XCTAssertEqual(
            TranscriptJobTitle.resolve(
                resumed: nil, acquisition: "Titre officiel", caller: "Autre titre"),
            "Titre officiel",
            "\(contrat) — l'acquisition (2) prime sur l'appelant (3), même quand les deux portent un titre")
    }

    // MARK: - (c) Un fichier local garde le titre de son appelant

    /// Un local n'a **pas** de métadonnée de source (`acquisition: nil`) : son titre est le nom du
    /// fichier, c'est-à-dire le titre de l'appelant. C'est le seul cas que le chantier exerçait, et
    /// c'est pourquoi il est gelé séparément du cas (a).
    func testUnFichierLocalGardeLeTitreDeSonAppelant() {
        XCTAssertEqual(
            TranscriptJobTitle.resolve(resumed: nil, acquisition: nil, caller: titreDUnLocal),
            titreDUnLocal,
            "\(contrat) — un local prend le titre de son appelant, et il n'est pas rogné")
    }

    // MARK: - (d) Une reprise garde le titre de son document

    /// L'ancre du §2.4 : une reprise **reprend le document tel qu'il est**, titre compris. Le titre de
    /// la vidéo ne l'écrase pas — une reprise de lien relancée après une mise à jour du titre `yt-dlp`
    /// ne doit pas renommer le document sous la tige qui l'ancre (règle 1 de « Collisions »).
    func testUneRepriseGardeLeTitreDeSonDocument() {
        XCTAssertEqual(
            TranscriptJobTitle.resolve(
                resumed: "Titre d'origine", acquisition: "Titre de la vidéo", caller: ""),
            "Titre d'origine",
            "\(contrat) — une reprise garde le titre de son document : (1) prime sur (2) et (3)")
    }

    // MARK: - (e) Une reprise au titre blanc se remplit sans changer de tige

    /// **Vide ou blanc vaut absent** : un document reprisable qui porte un titre blanc (cf. le défaut :
    /// toutes les passes liens ont écrit `""`) n'est **pas** une source de titre. La reprise se
    /// **remplit** alors — de l'acquisition pour un lien, de l'appelant pour un local — et c'est le
    /// même document, sous la **même tige** : la règle 1 de « Collisions » ancre la reprise sur la
    /// tige du document reprisable, indépendamment de son titre.
    func testUneRepriseAuTitreBlancSeRemplitSansChangerDeTige() {
        XCTAssertEqual(
            TranscriptJobTitle.resolve(
                resumed: "   ", acquisition: "Titre de la vidéo", caller: ""),
            "Titre de la vidéo",
            "\(contrat) — un titre de reprise blanc vaut absent : la reprise se remplit de l'acquisition")

        XCTAssertEqual(
            TranscriptJobTitle.resolve(resumed: "", acquisition: nil, caller: titreDUnLocal),
            titreDUnLocal,
            "\(contrat) — un titre de reprise blanc laisse la main à l'appelant (local)")
    }

    // MARK: - (f) Aucun titre n'est inventé

    /// Quand **aucun** des trois candidats ne porte de titre, la fonction rend la **chaîne vide** :
    /// elle n'invente aucun mot (règle du lot 10) et ne choisit pas de repli — le repli nomme le
    /// fichier, et la notification reste sans corps.
    ///
    /// **Deux contrôles positifs dans le même test**, parce que l'assertion attendue est `""` — c'est
    /// exactement ce que le corps sentinelle rend : sans eux, ce cas serait **vert** sans
    /// implémentation. Le premier montre qu'un titre réel est rendu (le corps sentinelle est rouge) ;
    /// le second montre qu'un titre d'acquisition **blanc** ne fait pas écran au candidat suivant — un
    /// `acquisition ?? caller` naïf rendrait `" "` ici.
    func testAucunTitreNEstInvente() {
        XCTAssertEqual(
            TranscriptJobTitle.resolve(resumed: nil, acquisition: " ", caller: ""),
            "",
            "\(contrat) — aucun titre chez les trois candidats : la chaîne vide, jamais un mot inventé")

        // Contrôle positif 1 — le même appel, avec un titre réel : il doit être rendu tel quel.
        XCTAssertEqual(
            TranscriptJobTitle.resolve(resumed: nil, acquisition: titreDeLaVideoA, caller: ""),
            titreDeLaVideoA,
            "\(contrat) — contrôle positif : la fonction rend bien un titre quand il y en a un")

        // Contrôle positif 2 — un titre d'acquisition blanc est **absent**, donc le candidat suivant
        // (3) est examiné : c'est la même règle « vide ou blanc vaut absent », côté acquisition.
        XCTAssertEqual(
            TranscriptJobTitle.resolve(resumed: nil, acquisition: " ", caller: titreDUnLocal),
            titreDUnLocal,
            "\(contrat) — contrôle positif : un titre d'acquisition blanc laisse la main à l'appelant")
    }

    // MARK: - (g) Le titre rendu n'est pas rogné

    /// §2.4 : « Le titre rendu n'est pas rogné : c'est le texte de la source, tel quel. » Le rognage
    /// est l'implémentation **naturelle et fausse** : elle réécrit le titre de la source, donc l'en-tête
    /// Markdown et la tuile (critères 16 et 18) ne portent plus ce que `yt-dlp` a écrit. La détection
    /// du titre **blanc** est une décision distincte (un titre blanc vaut absent, cas e et f) : elle ne
    /// se fait pas en rognant le titre retenu.
    ///
    /// Cas **ajouté** par la carte QA L8-T (les six cas de la carte sont obligatoires) : sans lui, la
    /// clause 4 du contrat du point 1 n'a aucun test, et un `trimmingCharacters(in:)` invisible aux six
    /// autres cas passerait le vert de la carte `dev`.
    func testLeTitreRenduNEstPasRogne() {
        XCTAssertEqual(
            TranscriptJobTitle.resolve(
                resumed: nil, acquisition: " Titre officiel ", caller: ""),
            " Titre officiel ",
            "\(contrat) — le titre de l'acquisition est rendu tel quel, espaces compris")

        XCTAssertEqual(
            TranscriptJobTitle.resolve(resumed: " Titre d'origine ", acquisition: nil, caller: ""),
            " Titre d'origine ",
            "\(contrat) — le titre d'une reprise est rendu tel quel, espaces compris")
    }
}
