import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 9 : **la tuile de transcript** — ce qu'une tuile affiche, dérivé du
/// document JSON (critère 16), les deux actions qu'elle offre (critère 17), et le fait que la
/// bibliothèque affichée est le dossier lui-même (critère 14). Plan §4 lot 9 et §2.4.
///
/// Ce que ces tests protègent, et pourquoi ils sont en Swift pur :
/// - **critère 16** : une tuile porte le titre écrit, un mot de provenance, le jour et la durée —
///   et un résumé d'une ligne pris au début du texte ;
/// - **critère 17** : les seules actions sont **ouvrir** et **supprimer**. Le plan range ce
///   critère sous « tests du modèle de tuile », et c'est la seule forme sous laquelle il est
///   vérifiable : la vue n'a pas de bundle de tests, l'énumération ``TranscriptTile/Action`` si ;
/// - **critère 14** : une tuile par document **présent sur disque**, y compris un travail en cours
///   ou en échec, et supprimer le fichier retire la tuile au chargement suivant — sans index à
///   resynchroniser, parce qu'il n'y en a pas.
///
/// Ce que ces tests ne font pas : ils ne dessinent rien. La largeur d'une tuile est gelée dans
/// `TranscriptsLayoutTests`, et la vue elle-même reste une gate à l'œil (plan §7 ligne 16).
///
/// Tout ce qui est écrit ici hors du dossier temporaire n'existe pas : rien n'approche
/// `~/Library/Application Support/Murmure` ni `~/Documents`.
///
/// Tous les cas ci-dessous échouent sur une **assertion explicite** — jamais sur une erreur de
/// compilation — tant que les corps sentinelles de `TranscriptTile.swift` n'ont pas été remplacés.
final class TranscriptTileTests: XCTestCase {
    private let contrat = "contrat lot 9 : non implémenté"

    /// Le fuseau de Louis, comme `HistoryRowTests` : c'est ce qui rend la date d'une tuile
    /// vérifiable par une chaîne plutôt que par le fuseau de la machine qui exécute les tests.
    private let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = HistoryGrouping.locale
        return calendar
    }()

    private var espace: URL!

    override func setUpWithError() throws {
        espace = try Self.bacASable("TranscriptTileTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: espace)
    }

    // MARK: - Outils

    /// Le seul endroit du fichier qui nomme un dossier, et il ne peut pas en nommer un vrai.
    private static func bacASable(_ nom: String) throws -> URL {
        let temporaire = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let racine = temporaire.appendingPathComponent(
            "\(nom)-\(UUID().uuidString)", isDirectory: true)
        precondition(
            racine.resolvingSymlinksInPath().path.hasPrefix(temporaire.path),
            "un test de tuile n'écrit que sous NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        return racine
    }

    /// Midi UTC un jour donné : midi ne peut pas basculer d'un jour à l'autre dans un fuseau
    /// européen, donc `utc(20)` est bien le 20 septembre pour un lecteur parisien.
    private static func utc(
        _ quantieme: Int, hour: Int = 12, minute: Int = 42, second: Int = 3
    ) -> Date {
        var composants = DateComponents()
        composants.year = 2026
        composants.month = 9
        composants.day = quantieme
        composants.hour = hour
        composants.minute = minute
        composants.second = second
        composants.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: composants)
            ?? Date(timeIntervalSince1970: 0)
    }

    private func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    private func document(
        id: String,
        title: String,
        kind: TranscriptSourceKind,
        identity: String,
        createdAt: Date,
        duration: Double,
        status: TranscriptStatus,
        segments: [TranscriptSegment]
    ) -> TranscriptDocument {
        TranscriptDocument(
            id: id,
            title: title,
            source: TranscriptSource(
                kind: kind,
                url: kind == .file ? nil : URL(string: "https://example.invalid/\(identity)"),
                path: kind == .file ? "/tmp/\(identity).mov" : nil,
                identity: identity),
            duration: duration,
            language: "fr",
            languageWasForced: false,
            model: "large-v3-turbo",
            createdAt: createdAt,
            completedAt: nil,
            status: status,
            segments: segments,
            coverage: TranscriptDocument.Coverage(coveredSeconds: duration, ratio: 1),
            boundaries: [])
    }

    /// Le document nominal : une vidéo YouTube transcrite le 20 septembre, 38 minutes.
    private func video(
        segments: [TranscriptSegment] = []
    ) -> TranscriptDocument {
        document(
            id: "comment-ecrire-une-app-macos-2026-09-20-abc12345",
            title: "Comment écrire une app macOS",
            kind: .youtube,
            identity: "abc12345",
            createdAt: Self.utc(20),
            duration: 2280,
            status: .complete,
            segments: segments)
    }

    private func tuile(_ document: TranscriptDocument) -> TranscriptTile {
        TranscriptTile.tile(for: document, calendar: paris)
    }

    // MARK: - Critère 16 : titre, source, date, durée

    /// Les quatre champs du critère 16, sur le cas nominal. Le titre est celui **qui a été
    /// écrit**, jamais le slug du nom de fichier, et la date est un jour sans heure : une tuile se
    /// lit dans une bibliothèque, pas dans une journée.
    func testCriterion16ATileCarriesTheDocumentsTitleItsSourceWordItsDayAndItsDuration() {
        let document = video()
        let tuile = tuile(document)

        XCTAssertEqual(tuile.id, document.id, contrat)
        XCTAssertEqual(tuile.title, "Comment écrire une app macOS", contrat)
        XCTAssertNotEqual(tuile.title, document.id, contrat)
        XCTAssertEqual(tuile.source, "YouTube", contrat)
        XCTAssertEqual(tuile.date, "20 Sep 2026", contrat)
        XCTAssertEqual(tuile.duration, "38 min", contrat)
        XCTAssertFalse(tuile.date.contains(":"), contrat)
    }

    /// Une tuile montre un mot, pas un nom de schéma. `youtube`, `x` et `file` sont les valeurs
    /// brutes du JSON (lot 1) : les confondre mettrait un nom de fichier dans une tuile, et la
    /// règle de langue de `MenuTextTests` ne les verrait même pas.
    func testCriterion16TheSourceIsADisplayWordAndNeverTheStorageName() {
        let attendus: [(TranscriptSourceKind, String)] = [
            (.youtube, "YouTube"), (.x, "X"), (.file, "File"),
        ]
        for (kind, mot) in attendus {
            let document = document(
                id: "tige-\(kind.rawValue)", title: "Un titre", kind: kind,
                identity: "identite-\(kind.rawValue)", createdAt: Self.utc(20), duration: 60,
                status: .complete, segments: [])
            XCTAssertEqual(tuile(document).source, mot, contrat)
            XCTAssertNotEqual(tuile(document).source, kind.rawValue, contrat)
        }
        let mots = Set(
            TranscriptSourceKind.allCases.map { kind in
                tuile(
                    document(
                        id: "tige-\(kind.rawValue)", title: "Un titre", kind: kind,
                        identity: "identite-\(kind.rawValue)", createdAt: Self.utc(20),
                        duration: 60, status: .complete, segments: [])
                ).source
            })
        XCTAssertEqual(mots.count, TranscriptSourceKind.allCases.count, contrat)
    }

    /// La durée suit la règle de l'Historique et pas une seconde règle écrite ici : « 38 min » doit
    /// vouloir dire la même chose dans les deux sections, et une durée de dictée de 29,7 s s'écrit
    /// « 30 s » là comme ici.
    func testTheDurationFollowsTheOneRuleTheModuleAlreadyHas() {
        for secondes in [0.0, 29.7, 59.6, 60, 119, 2280, 14_340] {
            let document = document(
                id: "duree", title: "Un titre", kind: .youtube, identity: "identite",
                createdAt: Self.utc(20), duration: secondes, status: .complete, segments: [])
            XCTAssertEqual(tuile(document).duration, HistoryRow.duration(secondes), contrat)
        }
        XCTAssertEqual(
            tuile(
                document(
                    id: "duree", title: "Un titre", kind: .youtube, identity: "identite",
                    createdAt: Self.utc(20), duration: 2280, status: .complete, segments: [])
            ).duration,
            "38 min", contrat)
    }

    // MARK: - Critère 16 : le résumé d'une ligne

    /// Le début du texte, sur **une seule ligne** : les segments vides sont transparents, les
    /// retours à la ligne et les suites d'espaces sont aplatis — c'est `StatusPanelText.oneLine`
    /// qui fait ce travail, la même fonction que la ligne d'une entrée d'Historique.
    func testCriterion16TheSummaryIsTheStartOfTheTextOnASingleLine() {
        let document = video(segments: [
            segment(0, 3, ""),
            segment(3, 6, "   \n"),
            segment(6, 9, "euh il faut brancher\n\nle connecteur   sur le staging"),
            segment(9, 12, "et ça continue"),
        ])
        XCTAssertEqual(
            tuile(document).summary, "euh il faut brancher le connecteur sur le staging", contrat)

        // Un texte plus court que le plafond n'est pas touché : aucune ellipsis gratuite.
        let court = video(segments: [segment(0, 3, "on rebranche le connecteur")])
        XCTAssertEqual(tuile(court).summary, "on rebranche le connecteur", contrat)
    }

    /// Coupé à la queue, à une frontière de mot, avec une ellipsis — la règle de
    /// `HistoryRow.preview`, parce qu'une tuile et une ligne d'Historique montrent la même chose :
    /// le début d'un texte, à la largeur d'une ligne.
    func testALongFirstSegmentIsCutAtAWordBoundaryWithAnEllipsis() {
        let long = String(repeating: "connecteur ", count: 40)
        let document = video(segments: [segment(0, 12, long)])
        let resume = tuile(document).summary

        XCTAssertTrue(
            resume.hasSuffix("…"), "la queue est ce qui tombe : \(resume) — \(contrat)")
        XCTAssertLessThanOrEqual(resume.count, TranscriptTile.previewLimit + 1, contrat)
        XCTAssertTrue(resume.hasPrefix("connecteur connecteur"), contrat)
        XCTAssertFalse(
            resume.contains("connect…"), "la coupe tombe entre deux mots — \(contrat)")
    }

    /// Un document sans texte — un travail `inProgress` écrit avant sa première unité, ou un
    /// `failed` — rend une chaîne vide, et **pas un mot inventé** : l'interface n'a de mots que
    /// dans `MenuText`, et un placeholder ici serait une phrase que personne n'a décidée.
    ///
    /// Le contrôle positif est **dans le même test** : sans lui, la sentinelle vide passerait pour
    /// une implémentation correcte.
    func testADocumentWithoutTextHasAnEmptySummaryRatherThanInventedWords() {
        let avecTexte = video(segments: [segment(0, 3, "premier vrai mot")])
        XCTAssertEqual(tuile(avecTexte).summary, "premier vrai mot", contrat)

        let enCours = document(
            id: "en-cours", title: "Un titre", kind: .youtube, identity: "en-cours",
            createdAt: Self.utc(20), duration: 2280, status: .inProgress, segments: [])
        XCTAssertEqual(tuile(enCours).summary, "", contrat)

        let enEchec = document(
            id: "en-echec", title: "Un titre", kind: .youtube, identity: "en-echec",
            createdAt: Self.utc(20), duration: 2280, status: .failed,
            segments: [segment(0, 1, "  \n ")])
        XCTAssertEqual(tuile(enEchec).summary, "", contrat)
    }

    // MARK: - Critère 17 : ouvrir et supprimer seulement

    /// **Les deux actions, et les deux seulement.** Une troisième — relancer la transcription,
    /// renommer, copier — serait un contrat faux : le critère 17 les exclut, et R7 range la
    /// relance sous le chemin de lancement normal (menu ou cible de dépôt), jamais sous une tuile.
    func testCriterion17ATileOffersOpeningAndDeletingAndNothingElse() {
        XCTAssertEqual(TranscriptTile.Action.allCases, [.open, .delete], contrat)
        XCTAssertEqual(TranscriptTile.Action.allCases.count, 2, contrat)

        let tuile = tuile(video(segments: [segment(0, 3, "on rebranche le connecteur")]))
        XCTAssertEqual(tuile.actions, [.open, .delete], contrat)
    }

    // MARK: - Critère 14 : le disque est la vérité

    /// Une tuile par document **présent sur disque**, quel que soit son statut : un travail
    /// interrompu a son fichier, donc il a sa tuile — la filtrer reviendrait à cacher une ligne à
    /// Louis sur son propre disque, et le plan §2.4 fait de l'état du transcript la façon de
    /// reprendre une acquisition.
    func testCriterion14ATileExistsForEveryDocumentOnDiskIncludingUnfinishedOnes() {
        for statut in TranscriptStatus.allCases {
            let document = document(
                id: "tige-\(statut.rawValue)", title: "Un titre \(statut.rawValue)", kind: .file,
                identity: "identite-\(statut.rawValue)", createdAt: Self.utc(20), duration: 600,
                status: statut, segments: [])
            let tuile = tuile(document)
            XCTAssertEqual(tuile.id, document.id, contrat)
            XCTAssertEqual(tuile.title, "Un titre \(statut.rawValue)", contrat)
        }
        XCTAssertEqual(TranscriptStatus.allCases.count, 3, contrat)
    }

    /// Le critère 14 de bout en bout, avec la vraie bibliothèque : ce qui est affiché est ce que le
    /// dossier rend, donc **supprimer les fichiers retire la tuile** — et il n'y a aucun index à
    /// resynchroniser, parce qu'il n'y en a pas (plan §2.4).
    func testCriterion14TheTilesFollowTheFolderWhenATranscriptIsDeleted() throws {
        let bibliotheque = TranscriptLibrary(
            base: espace.appendingPathComponent("Transcripts", isDirectory: true))
        let premier = document(
            id: "ignore-par-l-ecriture", title: "Une vidéo plus ancienne", kind: .youtube,
            identity: "ancienne", createdAt: Self.utc(18), duration: 600, status: .complete,
            segments: [segment(0, 3, "le début")])
        let second = document(
            id: "ignore-par-l-ecriture", title: "Une vidéo plus récente", kind: .youtube,
            identity: "recente", createdAt: Self.utc(20), duration: 2280, status: .complete,
            segments: [segment(0, 3, "le début")])

        // `write` décide la tige et la pose dans le champ `id` du document écrit (lot 2) : c'est
        // **cette** tige que la tuile doit porter.
        let urlPremier = try bibliotheque.write(premier)
        let urlSecond = try bibliotheque.write(second)
        let tigePremiere = urlPremier.deletingPathExtension().lastPathComponent
        let tigeSeconde = urlSecond.deletingPathExtension().lastPathComponent

        var tuiles = TranscriptTile.tiles(
            for: bibliotheque.list().documents, calendar: paris)
        XCTAssertEqual(tuiles.count, 2, contrat)
        XCTAssertEqual(Set(tuiles.map(\.id)), Set([tigePremiere, tigeSeconde]), contrat)
        XCTAssertEqual(tuiles.map(\.id), [tigeSeconde, tigePremiere], contrat)

        // Ouvrir et supprimer passent par cette identité : elle doit retrouver le document.
        // Indexée sûrement (`first`), jamais `tuiles[0]` : un test qui sort du tableau ferait
        // tomber tout le binaire de tests et masquerait les résultats des autres — le rouge doit
        // être une assertion, pas un arrêt brutal.
        let ouverte = tuiles.first.flatMap { bibliotheque.transcript(id: $0.id) }
        XCTAssertEqual(ouverte?.title, "Une vidéo plus récente", contrat)

        bibliotheque.delete(id: tigePremiere)
        tuiles = TranscriptTile.tiles(for: bibliotheque.list().documents, calendar: paris)
        XCTAssertEqual(tuiles.count, 1, contrat)
        XCTAssertEqual(tuiles.first?.id, tigeSeconde, contrat)
    }

    /// L'ordre appartient à ce lot — `TranscriptLibrary.list()` rend l'ordre du dossier et le dit
    /// explicitement. Le plus récent d'abord, comme l'Historique, et à instant égal un ordre qui ne
    /// dépend **pas** de l'ordre de parcours : deux documents écrits dans la même seconde ne
    /// doivent pas changer de place d'un chargement à l'autre.
    func testTheOrderIsNewestFirstAndDoesNotDependOnTheFolderOrder() {
        let vieux = document(
            id: "a-2026-09-18", title: "Vieille", kind: .youtube, identity: "a",
            createdAt: Self.utc(18), duration: 600, status: .complete, segments: [])
        let recent = document(
            id: "b-2026-09-20", title: "Récente", kind: .youtube, identity: "b",
            createdAt: Self.utc(20), duration: 600, status: .complete, segments: [])
        let memeInstant = document(
            id: "c-2026-09-20", title: "Même instant", kind: .youtube, identity: "c",
            createdAt: Self.utc(20), duration: 600, status: .complete, segments: [])

        let attendu = ["b-2026-09-20", "c-2026-09-20", "a-2026-09-18"]
        XCTAssertEqual(
            TranscriptTile.tiles(for: [vieux, recent, memeInstant], calendar: paris).map(\.id),
            attendu, contrat)
        XCTAssertEqual(
            TranscriptTile.tiles(for: [memeInstant, vieux, recent], calendar: paris).map(\.id),
            attendu, contrat)
        XCTAssertEqual(
            TranscriptTile.tiles(for: [recent, memeInstant, vieux], calendar: paris).map(\.id),
            attendu, contrat)
        XCTAssertEqual(TranscriptTile.tiles(for: [], calendar: paris), [], contrat)
    }
}
