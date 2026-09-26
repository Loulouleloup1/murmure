import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 2 : le **répertoire de travail** d'un travail de transcription,
/// `work/<jobID>/` dans la même arborescence que les transcripts (plan §2.4, critères 14 et 21).
///
/// Deux choses y sont figées et aucune n'est cosmétique :
/// - **nommer n'est pas créer** : `directoryURL`, `progressURL` et `unitURL(index:)` calculent un
///   chemin sans toucher au disque ; seul `create()` crée. C'est la leçon déjà payée du dépôt
///   (`Storage`) : une fonction qui crée au passage fait écrire un test qui voulait seulement
///   demander où est le dossier — dans le dossier réel de Louis, sans qu'il l'ait demandé ;
/// - **`remove()` est un nettoyage borné** : il emporte les unités et le point de reprise, jamais
///   les transcripts voisins, et se répète sans dommage (R7 : suppression après succès vérifié).
///
/// Tous ces cas échouent sur une **assertion explicite** tant que les corps sentinelles de
/// `TranscriptWorkDirectory.swift` n'ont pas été remplacés.
final class TranscriptWorkDirectoryTests: XCTestCase {
    private let contrat = "contrat lot 2 : non implémenté"

    private var espace: URL!
    private var base: URL!
    private var travail: TranscriptWorkDirectory!

    override func setUpWithError() throws {
        espace = try Self.bacASable("TranscriptWorkDirectoryTests")
        base = espace.appendingPathComponent("Transcripts", isDirectory: true)
        travail = TranscriptWorkDirectory(base: base, jobID: "job-0001")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: espace)
    }

    // MARK: - Outils

    /// Le seul endroit du fichier qui nomme un dossier, et il ne peut pas en nommer un vrai : tout
    /// ce que ces tests écrivent vit sous `NSTemporaryDirectory()`. Rien ici ne doit approcher
    /// `~/Library/Application Support/Murmure` ni `~/Documents`.
    private static func bacASable(_ nom: String) throws -> URL {
        let temporaire = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let racine = temporaire.appendingPathComponent("\(nom)-\(UUID().uuidString)", isDirectory: true)
        precondition(
            racine.resolvingSymlinksInPath().path.hasPrefix(temporaire.path),
            "un test du répertoire de travail ne travaille que sous NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        return racine
    }

    /// Le préalable commun des tests qui déposent des fixtures : le répertoire de travail existe et
    /// **les chemins calculés sont bien dedans**. Sans ce contrôle, un corps sentinelle ferait
    /// écrire le test au chemin sentinelle au lieu d'échouer proprement.
    private func travailPret() -> Bool {
        let racine = travail.directoryURL.path
        let dedans =
            travail.progressURL.deletingLastPathComponent().path == racine
            && travail.unitURL(index: 0).deletingLastPathComponent().path == racine + "/units"
        guard dedans, FileManager.default.fileExists(atPath: racine) else {
            XCTFail(contrat + " — create() doit créer \(racine) et les chemins calculés doivent être dedans")
            return false
        }
        return true
    }

    // MARK: - Les chemins

    /// La forme gelée par le plan : `<base>/work/<jobID>`, `<...>/progress.json`,
    /// `<...>/units/0000.wav` — et **rien de tout cela n'existe après avoir été nommé**.
    func testLesCheminsSontCeuxDuPlanEtLeNommageNeCreeRien() {
        XCTAssertEqual(travail.directoryURL.path, base.appendingPathComponent("work/job-0001").path, contrat)
        XCTAssertEqual(travail.progressURL.path, "\(travail.directoryURL.path)/progress.json", contrat)
        XCTAssertEqual(travail.unitURL(index: 0).path, "\(travail.directoryURL.path)/units/0000.wav", contrat)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: base.path),
            contrat + " — nommer un chemin ne crée rien (leçon du dépôt : Storage.url ne crée pas)")
    }

    /// La numérotation des tranches : **au moins quatre chiffres** (`0000`, `0042`), et au-delà de
    /// 9999 le numéro s'allonge au lieu d'être tronqué — deux tranches ne peuvent pas porter le
    /// même nom de fichier.
    func testLesTranchesSontNumeroteesSurQuatreChiffresEtSAllongentAuDela() {
        let attendus = [(0, "0000.wav"), (7, "0007.wav"), (42, "0042.wav"), (1234, "1234.wav"), (10000, "10000.wav")]

        for (index, nom) in attendus {
            XCTAssertEqual(
                travail.unitURL(index: index).lastPathComponent, nom,
                contrat + " — la tranche \(index) doit s'appeler \(nom)")
        }
    }

    /// Deux travaux n'écrivent pas au même endroit : le `jobID` sépare les répertoires, sinon deux
    /// transcriptions concurrentes se marcheraient dessus.
    func testDeuxTravauxOntDesRepertoiresDistinctsSousWork() {
        let autre = TranscriptWorkDirectory(base: base, jobID: "job-0002")

        XCTAssertNotEqual(travail.directoryURL, autre.directoryURL, contrat)
        XCTAssertTrue(travail.directoryURL.path.hasSuffix("/work/job-0001"), contrat)
        XCTAssertTrue(autre.directoryURL.path.hasSuffix("/work/job-0002"), contrat)
        XCTAssertNotEqual(travail.unitURL(index: 0), autre.unitURL(index: 0), contrat)
    }

    // MARK: - Création

    /// `create()` crée le répertoire de travail **et** son sous-dossier `units/` (parents compris) :
    /// c'est là que la première tranche sera écrite (lot 7).
    func testCreateCreeLeRepertoireDeTravailEtSonSousDossierDUnites() throws {
        try travail.create()

        var estUnDossier: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: travail.directoryURL.path, isDirectory: &estUnDossier),
            contrat)
        XCTAssertTrue(estUnDossier.boolValue, contrat)
        XCTAssertTrue(travailPret(), contrat)
    }

    /// `create()` réussit sur un répertoire qui existe déjà — une reprise (statut `inProgress`,
    /// plan §2.4) repasse par ici — et **garde ce qu'il y a dedans** : les unités déjà transcrites
    /// sont le travail déjà payé.
    func testCreateRepeteGardeLeContenuDuRepertoire() throws {
        try travail.create()
        guard travailPret() else { return }
        let premiere = travail.unitURL(index: 0)
        try Data("audio de la premiere unite".utf8).write(to: premiere)

        try travail.create()

        XCTAssertEqual(
            try? String(contentsOf: premiere, encoding: .utf8), "audio de la premiere unite", contrat)
    }

    // MARK: - Suppression

    /// `remove()` emporte **tout** le répertoire de travail : unités, point de reprise, répertoire.
    func testRemoveSupprimeToutLeRepertoireDeTravail() throws {
        try travail.create()
        guard travailPret() else { return }
        try Data("wav".utf8).write(to: travail.unitURL(index: 3))
        try Data("{\"unite\":3}".utf8).write(to: travail.progressURL)

        travail.remove()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: travail.directoryURL.path),
            contrat + " — le répertoire de travail doit disparaître avec ses unités")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: base.path),
            contrat + " — remove() enlève le travail, pas la racine des transcripts")
    }

    /// La suppresion est **bornée** : elle ne touche pas aux transcripts du dossier parent, qui
    /// sont le résultat du travail et la seule chose qu'on garde (R7).
    func testRemoveNeTouchePasAuxTranscriptsVoisins() throws {
        try travail.create()
        guard travailPret() else { return }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let transcript = base.appendingPathComponent("demonstration-2026-09-20-a1b2c3d4.json")
        try Data("{\"id\":\"demonstration-2026-09-20-a1b2c3d4\"}".utf8).write(to: transcript)

        travail.remove()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: travail.directoryURL.path),
            contrat + " — le répertoire de travail doit partir")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: transcript.path),
            contrat + " — remove() ne touche jamais aux transcripts")
    }

    /// `remove()` sur un répertoire absent ne casse rien, et le travail peut repartir derrière :
    /// c'est le cas d'une relance après un nettoyage déjà fait.
    func testRemoveSurUnTravailAbsentNeCasseRienEtLeTravailRepart() throws {
        travail.remove()

        try travail.create()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: travail.directoryURL.path),
            contrat + " — le travail doit pouvoir repartir après un remove() sans travail")
    }
}
