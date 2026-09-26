import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 2 : **la bibliothèque sur disque** — écriture atomique, lecture du dossier,
/// suppression — dans `~/Library/Application Support/Murmure/Transcripts/` (plan §2.4 et §4 lot 2,
/// décision R3, critères 14 et 21).
///
/// Ce que ces tests protègent, au-delà de la forme des fichiers :
/// - **le disque est la vérité** (critère 14) : la liste est un parcours du dossier, donc supprimer
///   un fichier hors de l'API le retire de la liste — sans index à resynchroniser ;
/// - **un transcript existant n'est jamais écrasé** : relancer une source déjà transcrite écrit un
///   second transcript à côté du premier, et une reprise (`inProgress`) réutilise la même tige au
///   lieu d'en créer une deuxième (arbitrage N1) ;
/// - **l'écriture est atomique** : un lecteur ne voit jamais un JSON tronqué, et un lecteur qui
///   avait ouvert l'ancien fichier lit encore l'ancien transcript complet ;
/// - **un JSON illisible est ignoré et compté**, jamais fatal — un fichier abîmé ne doit pas rendre
///   toute la bibliothèque invisible.
///
/// Tout ce que ces tests écrivent vit sous `NSTemporaryDirectory()` : la racine réelle de
/// l'application n'est jamais touchée (ni `Application Support`, ni `Documents`).
///
/// Tous ces cas échouent sur une **assertion explicite** tant que les corps sentinelles de
/// `TranscriptLibrary.swift` n'ont pas été remplacés.
final class TranscriptLibraryTests: XCTestCase {
    private let contrat = "contrat lot 2 : non implémenté"

    private var espace: URL!
    private var base: URL!
    private var bibliotheque: TranscriptLibrary!

    override func setUpWithError() throws {
        espace = try Self.bacASable("TranscriptLibraryTests")
        base = espace.appendingPathComponent("Transcripts", isDirectory: true)
        bibliotheque = TranscriptLibrary(base: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: espace)
    }

    // MARK: - Outils

    /// Le seul endroit du fichier qui nomme un dossier, et il ne peut pas en nommer un vrai : tout
    /// vit sous `NSTemporaryDirectory()`. Rien ici ne doit approcher
    /// `~/Library/Application Support/Murmure` ni `~/Documents/Murmure`.
    private static func bacASable(_ nom: String) throws -> URL {
        let temporaire = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let racine = temporaire.appendingPathComponent("\(nom)-\(UUID().uuidString)", isDirectory: true)
        precondition(
            racine.resolvingSymlinksInPath().path.hasPrefix(temporaire.path),
            "un test de la bibliothèque ne travaille que sous NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        return racine
    }

    private static func decodeur() -> JSONDecoder {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        return decodeur
    }

    /// Midi, dans le calendrier et le fuseau courants — la tige porte le jour **local** (lot 1), et
    /// midi ne peut basculer d'un jour à l'autre par un décalage horaire.
    private func jour(_ annee: Int = 2026, _ mois: Int = 9, _ quantieme: Int = 20) -> Date {
        var composants = DateComponents()
        composants.year = annee
        composants.month = mois
        composants.day = quantieme
        composants.hour = 12
        return Calendar(identifier: .gregorian).date(from: composants) ?? Date(timeIntervalSince1970: 0)
    }

    private func document(
        titre: String = "Démonstration",
        identite: String = "dQw4w9WgXcQ",
        statut: TranscriptStatus = .complete,
        segments: [TranscriptSegment]? = nil,
        creeLe: Date? = nil,
        id: String = "identifiant-invente"
    ) -> TranscriptDocument {
        let date = creeLe ?? jour()
        return TranscriptDocument(
            id: id,
            title: titre,
            source: TranscriptSource(
                kind: .youtube,
                url: URL(string: "https://www.youtube.com/watch?v=\(identite)")
                    ?? URL(fileURLWithPath: "/identite-invalide"),
                identity: identite),
            duration: 20,
            language: "fr",
            languageWasForced: false,
            model: "large-v3-turbo",
            createdAt: date,
            completedAt: statut == .complete ? date : nil,
            status: statut,
            segments: segments ?? Self.petitsSegments,
            coverage: TranscriptDocument.Coverage(coveredSeconds: 20, ratio: 1),
            boundaries: [])
    }

    private static let petitsSegments = [
        TranscriptSegment(start: 0, end: 10, text: "Bonjour"),
        TranscriptSegment(start: 10, end: 20, text: "tout le monde"),
    ]

    /// Des segments qui **pèsent** : les cas d'atomicité ont besoin d'une écriture mesurable, pas
    /// d'une écriture instantanée.
    private static func grosSegments(_ compte: Int) -> [TranscriptSegment] {
        (0..<compte).map { rang in
            TranscriptSegment(
                start: Double(rang) * 2, end: Double(rang) * 2 + 1.5,
                text: "segment \(rang) — un peu de texte pour que le JSON pèse quelque chose")
        }
    }

    /// La tige que la bibliothèque **doit** employer : `<slug>-<AAAA-MM-JJ>-<id8>` du titre, de la
    /// date de création et de l'identité de la source (nommage gelé au lot 1).
    private static func tige(_ document: TranscriptDocument) -> String {
        TranscriptFilenames.stem(
            title: document.title, date: document.createdAt, identity: document.source.identity)
    }

    private func chemin(_ tige: String, _ extensionFichier: String = "json") -> String {
        base.appendingPathComponent("\(tige).\(extensionFichier)").path
    }

    private func existe(_ tige: String, _ extensionFichier: String = "json") -> Bool {
        FileManager.default.fileExists(atPath: chemin(tige, extensionFichier))
    }

    /// Le document relu du disque, comme le feraient le CLI (`murmure read <id>`) et le panneau :
    /// décodeur ISO-8601, la stratégie gelée par le lot 1.
    private func relire(_ tige: String) -> TranscriptDocument? {
        guard let donnees = try? Data(contentsOf: base.appendingPathComponent("\(tige).json")) else {
            return nil
        }
        return try? Self.decodeur().decode(TranscriptDocument.self, from: donnees)
    }

    private func identifiantsListes() -> Set<String> {
        Set(bibliotheque.list().documents.map(\.id))
    }

    // MARK: - Écriture : les deux formats, la tige, le champ id

    /// Une écriture produit **les deux formats sous la même tige** (critère 21) et rien d'autre :
    /// le fichier temporaire de l'écriture atomique ne doit pas rester dans le dossier.
    func testEcritureProduitLesDeuxFormatsSousLaMemeTigeEtRienDAutre() throws {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: base.path),
            contrat + " — poser une bibliothèque ne crée rien ; c'est l'écriture qui crée la racine")

        let ecrit = try bibliotheque.write(document())
        let tige = Self.tige(document())

        guard FileManager.default.fileExists(atPath: ecrit.path), ecrit.path.hasPrefix(base.path) else {
            return XCTFail(contrat + " — write doit écrire le JSON sous la base et rendre son URL (reçu \(ecrit.path))")
        }
        XCTAssertEqual(ecrit.lastPathComponent, "\(tige).json", contrat)
        guard let markdown = try? String(
            contentsOf: base.appendingPathComponent("\(tige).md"), encoding: .utf8)
        else {
            return XCTFail(contrat + " — critère 21 : \(tige).md doit exister à côté du JSON")
        }
        XCTAssertEqual(markdown, TranscriptMarkdown.render(document()), contrat)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: base.path).sorted(),
            ["\(tige).json", "\(tige).md"],
            contrat + " — l'écriture passe par un fichier temporaire qui ne doit pas rester derrière")
    }

    /// Le JSON écrit est celui du lot 1 : version de schéma, dates ISO-8601 (le décodeur des agents),
    /// segments intacts. Un document écrit qui ne se relit pas n'est pas un transcript.
    func testLeJSONEcritPorteLaVersionDuSchemaEtSeRelitParUnDecodeurISO8601() throws {
        let ecrit = document(titre: "Comment écrire une app macOS")
        try bibliotheque.write(ecrit)

        guard let relu = relire(Self.tige(ecrit)) else {
            return XCTFail(contrat + " — le JSON écrit doit se décoder avec un décodeur ISO-8601")
        }
        XCTAssertEqual(relu.schemaVersion, TranscriptDocument.schemaVersion, contrat)
        XCTAssertEqual(relu.title, ecrit.title, contrat)
        XCTAssertEqual(relu.source.identity, ecrit.source.identity, contrat)
        XCTAssertEqual(relu.createdAt, ecrit.createdAt, contrat)
        XCTAssertEqual(relu.status, .complete, contrat)
        XCTAssertEqual(relu.segments, ecrit.segments, contrat)
    }

    /// **Le champ `id` d'un transcript écrit est la tige de son nom de fichier.** C'est ce qui
    /// permet à `transcript(id:)`, à la tuile (critère 16) et au `murmure read <id>` (critère 20) de
    /// le retrouver sans index — un document qui garderait un id inventé serait introuvable.
    func testLeChampIdEcritEstLaTigeDuNomDeFichier() throws {
        let ecrit = document(id: "identifiant-invente")
        try bibliotheque.write(ecrit)
        let tige = Self.tige(ecrit)

        guard let relu = relire(tige) else {
            return XCTFail(contrat + " — \(tige).json doit exister et se décoder")
        }
        XCTAssertEqual(relu.id, tige, contrat)
    }

    // MARK: - Lecture du dossier

    /// Le dossier est l'index : trois transcripts écrits, trois transcripts listés.
    func testListParcourtLeDossierEtRendLesTranscriptsEcrits() throws {
        let premiers = [
            document(),
            document(titre: "Deuxième", identite: "aaaa"),
            document(titre: "Troisième", identite: "bbbb"),
        ]
        for ecrit in premiers { try bibliotheque.write(ecrit) }

        let listing = bibliotheque.list()

        XCTAssertEqual(listing.unreadableCount, 0, contrat)
        XCTAssertEqual(identifiantsListes(), Set(premiers.map(Self.tige)), contrat)
    }

    /// Un JSON illisible — tronqué, ou JSON valide mais étranger au schéma — est **ignoré et
    /// compté**, jamais fatal : le transcript valide reste visible, et le compte dit pourquoi une
    /// tuile manque.
    func testUnJSONIllisibleEstIgnoreEtCompte() throws {
        let valide = document()
        try bibliotheque.write(valide)
        guard existe(Self.tige(valide)) else {
            return XCTFail(contrat + " — le transcript valide doit être écrit avant de semer des JSON illisibles")
        }
        try Data("{\"schemaVersion\": 1, \"titre\":".utf8)
            .write(to: base.appendingPathComponent("tronque-2026-09-20-00000000.json"))
        try Data("{\"bonjour\": 1}".utf8)
            .write(to: base.appendingPathComponent("etranger-2026-09-20-11111111.json"))

        let listing = bibliotheque.list()

        XCTAssertEqual(
            listing.unreadableCount, 2,
            contrat + " — un JSON illisible est ignoré mais compté, et jamais fatal")
        XCTAssertEqual(identifiantsListes(), Set([Self.tige(valide)]), contrat)
    }

    /// Ce qui n'est pas un transcript ne compte pas comme un transcript illisible : le sous-dossier
    /// `work/` (ses tranches, son `progress.json`), un `.md` orphelin, un fichier du Finder. Le
    /// parcours ne descend pas non plus dans les sous-dossiers.
    func testLesFichiersQuiNeSontPasDesTranscriptsNeSontNiListesNiComptes() throws {
        let valide = document()
        try bibliotheque.write(valide)
        let travail = base.appendingPathComponent("work/job-0001/units", isDirectory: true)
        try FileManager.default.createDirectory(at: travail, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: travail.appendingPathComponent("0000.wav"))
        try Data("{\"unite\": 3}".utf8)
            .write(to: base.appendingPathComponent("work/job-0001/progress.json"))
        try Data("# orphelin\n".utf8)
            .write(to: base.appendingPathComponent("orphelin-2026-09-20-22222222.md"))
        try Data([0x00]).write(to: base.appendingPathComponent(".DS_Store"))
        try Data("notes".utf8).write(to: base.appendingPathComponent("notes.txt"))

        let listing = bibliotheque.list()

        XCTAssertEqual(
            listing.unreadableCount, 0,
            contrat + " — work/, un .md orphelin, un .DS_Store ne sont pas des transcripts illisibles")
        XCTAssertEqual(identifiantsListes(), Set([Self.tige(valide)]), contrat)
    }

    /// Première installation : la racine n'existe pas encore, la liste est vide et **ne jette pas**.
    /// Le premier transcript écrit crée la racine et apparaît (contrôle : sans lui, une liste
    /// toujours vide passerait pour un vert).
    func testListSurUneBaseAbsenteRendUneListeVidePuisSeRemplitAuPremierEcrit() throws {
        let vide = bibliotheque.list()

        XCTAssertTrue(vide.documents.isEmpty, contrat)
        XCTAssertEqual(vide.unreadableCount, 0, contrat)

        let premier = document()
        try bibliotheque.write(premier)

        XCTAssertEqual(
            identifiantsListes(), Set([Self.tige(premier)]),
            contrat + " — un premier transcript dans une racine absente doit créer la racine")
    }

    /// **Critère 14 — le disque est la vérité.** Supprimer un fichier du dossier, hors de l'API, le
    /// retire de la liste : c'est ce qui fait qu'une tuile supprimée dans le Finder disparaît au
    /// rechargement, sans index à resynchroniser.
    func testSupprimerUnFichierDuDossierLeRetireDeLaListe() throws {
        let premier = document(identite: "aaaa")
        let second = document(titre: "Deuxième", identite: "bbbb")
        try bibliotheque.write(premier)
        try bibliotheque.write(second)
        let fichier = base.appendingPathComponent("\(Self.tige(premier)).json")
        guard FileManager.default.fileExists(atPath: fichier.path) else {
            return XCTFail(contrat + " — les deux JSON doivent exister pour que le test ait un sens")
        }

        try FileManager.default.removeItem(at: fichier)

        XCTAssertEqual(
            identifiantsListes(), Set([Self.tige(second)]),
            contrat + " — critère 14 : ce qui n'est plus sur disque n'est plus dans la liste")
    }

    /// `transcript(id:)` retrouve un transcript par sa tige, et rend `nil` pour un id que le
    /// dossier ne porte pas (le panneau ne doit pas casser sur une tuile disparue).
    func testTranscriptRetrouveParIdEtRendNilPourUnIdInconnu() throws {
        let ecrit = document(titre: "Cours d'écriture")
        try bibliotheque.write(ecrit)

        guard let retrouve = bibliotheque.transcript(id: Self.tige(ecrit)) else {
            return XCTFail(contrat + " — transcript(id:) doit retrouver le transcript par sa tige")
        }
        XCTAssertEqual(retrouve.title, ecrit.title, contrat)
        XCTAssertEqual(retrouve.segments, ecrit.segments, contrat)
        XCTAssertNil(bibliotheque.transcript(id: "aucun-fichier-2026-09-20-00000000"), contrat)
    }

    // MARK: - Suppression

    /// Supprimer un transcript emporte **les deux fichiers** : un `.md` orphelin resterait dans le
    /// Finder sous une tige dont la tuile a disparu, et le critère 21 veut les deux formats liés.
    func testDeleteRetireLesDeuxFichiersEtLeurTuile() throws {
        let ecrit = document()
        try bibliotheque.write(ecrit)
        let tige = Self.tige(ecrit)
        guard existe(tige), existe(tige, "md") else {
            return XCTFail(contrat + " — les deux fichiers doivent exister avant la suppression")
        }

        bibliotheque.delete(id: tige)

        XCTAssertFalse(existe(tige), contrat)
        XCTAssertFalse(existe(tige, "md"), contrat + " — critère 21 : les deux formats partent ensemble")
        XCTAssertTrue(bibliotheque.list().documents.isEmpty, contrat)
    }

    /// Supprimer deux fois n'est pas une erreur (le panneau et le CLI peuvent viser la même tuile,
    /// R4), et la suppression ne déborde pas sur le transcript voisin.
    func testDeleteRepeteNeCasseRienEtLaisseLeVoisinIntact() throws {
        let premier = document(identite: "aaaa")
        let second = document(titre: "Deuxième", identite: "bbbb")
        try bibliotheque.write(premier)
        try bibliotheque.write(second)
        let tige = Self.tige(premier)
        guard existe(tige) else {
            return XCTFail(contrat + " — le transcript à supprimer doit exister")
        }

        bibliotheque.delete(id: tige)
        bibliotheque.delete(id: tige)

        XCTAssertFalse(existe(tige), contrat)
        XCTAssertEqual(
            identifiantsListes(), Set([Self.tige(second)]),
            contrat + " — supprimer deux fois laisse le reste intact")
    }

    /// L'id est une **tige**, jamais un chemin : une suppression ne doit pas pouvoir sortir de la
    /// racine (le CLI accepte un id venu de l'extérieur, R4).
    func testDeleteNeSortJamaisDeLaBase() throws {
        let intrus = espace.appendingPathComponent("hors-base.json")
        try Data("{\"intrus\": true}".utf8).write(to: intrus)
        let ecrit = document()
        try bibliotheque.write(ecrit)
        guard existe(Self.tige(ecrit)) else {
            return XCTFail(contrat + " — le transcript témoin doit exister")
        }

        bibliotheque.delete(id: "../hors-base")

        XCTAssertEqual(
            identifiantsListes(), Set([Self.tige(ecrit)]),
            contrat + " — un id n'est pas un chemin : la suppression ne sort pas de la racine")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: intrus.path),
            contrat + " — le fichier hors de la base n'est jamais touché")
    }

    // MARK: - Collisions : jamais d'écrasement, reprise sur la même tige

    /// **Un transcript existant n'est jamais écrasé.** Re-lancer la même source produit un second
    /// transcript à côté du premier (tige suffixée `-2`), et le premier n'a pas bougé d'un octet.
    func testUnTranscriptTermineNEstJamaisEcrase() throws {
        let premier = document()
        let ecrit = try bibliotheque.write(premier)
        guard FileManager.default.fileExists(atPath: ecrit.path),
            let octetsPremier = try? Data(contentsOf: ecrit)
        else {
            return XCTFail(contrat + " — le premier transcript doit être écrit et lisible")
        }

        let ecrit2 = try bibliotheque.write(document())

        XCTAssertNotEqual(
            ecrit2, ecrit,
            contrat + " — un transcript « complete » n'est jamais écrasé : la tige est suffixée")
        XCTAssertEqual(ecrit2.lastPathComponent, "\(Self.tige(premier))-2.json", contrat)
        XCTAssertEqual(
            try? Data(contentsOf: ecrit), octetsPremier,
            contrat + " — le premier fichier n'a pas bougé")
        XCTAssertEqual(bibliotheque.list().documents.count, 2, contrat)
    }

    /// **Une reprise réutilise la même tige** (plan §2.4, arbitrage N1) : un travail `inProgress`
    /// relancé écrit dans son propre fichier, il ne laisse pas un doublon derrière lui — sans quoi
    /// l'audio conservé (R7) ne serait jamais réutilisé et Louis aurait deux tuiles pour une vidéo.
    func testUneRepriseEnCoursReutiliseLaMemeTige() throws {
        let enCours = document(statut: .inProgress, segments: [])
        let ecrit = try bibliotheque.write(enCours)
        guard FileManager.default.fileExists(atPath: ecrit.path) else {
            return XCTFail(contrat + " — le travail en cours doit être écrit")
        }

        let reprise = document(
            statut: .inProgress, segments: [TranscriptSegment(start: 0, end: 5, text: "bonjour")])
        let ecrit2 = try bibliotheque.write(reprise)

        XCTAssertEqual(ecrit2, ecrit, contrat + " — le statut décide de la tige")
        XCTAssertEqual(bibliotheque.list().documents.count, 1, contrat)
        XCTAssertEqual(relire(Self.tige(reprise))?.segments.count, 1, contrat)
    }

    /// Un fichier qu'on n'a **pas pu lire** à la tige visée est traité comme pris : on suffixe, et
    /// on n'écrase jamais un fichier dont on ignore le contenu.
    func testUnFichierIllisibleALaTigeViseeEstTraiteCommePrise() throws {
        let ecrit = document()
        let tige = Self.tige(ecrit)
        let abime = base.appendingPathComponent("\(tige).json")
        let octetsAbimes = Data("{ \"coupe\": ".utf8)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try octetsAbimes.write(to: abime)

        try bibliotheque.write(ecrit)

        guard existe("\(tige)-2") else {
            return XCTFail(contrat + " — un fichier illisible à la tige visée doit faire suffixer l'écriture")
        }
        XCTAssertEqual(try? Data(contentsOf: abime), octetsAbimes, contrat)
        XCTAssertEqual(bibliotheque.list().unreadableCount, 1, contrat)
    }

    /// Les vingt tiges sont prises : l'échec est **explicite** (plan §2.4), pas un vingt-et-unième
    /// fichier ni une écriture par-dessus l'un des vingt.
    func testLesVingtTigesPrisesEchouentExplicitement() throws {
        let ecrit = document()
        let tige = Self.tige(ecrit)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for rang in 0...19 {
            let candidat = rang == 0 ? tige : "\(tige)-\(rang + 1)"
            try Data("{}".utf8).write(to: base.appendingPathComponent("\(candidat).json"))
        }

        XCTAssertThrowsError(
            try bibliotheque.write(ecrit),
            contrat + " — au-delà de vingt tiges, l'échec est explicite"
        ) { erreur in
            XCTAssertEqual(erreur as? TranscriptFilenameError, .allNamesTaken(base: tige), contrat)
        }
        XCTAssertFalse(existe("\(tige)-21"), contrat)
    }

    // MARK: - Atomicité

    /// **L'écriture est un remplacement, pas une réécriture sur place.** Un lecteur qui avait ouvert
    /// le fichier continue de lire l'ancien transcript **complet** pendant et après la reprise :
    /// c'est exactement ce que garantit « fichier temporaire + remplacement », et ce qu'une
    /// réécriture tronquerait sous ses yeux.
    func testUnRemplacementNeTronqueJamaisLeFichierEnPlace() throws {
        let enCours = document(statut: .inProgress, segments: Self.grosSegments(4000))
        let ecrit = try bibliotheque.write(enCours)
        guard FileManager.default.fileExists(atPath: ecrit.path),
            let descripteur = try? FileHandle(forReadingFrom: ecrit),
            let octetsAvant = try? descripteur.readToEnd(), !octetsAvant.isEmpty
        else {
            return XCTFail(contrat + " — le transcript en cours doit être écrit et lisible")
        }

        let reprise = document(statut: .inProgress, segments: Self.grosSegments(1))
        let ecrit2 = try bibliotheque.write(reprise)

        XCTAssertEqual(ecrit2, ecrit, contrat + " — la reprise écrit dans la même tige")
        try? descripteur.seek(toOffset: 0)
        XCTAssertEqual(
            try? descripteur.readToEnd(), octetsAvant,
            contrat + " — un lecteur ouvert avant le remplacement lit encore l'ancien transcript complet")
        XCTAssertNotEqual(
            try? Data(contentsOf: ecrit), octetsAvant,
            contrat + " — le fichier du disque porte bien le nouveau contenu")
        try? descripteur.close()
    }

    /// **Deux écritures concurrentes ne produisent aucun fichier partiel.** Un lecteur qui parcourt
    /// le dossier pendant les écritures ne doit jamais tomber sur un JSON tronqué, et les six
    /// transcripts écrits en parallèle doivent tous être là, lisibles, une fois les écritures
    /// terminées.
    func testDeuxEcrituresConcurrentesNeProduisentAucunFichierPartiel() throws {
        let ecrits = (0..<6).map { rang in
            document(
                titre: "Concurrent \(rang)", identite: "identite-\(rang)",
                segments: Self.grosSegments(12000))
        }
        let tiges = ecrits.map(Self.tige)

        let groupe = DispatchGroup()
        for ecrit in ecrits {
            DispatchQueue.global().async(group: groupe) { _ = try? self.bibliotheque.write(ecrit) }
        }

        // Le dossier est lu comme le ferait le panneau, pendant que ça écrit.
        var observationsPartielles = 0
        let decodeur = Self.decodeur()
        let echeance = Date().addingTimeInterval(30)
        while Date() < echeance {
            if groupe.wait(timeout: .now()) == .success { break }
            for tige in tiges {
                guard let donnees = try? Data(contentsOf: base.appendingPathComponent("\(tige).json"))
                else { continue }
                if (try? decodeur.decode(TranscriptDocument.self, from: donnees)) == nil {
                    observationsPartielles += 1
                }
            }
        }

        let manquants = tiges.filter { !existe($0) }
        XCTAssertTrue(
            manquants.isEmpty,
            contrat + " — écriture concurrencée : \(manquants.count) transcript(s) jamais écrit(s)")
        XCTAssertEqual(
            observationsPartielles, 0,
            contrat + " — un lecteur ne doit jamais voir un fichier partiel (\(observationsPartielles) observation(s))")
        let listing = bibliotheque.list()
        XCTAssertEqual(Set(listing.documents.map(\.id)), Set(tiges), contrat)
        XCTAssertEqual(listing.unreadableCount, 0, contrat)
    }

    // MARK: - La racine

    /// **Critère 14 / R3** : la racine par défaut est `Application Support/Murmure/Transcripts`, et
    /// **jamais `~/Documents`** — l'emplacement du tour 6 est abandonné parce qu'il demande une
    /// autorisation macOS qui, refusée, tuerait la fonctionnalité.
    func testLaRacineParDefautEstApplicationSupportMurmureTranscripts() {
        let racine = TranscriptLibrary.defaultBase

        XCTAssertEqual(
            racine.path, Storage.url(subfolder: "Transcripts").path,
            contrat + " — la racine passe par Storage, le seul endroit qui sait où est Application Support")
        XCTAssertTrue(racine.path.hasSuffix("/Murmure/Transcripts"), contrat)
        XCTAssertTrue(
            racine.path.hasPrefix(Storage.applicationSupport.path),
            contrat + " — la racine vit sous Application Support")
        XCTAssertFalse(
            racine.path.contains("/Documents"),
            contrat + " — R3 : jamais ~/Documents (aucune autorisation macOS à demander)")
        XCTAssertEqual(
            TranscriptLibrary().base, racine,
            contrat + " — la base par défaut est la racine réelle (rien n'est écrit ici)")
    }
}

/// Contrat rouge du lot **2/8-R** : **la tige d'un travail reprisable est réutilisée telle quelle**
/// (plan §2.4 « Collisions » et §4 lot 2/8-R ; défaut mesuré au round 2 du lot 8).
///
/// Ce que ces cas rendent impossible : `write` ne regardait que la **tige de base** pour décider
/// d'une reprise. Quand un transcript `complete` de la même source l'occupait — le cas normal de la
/// retranscription d'une vidéo déjà transcrite — **chaque** écriture du même travail suffixait une
/// tige de plus (`-2`…`-20`), laissait un document `inProgress` par écriture, et finissait par
/// `TranscriptFilenameError.allNamesTaken(base:)` (mesuré le 2026-09-22 : 7 documents `inProgress`
/// pour une source, puis l'épuisement des vingt tiges ; bibliothèque réelle à 31 `.json` et 28
/// `inProgress`).
///
/// Les règles du §2.4 que ces cas gèlent, dans cet ordre : (1) la tige du travail reprisable de la
/// même identité canonique — ``TranscriptLibrary/resumable(identity:)`` —, qu'elle soit la tige de
/// base ou une tige suffixée **et que la tige de base soit libre ou non** ; (2) sinon la tige de
/// base, si elle est libre ; (3) sinon `TranscriptFilenames.uniqueStem(in:base:)`, **inchangé** :
/// vingt documents terminés (ou étrangers) de la même source restent le seul chemin vers
/// `allNamesTaken`, et cette erreur reste explicite.
///
/// Les helpers de la classe du lot 2 (`document(...)`, `tige(...)`, `relire(...)`, `existe(...)`,
/// `bacASable(...)`) sont `private` à cette classe-là et **ne sont pas modifiés** (règle 5) : cette
/// classe porte ses propres copies, à l'identique.
///
/// Tout ce que ces cas écrivent vit sous `NSTemporaryDirectory()` : la racine réelle de
/// l'application n'est jamais touchée (ni `Application Support`, ni `Documents`).
///
/// Tous ces cas échouent sur une **assertion explicite** tant que la règle de collision du §2.4 et
/// le corps de `resumable(identity:)` n'ont pas été écrits.
final class TranscriptStemReuseTests: XCTestCase {
    private let contrat = "contrat lot 2/8-R : non implémenté"

    private var espace: URL!
    private var base: URL!
    private var bibliotheque: TranscriptLibrary!

    override func setUpWithError() throws {
        espace = try Self.bacASable("TranscriptStemReuseTests")
        base = espace.appendingPathComponent("Transcripts", isDirectory: true)
        bibliotheque = TranscriptLibrary(base: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: espace)
    }

    // MARK: - Outils (copies de ceux du lot 2, mêmes corps)

    /// Le seul endroit de cette classe qui nomme un dossier, et il ne peut pas en nommer un vrai :
    /// tout vit sous `NSTemporaryDirectory()`.
    private static func bacASable(_ nom: String) throws -> URL {
        let temporaire = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let racine = temporaire.appendingPathComponent("\(nom)-\(UUID().uuidString)", isDirectory: true)
        precondition(
            racine.resolvingSymlinksInPath().path.hasPrefix(temporaire.path),
            "un test de la bibliothèque ne travaille que sous NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        return racine
    }

    private static func decodeur() -> JSONDecoder {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        return decodeur
    }

    /// L'encodage de ``poser(_:_:id:)`` : la stratégie de dates du lot 1, celle des fichiers que la
    /// bibliothèque écrit réellement.
    private static func encodeur() -> JSONEncoder {
        let encodeur = JSONEncoder()
        encodeur.dateEncodingStrategy = .iso8601
        encodeur.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encodeur
    }

    /// Midi, dans le calendrier et le fuseau courants — la tige porte le jour **local** (lot 1), et
    /// midi ne peut basculer d'un jour à l'autre par un décalage horaire.
    private func jour(_ annee: Int = 2026, _ mois: Int = 9, _ quantieme: Int = 20) -> Date {
        var composants = DateComponents()
        composants.year = annee
        composants.month = mois
        composants.day = quantieme
        composants.hour = 12
        return Calendar(identifier: .gregorian).date(from: composants) ?? Date(timeIntervalSince1970: 0)
    }

    private func document(
        titre: String = "Démonstration",
        identite: String = "dQw4w9WgXcQ",
        statut: TranscriptStatus = .complete,
        segments: [TranscriptSegment]? = nil,
        creeLe: Date? = nil,
        id: String = "identifiant-invente"
    ) -> TranscriptDocument {
        let date = creeLe ?? jour()
        return TranscriptDocument(
            id: id,
            title: titre,
            source: TranscriptSource(
                kind: .youtube,
                url: URL(string: "https://www.youtube.com/watch?v=\(identite)")
                    ?? URL(fileURLWithPath: "/identite-invalide"),
                identity: identite),
            duration: 20,
            language: "fr",
            languageWasForced: false,
            model: "large-v3-turbo",
            createdAt: date,
            completedAt: statut == .complete ? date : nil,
            status: statut,
            segments: segments ?? [
                TranscriptSegment(start: 0, end: 10, text: "Bonjour"),
                TranscriptSegment(start: 10, end: 20, text: "tout le monde"),
            ],
            coverage: TranscriptDocument.Coverage(coveredSeconds: 20, ratio: 1),
            boundaries: [])
    }

    /// La tige que la bibliothèque **doit** employer : `<slug>-<AAAA-MM-JJ>-<id8>` du titre, de la
    /// date de création et de l'identité de la source (nommage gelé au lot 1).
    private static func tige(_ document: TranscriptDocument) -> String {
        TranscriptFilenames.stem(
            title: document.title, date: document.createdAt, identity: document.source.identity)
    }

    private func existe(_ tige: String, _ extensionFichier: String = "json") -> Bool {
        FileManager.default.fileExists(
            atPath: base.appendingPathComponent("\(tige).\(extensionFichier)").path)
    }

    /// Ce que le Finder montrerait à Louis : les noms des fichiers de la racine, triés.
    private func contenuDeLaBase() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.sorted() ?? []
    }

    /// Le document relu du disque, comme le ferait le CLI (`murmure read <id>`) : décodeur ISO-8601.
    private func relire(_ tige: String) -> TranscriptDocument? {
        guard let donnees = try? Data(contentsOf: base.appendingPathComponent("\(tige).json")) else {
            return nil
        }
        return try? Self.decodeur().decode(TranscriptDocument.self, from: donnees)
    }

    /// Pose un document **directement** sous une tige donnée, sans passer par `write`.
    ///
    /// C'est la seule façon de fabriquer l'état mesuré du défaut — un `complete` sous la tige de
    /// base, un `inProgress` sous une tige suffixée — sans dépendre de l'implémentation mise à
    /// l'épreuve. Le champ `id` porte la tige (sauf mention contraire) : c'est l'invariant du §2.4,
    /// et un document dont l'`id` diffère de sa tige est compté **illisible** par `list()`.
    @discardableResult
    private func poser(
        _ tige: String, _ document: TranscriptDocument, id: String? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var pose = document
        pose.id = id ?? tige
        let fichier = base.appendingPathComponent("\(tige).json")
        try Self.encodeur().encode(pose).write(to: fichier)
        try Data(TranscriptMarkdown.render(pose).utf8)
            .write(to: base.appendingPathComponent("\(tige).md"))
        return fichier
    }

    /// Écrit en rendant l'échec visible comme une **assertion du contrat** : un `write` qui jette
    /// doit être un échec nommé de ce cas, jamais une erreur du harnais.
    private func ecrire(_ document: TranscriptDocument, _ quoi: String) -> URL? {
        do {
            return try bibliotheque.write(document)
        } catch {
            XCTFail(contrat + " — \(quoi) : write a jeté \(error)")
            return nil
        }
    }

    // MARK: - (a) Une suite d'écritures du même travail ne consomme pas les suffixes

    /// Un `complete` de la source occupe la tige de base ; **vingt** écritures successives du même
    /// travail `inProgress` rendent **la même** URL (`<base>-2.json`), le dossier ne porte que
    /// **deux** documents (le `complete` et **un** `inProgress`), aucun `<base>-3.json` …
    /// `<base>-21.json` n'apparaît, et `allNamesTaken` n'est **jamais** levée.
    func testEcrituresRepeteesDUneSourceNeConsommentPasLesSuffixes() throws {
        let termine = document()
        let tige = Self.tige(termine)
        try poser(tige, termine)
        guard relire(tige)?.status == .complete else {
            return XCTFail(contrat + " — la fixture : un transcript `complete` occupe \(tige).json")
        }

        var ecrites: [URL] = []
        for rang in 1...20 {
            let travail = document(
                statut: .inProgress,
                segments: [TranscriptSegment(start: 0, end: Double(rang), text: "unité \(rang)")])
            guard let url = ecrire(travail, "écriture \(rang)/20 du même travail") else { return }
            ecrites.append(url)
        }

        let ancree = base.appendingPathComponent("\(tige)-2.json").path
        XCTAssertEqual(ecrites.count, 20, contrat)
        XCTAssertEqual(
            Set(ecrites.map(\.path)), Set([ancree]),
            contrat + " — une seule tige, jamais vingt : toutes les écritures du même travail visent la même URL")
        XCTAssertEqual(
            contenuDeLaBase().filter { $0.hasSuffix(".json") }, ["\(tige)-2.json", "\(tige).json"],
            contrat + " — le dossier ne porte que le `complete` et un seul document `inProgress`")
        XCTAssertEqual(
            contenuDeLaBase().filter { $0.hasSuffix(".md") }, ["\(tige)-2.md", "\(tige).md"],
            contrat + " — les deux formats restent sous les deux mêmes tiges")

        let listing = bibliotheque.list()
        XCTAssertEqual(listing.documents.count, 2, contrat + " — 1 `complete` + 1 `inProgress`, pas 21")
        XCTAssertEqual(listing.unreadableCount, 0, contrat)
        // Trié par `id` : `list()` ne garantit aucun ordre (TranscriptListing.documents), et la tige
        // de base est préfixe des tiges suffixées — le tri reproduit donc l'ordre voulu.
        XCTAssertEqual(
            listing.documents.sorted { $0.id < $1.id }.map(\.status), [.complete, .inProgress],
            contrat + " — 1 `complete` + 1 `inProgress`, quel que soit l'ordre rendu par le dossier")
        XCTAssertEqual(relire(tige)?.status, .complete, contrat + " — le `complete` d'origine n'est jamais écrasé")
        // Contrôle positif : la tige ancrée porte bien le contenu de la dernière écriture.
        XCTAssertEqual(
            relire("\(tige)-2")?.segments.last?.end ?? -1, 20,
            contrat + " — la 20e écriture est le contenu présent sous la tige ancrée")
    }

    // MARK: - (b) L'ancre gagne même quand la tige de base est libre

    /// Un `inProgress` vit en `<base>-2` et rien n'occupe `<base>` : l'écriture du même travail vise
    /// `<base>-2`, et le dossier ne porte qu'**un** document. C'est la règle 1 du §2.4 appliquée
    /// seule : l'ancre du travail en cours décide de la tige, pas la première tige libre.
    func testLeDocumentReprisableAncreLaTigeMemeSiLaTigeDeBaseEstLibre() throws {
        let travail = document(
            statut: .inProgress, segments: [TranscriptSegment(start: 0, end: 5, text: "déjà transcrit")])
        let tige = Self.tige(travail)
        try poser("\(tige)-2", travail)
        guard !existe(tige), existe("\(tige)-2") else {
            return XCTFail(contrat + " — la fixture : le reprisable est en \(tige)-2, la tige de base est libre")
        }

        guard let reprisable = bibliotheque.resumable(identity: travail.source.identity) else {
            return XCTFail(
                contrat + " — resumable(identity:) rend le travail reprisable de cette identité canonique")
        }
        XCTAssertEqual(reprisable.id, "\(tige)-2", contrat + " — le plus récent travail en cours de cette source")

        guard let ecrit = ecrire(travail, "l'écriture du même travail") else { return }

        XCTAssertEqual(
            ecrit.path, base.appendingPathComponent("\(tige)-2.json").path,
            contrat + " — l'ancre du travail reprisable gagne sur une tige de base libre")
        XCTAssertFalse(existe(tige), contrat + " — la tige de base libre n'est pas prise par la reprise")
        let listing = bibliotheque.list()
        XCTAssertEqual(listing.documents.count, 1, contrat + " — un seul document pour cette source")
        XCTAssertEqual(listing.documents.map(\.id), ["\(tige)-2"], contrat)
        XCTAssertEqual(listing.documents.map(\.status), [.inProgress], contrat)
    }

    // MARK: - (c) Un nouveau travail après deux terminés prend la tige suivante (garde-fou)

    /// `complete` en `<base>` **et** en `<base>-2` : le nouveau travail écrit en `<base>-3`, et ses
    /// écritures suivantes y restent (3 documents). La règle 3 reste la bonne pour le **premier**
    /// écrit d'un travail qui n'a rien à reprendre.
    func testUnNouveauTravailApresDeuxTerminesPrendLaTigeSuivante() throws {
        let premier = document()
        let tige = Self.tige(premier)
        try poser(tige, premier)
        try poser("\(tige)-2", document())
        guard relire(tige)?.status == .complete, relire("\(tige)-2")?.status == .complete else {
            return XCTFail(contrat + " — la fixture : deux transcripts terminés occupent \(tige) et \(tige)-2")
        }

        let nouveau = document(
            statut: .inProgress, segments: [TranscriptSegment(start: 0, end: 3, text: "unité 0")])
        var ecrites: [URL] = []
        for rang in 1...2 {
            guard let url = ecrire(nouveau, "écriture \(rang)/2 du nouveau travail") else { return }
            ecrites.append(url)
        }

        let suivante = base.appendingPathComponent("\(tige)-3.json").path
        XCTAssertEqual(
            ecrites.map(\.path), [suivante, suivante],
            contrat + " — le nouveau travail prend la tige suivante, et ses écritures suivantes y restent")
        XCTAssertFalse(existe("\(tige)-4"), contrat + " — un second suffixe n'est pas consommé")
        let listing = bibliotheque.list()
        XCTAssertEqual(listing.documents.count, 3, contrat + " — deux terminés + un seul reprisable")
        XCTAssertEqual(listing.unreadableCount, 0, contrat)
        // Même forme qu'au cas (a) : trié par `id`, jamais par l'ordre rendu par `list()`.
        XCTAssertEqual(
            listing.documents.sorted { $0.id < $1.id }.map(\.status),
            [.complete, .complete, .inProgress],
            contrat + " — 2 `complete` + 1 `inProgress`, quel que soit l'ordre rendu par le dossier")
    }

    // MARK: - (d) Vingt terminés épuisent les suffixes, et l'échec reste explicite (garde-fou)

    /// Vingt documents `complete` de la même source occupant `<base>` … `<base>-20` : l'écriture
    /// **lève** `TranscriptFilenameError.allNamesTaken(base:)` et n'écrase rien. C'est le seul
    /// chemin qui reste vers cette erreur — un `complete` n'est jamais reprisable, donc aucune suite
    /// d'écritures du même travail ne peut l'atteindre.
    func testVingtTerminesEpuisentLesSuffixesEtLEchecResteExplicite() throws {
        let modele = document()
        let tige = Self.tige(modele)
        for rang in 0...19 {
            let candidat = rang == 0 ? tige : "\(tige)-\(rang + 1)"
            try poser(candidat, modele)
        }
        guard let octetsDeLaBase = try? Data(contentsOf: base.appendingPathComponent("\(tige).json")),
            bibliotheque.list().documents.count == 20
        else {
            return XCTFail(contrat + " — la fixture : vingt transcripts terminés occupent \(tige) … \(tige)-20")
        }

        XCTAssertThrowsError(
            try bibliotheque.write(
                document(statut: .inProgress, segments: [TranscriptSegment(start: 0, end: 3, text: "unité 0")])),
            contrat + " — vingt tiges terminées : l'échec est explicite"
        ) { erreur in
            XCTAssertEqual(erreur as? TranscriptFilenameError, .allNamesTaken(base: tige), contrat)
        }

        XCTAssertEqual(
            try? Data(contentsOf: base.appendingPathComponent("\(tige).json")), octetsDeLaBase,
            contrat + " — l'échec n'écrase rien")
        XCTAssertEqual(contenuDeLaBase().filter { $0.hasSuffix(".json") }.count, 20, contrat)
        XCTAssertFalse(existe("\(tige)-21"), contrat + " — aucun vingt-et-unième fichier n'est écrit")
        let listing = bibliotheque.list()
        XCTAssertEqual(listing.documents.count, 20, contrat)
        XCTAssertEqual(listing.unreadableCount, 0, contrat)
    }

    // MARK: - (e) L'invariant du §2.4 : l'id d'un document est la tige de son fichier

    /// `<base>.json` dont le champ `id` vaut `"autre-tige"` : `list().unreadableCount == 1` et
    /// `transcript(id: base) == nil`. Un document qui déclare un autre identifiant que sa tige est
    /// **illisible** — sans quoi une tuile (critère 16) ou un `murmure read <id>` (critère 20)
    /// désignerait autre chose que le fichier qu'on croit.
    func testUnIdentifiantQuiNeCollePasAuNomDuFichierEstCompteIllisible() throws {
        let menteur = document(
            statut: .inProgress, segments: [TranscriptSegment(start: 0, end: 4, text: "mensonge")])
        let tige = Self.tige(menteur)
        try poser(tige, menteur, id: "autre-tige")
        guard existe(tige) else {
            return XCTFail(contrat + " — la fixture : \(tige).json existe sur disque")
        }

        let listing = bibliotheque.list()

        XCTAssertEqual(
            listing.unreadableCount, 1,
            contrat + " — l'invariant du §2.4 : l'`id` d'un document est la tige de son fichier")
        XCTAssertNil(
            bibliotheque.transcript(id: tige),
            contrat + " — transcript(id:) ne rend pas un fichier qui déclare un autre identifiant")
        XCTAssertTrue(listing.documents.isEmpty, contrat + " — ce fichier n'est pas un transcript de la bibliothèque")
    }

    // MARK: - `resumable(identity:)` : la sélection n'existe qu'ici

    /// Le travail reprisable est le **plus récent** des documents `inProgress`/`failed` de cette
    /// identité canonique — `createdAt` d'abord, puis `segments.last?.end` à date égale — et un
    /// `complete` n'est jamais reprisable. C'est la sélection que le runner délègue (plan §4
    /// lot 2/8-R) : elle décide de la tige sur laquelle une reprise écrit, et sa date de référence
    /// est la même que celle du `write` qui l'écrira.
    func testResumableRendLePlusRecentDesTravauxNonTermines() throws {
        let identite = "dQw4w9WgXcQ"
        let passe = document(
            identite: identite, statut: .inProgress,
            segments: [TranscriptSegment(start: 0, end: 5, text: "unité 0")],
            creeLe: jour(2026, 9, 20))
        let reprisable = document(
            identite: identite, statut: .failed,
            segments: [TranscriptSegment(start: 0, end: 30, text: "unité 1")],
            creeLe: jour(2026, 9, 21))
        let termine = document(
            identite: identite, statut: .complete,
            segments: [TranscriptSegment(start: 0, end: 60, text: "unité 2")],
            creeLe: jour(2026, 9, 22))
        try poser(Self.tige(passe), passe)
        try poser(Self.tige(reprisable), reprisable)
        try poser(Self.tige(termine), termine)
        guard bibliotheque.list().documents.count == 3 else {
            return XCTFail(contrat + " — la fixture : trois documents de la même source")
        }

        guard let retenu = bibliotheque.resumable(identity: identite) else {
            return XCTFail(contrat + " — resumable(identity:) doit rendre le travail reprisable de cette source")
        }
        XCTAssertEqual(
            retenu.id, Self.tige(reprisable),
            contrat + " — le plus récent des travaux `inProgress`/`failed` : un `complete` n'est jamais reprisable")

        // À date de création égale, c'est le travail le plus avancé qui ancre (`segments.last?.end`).
        let memeDate = document(
            identite: identite, statut: .inProgress,
            segments: [TranscriptSegment(start: 0, end: 90, text: "unité 3")],
            creeLe: jour(2026, 9, 21))
        try poser("\(Self.tige(reprisable))-2", memeDate)

        XCTAssertEqual(
            bibliotheque.resumable(identity: identite)?.id ?? "", "\(Self.tige(reprisable))-2",
            contrat + " — à date de création égale, le travail le plus avancé (segments.last?.end)")
    }
}
