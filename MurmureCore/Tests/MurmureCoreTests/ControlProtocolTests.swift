import Foundation
import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 11, première moitié : **le protocole de contrôle du CLI** (plan §2.5,
/// §4 lot 11, décision R4 du §0, critères 12 et 20).
///
/// Ce que ces tests gèlent, et ce que la carte `dev` `t_6879ee2e` doit faire passer :
/// - **critère 20 « commande locale, retour 0 »** : `list`, `read` et `version` lisent le dossier
///   et retournent `0` **application fermée** — aucune de ces commandes ne demande quoi que ce soit
///   au socket (`ControlRoute.local`) ;
/// - **critère 21 (lecture)** : un transcript listé porte les chemins absolus de **ses deux**
///   fichiers, la même tige ;
/// - **critère 12** : `--language xx` est porté par la requête `transcribe` ; sans l'option, la
///   requête ne force **aucune** langue (la langue du document fait foi à la reprise, §2.4/N1) ;
/// - **R4** : le socket vit dans `Application Support/Murmure/`, en `0600`, dans un répertoire
///   `0700`, et seul un pair du **même UID** peut commander ;
/// - **les cas obligatoires de la carte** : une requête inconnue ou mal formée rend un code d'usage
///   (jamais un plantage), une réponse **tronquée** n'est jamais acceptée comme valide, un `read`
///   d'un transcript supprimé échoue proprement.
///
/// Tous ces tests échouent sur une **assertion explicite** (message « contrat lot 11 : non
/// implémenté ») tant que les corps sentinelles de `ControlProtocol.swift` n'ont pas été remplacés —
/// jamais sur une erreur de compilation (plan §7.1, règle 4).
///
/// Rien ici n'ouvre de socket : le contrat porte la **décision** (routage, codes, mise en ligne),
/// le transport est l'adaptateur du câblage.
final class ControlProtocolTests: XCTestCase {
    private let contrat = "contrat lot 11 : non implémenté"

    private var espace: URL!
    private var base: URL!
    private var bibliotheque: TranscriptLibrary!

    override func setUpWithError() throws {
        espace = try Self.bacASable("ControlProtocolTests")
        base = espace.appendingPathComponent("Transcripts", isDirectory: true)
        bibliotheque = TranscriptLibrary(base: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: espace)
    }

    // MARK: - Outils

    /// Le seul endroit du fichier qui nomme un dossier, et il ne peut pas en nommer un vrai : tout
    /// vit sous `NSTemporaryDirectory()`. Ni `Application Support/Murmure` ni `Documents/Murmure`
    /// ne sont approchés par ces tests.
    private static func bacASable(_ nom: String) throws -> URL {
        let temporaire = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let racine = temporaire.appendingPathComponent("\(nom)-\(UUID().uuidString)", isDirectory: true)
        precondition(
            racine.resolvingSymlinksInPath().path.hasPrefix(temporaire.path),
            "un test du protocole de contrôle ne travaille que sous NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        return racine
    }

    private static func decodeur() -> JSONDecoder {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        return decodeur
    }

    /// Le Markdown écrit à côté du JSON : sa lecture par `read --format md` est vérifiée **au
    /// contenu**, pas au chemin seulement.
    private func contenuMarkdown(_ tige: String) -> String {
        "# \(tige)\n\nPremier paragraphe du transcript.\n\nSecond paragraphe, un peu plus long.\n"
    }

    /// Écrit un transcript **directement sur disque**, sous une tige choisie : ces tests portent sur
    /// la lecture du dossier (§2.4 : « l'index, c'est le dossier »), donc ils ne dépendent pas de la
    /// règle de nommage de la bibliothèque — et n'en figent aucune (révision 8 du plan).
    @discardableResult
    private func ecrire(
        _ tige: String, titre: String = "Démonstration", statut: TranscriptStatus = .complete
    ) throws -> TranscriptDocument {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let document = TranscriptDocument(
            id: tige,
            title: titre,
            source: TranscriptSource(kind: .file, path: "/tmp/source.wav", identity: "identite-\(tige)"),
            duration: 20,
            language: "fr",
            languageWasForced: false,
            model: "large-v3-turbo",
            createdAt: date,
            completedAt: statut == .complete ? date.addingTimeInterval(20) : nil,
            status: statut,
            segments: [
                TranscriptSegment(start: 0, end: 10, text: "Bonjour"),
                TranscriptSegment(start: 10, end: 20, text: "tout le monde"),
            ],
            coverage: TranscriptDocument.Coverage(coveredSeconds: 20, ratio: 1),
            boundaries: [])
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Self.encodeur().encode(document)
            .write(to: base.appendingPathComponent("\(tige).json"))
        try Data(contenuMarkdown(tige).utf8)
            .write(to: base.appendingPathComponent("\(tige).md"))
        return document
    }

    private static func encodeur() -> JSONEncoder {
        let encodeur = JSONEncoder()
        encodeur.dateEncodingStrategy = .iso8601
        return encodeur
    }

    /// Sème un `.json` **illisible** à la racine : il doit être ignoré **et compté** par `list`
    /// (§2.4, critère 14), jamais fatal.
    private func semerIllisible(_ tige: String) throws {
        try Data("{ \"id\": \"\(tige)\",".utf8)
            .write(to: base.appendingPathComponent("\(tige).json"))
    }

    /// Exécute un appel du contrat qui peut jeter. Une levée devient une **assertion explicite**
    /// (message du contrat) : c'est ce que §7.1 règle 4 exige d'un rouge, et c'est aussi ce qui
    /// évite qu'une sentinelle qui jette fasse sortir le test par une erreur non attribuée.
    private func resultat<T>(_ objet: String, _ corps: () throws -> T) -> T? {
        do {
            return try corps()
        } catch {
            XCTFail(contrat + " — \(objet) a levé \(error)")
            return nil
        }
    }

    /// Vérifie qu'un appel est **refusé** par le cas attendu, et que ce refus sort en **code
    /// d'usage** (plan §2.5 : `2` usage) — jamais par un plantage.
    private func verifierRefus<T>(
        _ objet: String, _ attendu: ControlProtocolError, _ corps: () throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try corps(), contrat + " — \(objet) : doit être refusé", file: file, line: line
        ) { erreur in
            XCTAssertEqual(
                erreur as? ControlProtocolError, attendu,
                contrat + " — \(objet) : erreur attendue \(attendu), obtenue \(erreur)",
                file: file, line: line)
            XCTAssertEqual(
                ControlProtocol.exitCode(for: erreur), .usage,
                contrat + " — \(objet) : un refus mal formé sort en code d'usage (2)",
                file: file, line: line)
        }
    }

    /// La racine de la bibliothèque **réelle** de l'application, telle que R4 la nomme, recalculée
    /// ici sans passer par `Storage` : c'est ce qui rend l'attente indépendante de l'implémentation.
    private var cheminAttenduDuSocket: String {
        "\(NSHomeDirectory())/Library/Application Support/Murmure/control.sock"
    }

    // MARK: - Critère 20 : les commandes locales, application fermée

    /// Cr 20 — `list` lit le dossier et retourne **0**, application fermée : deux transcripts
    /// lisibles, un `.json` illisible **compté**, le dossier lu annoncé.
    func testCritere20_ListLitLeDossierEtRetourneZero() throws {
        try ecrire("bonjour-2026-09-22-aaaaaaaa", titre: "Bonjour")
        try ecrire("conference-2026-09-21-bbbbbbbb", titre: "Conférence", statut: .inProgress)
        try semerIllisible("casse-2026-09-20-cccccccc")

        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .list), library: bibliotheque)

        XCTAssertEqual(
            reponse.exitCode, .success,
            contrat + " — critère 20 : `list` doit retourner 0 en succès")
        XCTAssertEqual(
            reponse.exitCode.rawValue, 0,
            contrat + " — critère 20 : le code de succès vaut 0 (reçu \(reponse.exitCode.rawValue))")
        XCTAssertEqual(
            reponse.version, ControlProtocol.version,
            contrat + " — la réponse porte la version du protocole")
        XCTAssertNil(
            reponse.error, contrat + " — un succès ne porte pas de message d'échec")
        guard let listing = reponse.listing else {
            return XCTFail(contrat + " — `list` doit rendre la liste des transcripts")
        }
        XCTAssertEqual(
            listing.directory, base.path,
            contrat + " — critère 20 : `list` annonce le dossier qu'il a lu")
        XCTAssertEqual(
            listing.transcripts.map(\.id).sorted(),
            ["bonjour-2026-09-22-aaaaaaaa", "conference-2026-09-21-bbbbbbbb"],
            contrat + " — critère 14 : la liste est exactement ce que le dossier contient de lisible")
        XCTAssertEqual(
            listing.unreadableCount, 1,
            contrat + " — critère 14 : un `.json` illisible est ignoré ET compté (jamais fatal)")
    }

    /// Cr 21 (lecture) — chaque transcript listé porte les **deux** chemins absolus de sa tige, et
    /// les deux fichiers existent : « un agent qui trouve l'un trouve l'autre sans index » (§2.4).
    func testCritere21_ChaqueTranscriptListePorteLesDeuxCheminsDeSaTige() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .list), library: bibliotheque)
        guard let resume = reponse.listing?.transcripts.first else {
            return XCTFail(contrat + " — `list` doit rendre le transcript écrit")
        }

        XCTAssertEqual(
            resume.id, tige,
            contrat + " — l'id listé est la tige du fichier (§2.4, invariant d'id)")
        XCTAssertEqual(
            resume.jsonPath, base.appendingPathComponent("\(tige).json").path,
            contrat + " — le chemin du JSON est absolu et construit sur la racine lue")
        XCTAssertEqual(
            resume.markdownPath, base.appendingPathComponent("\(tige).md").path,
            contrat + " — le chemin du Markdown est celui de la MÊME tige")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resume.jsonPath),
            contrat + " — le JSON annoncé doit exister sur disque")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resume.markdownPath),
            contrat + " — le Markdown annoncé doit exister sur disque")
        XCTAssertEqual(
            resume.status, .complete, contrat + " — le statut listé est celui du document")
    }

    /// Cr 20 — `read` sans `--format` rend **le document** du disque.
    func testCritere20_ReadRendLeDocumentDuDisque() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .read, source: tige), library: bibliotheque)

        XCTAssertEqual(
            reponse.exitCode, .success,
            contrat + " — critère 20 : `read` d'un transcript existant retourne 0")
        guard let document = reponse.document else {
            return XCTFail(contrat + " — `read` doit rendre le document, pas un texte vide")
        }
        XCTAssertEqual(document.id, tige, contrat + " — le document rendu est celui de l'id demandé")
        XCTAssertEqual(document.title, "Bonjour", contrat + " — le titre vient du fichier")
        XCTAssertEqual(
            document.segments.count, 2, contrat + " — les segments viennent du fichier")
        XCTAssertNil(
            reponse.text,
            contrat + " — `read` sans `--format` rend le document JSON, pas le Markdown")
        XCTAssertNil(reponse.error, contrat + " — un succès ne porte pas de message d'échec")
    }

    /// Cr 20 — `read --format md` rend **le contenu du `<tige>.md`**.
    func testCritere20_ReadFormatMarkdownRendLeContenuDuFichierMd() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .read, source: tige, format: .md), library: bibliotheque)

        XCTAssertEqual(
            reponse.exitCode, .success, contrat + " — critère 20 : `read --format md` retourne 0")
        XCTAssertEqual(
            reponse.text, contenuMarkdown(tige),
            contrat + " — `read --format md` rend le contenu du fichier Markdown de la même tige")
        XCTAssertNil(reponse.error, contrat + " — un succès ne porte pas de message d'échec")
    }

    /// Cr 20 + carte QA L11 — **`read` d'un transcript supprimé échoue proprement** : code d'échec,
    /// message, aucun document — pas un plantage, pas un document vide.
    func testCritere20_ReadDUnTranscriptSupprimeEchoueProprement() throws {
        let tige = "disparu-2026-09-22-dddddddd"
        try ecrire(tige, titre: "Disparu")
        try FileManager.default.removeItem(at: base.appendingPathComponent("\(tige).json"))
        try FileManager.default.removeItem(at: base.appendingPathComponent("\(tige).md"))

        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .read, source: tige), library: bibliotheque)

        XCTAssertEqual(
            reponse.exitCode, .jobFailed,
            contrat + " — un `read` d'un transcript disparu sort en travail en échec (1)"
                + " (reçu \(reponse.exitCode.rawValue))")
        XCTAssertNil(
            reponse.document,
            contrat + " — un transcript disparu ne rend pas de document")
        XCTAssertNil(
            reponse.text, contrat + " — un transcript disparu ne rend pas de texte")
        guard let message = reponse.error else {
            return XCTFail(contrat + " — un échec sans phrase est un échec silencieux")
        }
        XCTAssertFalse(
            message.isEmpty, contrat + " — le message d'échec doit dire quelque chose")
        XCTAssertEqual(
            ControlProtocol.exitCode(for: TranscriptQueryError.notFound(query: tige)), .jobFailed,
            contrat + " — un transcript introuvable n'est pas une faute d'usage : code 1, pas 2")
    }

    /// Cr 20 — une commande que la table envoie à l'application, sans application, sort en **3** ;
    /// et la table de routage est explicite : `list`, `read`, `version` **sans** l'app.
    func testCritere20_LesCommandesLocalesSontSansApplicationEtLesAutresSortentEnTrois() throws {
        XCTAssertEqual(
            ControlProtocol.route(for: .list), .local,
            contrat + " — critère 20 : `list` lit le dossier, elle ne dépend pas de l'app")
        XCTAssertEqual(
            ControlProtocol.route(for: .read), .local,
            contrat + " — critère 20 : `read` lit le dossier, elle ne dépend pas de l'app")
        XCTAssertEqual(
            ControlProtocol.route(for: .version), .local,
            contrat + " — critère 20 : `version` ne dépend pas de l'app")
        XCTAssertEqual(
            ControlProtocol.route(for: .transcribe), .app,
            contrat + " — `transcribe` remet le travail à l'application, par le socket")
        XCTAssertEqual(
            ControlProtocol.route(for: .status), .app,
            contrat + " — `status` décrit la file de l'application, par le socket")

        let statut = ControlProtocol.respondLocally(
            to: ControlRequest(command: .status), library: bibliotheque)
        XCTAssertEqual(
            statut.exitCode, .appUnreachable,
            contrat + " — une commande servie par l'app, sans app, sort en 3"
                + " (reçu \(statut.exitCode.rawValue))")
        XCTAssertFalse(
            (statut.error ?? "").isEmpty,
            contrat + " — l'app injoignable doit être dite, pas rendue en succès vide")
        XCTAssertEqual(
            ControlProtocol.exitCode(for: ControlProtocolError.appUnreachable), .appUnreachable,
            contrat + " — le seul cas qui rend 3 est l'app injoignable")
    }

    /// Cr 20 — `version` répond en succès avec un texte non vide.
    func testCritere20_VersionRepondUnTexteNonVideEnSucces() {
        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .version), library: bibliotheque)

        XCTAssertEqual(
            reponse.exitCode, .success, contrat + " — critère 20 : `version` retourne 0")
        guard let texte = reponse.text else {
            return XCTFail(contrat + " — `version` doit imprimer la version du CLI")
        }
        XCTAssertFalse(texte.isEmpty, contrat + " — `version` imprime quelque chose")
        XCTAssertNil(reponse.error, contrat + " — `version` n'échoue pas")
    }

    // MARK: - Usage : jamais un plantage

    /// Carte QA L11 — une **commande inconnue** rend un code d'usage, pas un plantage. Le contrôle
    /// positif est dans le même test : une ligne valide se lit, sinon un décodeur qui refuse tout
    /// passerait ce cas.
    func testUsage_UneCommandeInconnueDonneUnCodeDUsage() throws {
        let inconnue = Data("{\"version\":1,\"command\":\"frobnicate\"}\n".utf8)
        verifierRefus("requête de commande inconnue", .unknownCommand("frobnicate"), {
            try ControlProtocol.decodeRequest(line: inconnue)
        })

        let valide = Data("{\"version\":1,\"command\":\"list\"}\n".utf8)
        guard let requete = resultat("decodeRequest d'une ligne valide", {
            try ControlProtocol.decodeRequest(line: valide)
        }) else { return }
        XCTAssertEqual(
            requete.command, .list,
            contrat + " — une ligne valide doit se lire (contrôle positif du refus ci-dessus)")
        XCTAssertEqual(
            requete.version, ControlProtocol.version,
            contrat + " — la version lue est celle du protocole")
    }

    /// Carte QA L11 — une **ligne mal formée** rend un code d'usage, pas un plantage : ligne vide,
    /// JSON qui n'est pas un objet, objet auquel il manque `command`, UTF-8 invalide.
    func testUsage_UneLigneMalFormeeDonneUnCodeDUsage() throws {
        verifierRefus("ligne vide", .emptyLine, {
            try ControlProtocol.decodeRequest(line: Data())
        })

        XCTAssertThrowsError(
            try ControlProtocol.decodeRequest(line: Data("pas du json\n".utf8)),
            contrat + " — une ligne qui n'est pas du JSON doit être refusée"
        ) { erreur in
            guard case .malformedLine? = erreur as? ControlProtocolError else {
                return XCTFail(contrat + " — attendu .malformedLine, obtenu \(erreur)")
            }
            XCTAssertEqual(
                ControlProtocol.exitCode(for: erreur), .usage,
                contrat + " — une ligne illisible sort en code d'usage (2)")
        }

        XCTAssertThrowsError(
            try ControlProtocol.decodeRequest(line: Data("[1,2]\n".utf8)),
            contrat + " — un tableau JSON n'est pas un message"
        ) { erreur in
            guard case .malformedLine? = erreur as? ControlProtocolError else {
                return XCTFail(contrat + " — attendu .malformedLine, obtenu \(erreur)")
            }
        }

        XCTAssertThrowsError(
            try ControlProtocol.decodeRequest(line: Data("{\"version\":1}\n".utf8)),
            contrat + " — une requête sans `command` doit être refusée"
        ) { erreur in
            guard case .malformedLine? = erreur as? ControlProtocolError else {
                return XCTFail(contrat + " — attendu .malformedLine, obtenu \(erreur)")
            }
        }

        verifierRefus("octets qui ne sont pas de l'UTF-8", .notUTF8, {
            try ControlProtocol.decodeRequest(line: Data([0xFF, 0xFE, 0x0A]))
        })
    }

    /// Cr 20 — les arguments mal formés sont refusés en **usage** : opérande manquant, opérande
    /// excédentaire, option inconnue, valeur d'option hors des valeurs admises.
    func testUsage_LesArgumentsMalFormesSontRefusesEnUsage() throws {
        verifierRefus("aucune commande", .noCommand, {
            try ControlProtocol.request(fromArguments: [])
        })
        verifierRefus("commande inconnue", .unknownCommand("frobnicate"), {
            try ControlProtocol.request(fromArguments: ["frobnicate"])
        })
        verifierRefus("`read` sans opérande", .missingOperand(.read), {
            try ControlProtocol.request(fromArguments: ["read"])
        })
        verifierRefus("`transcribe` sans opérande", .missingOperand(.transcribe), {
            try ControlProtocol.request(fromArguments: ["transcribe"])
        })
        verifierRefus("opérande excédentaire", .unexpectedOperand("en trop"), {
            try ControlProtocol.request(fromArguments: ["list", "en trop"])
        })
        verifierRefus("option inconnue", .unknownOption("--bavard"), {
            try ControlProtocol.request(fromArguments: ["read", "tige", "--bavard"])
        })
        verifierRefus("valeur d'option invalide", .invalidValue(option: "--format", value: "xml"), {
            try ControlProtocol.request(fromArguments: ["read", "tige", "--format", "xml"])
        })
    }

    // MARK: - Protocole versionné, une ligne par message

    /// §2.5 — **JSON par ligne** : une requête, une réponse, chacune terminée par un saut de ligne,
    /// sans saut de ligne à l'intérieur ; deux messages collés ne sont pas un message.
    func testProtocole_UnMessageParLigneTermineParUnSautDeLigne() throws {
        guard let ligneRequete = resultat("encodeRequest", {
            try ControlProtocol.encodeRequest(ControlRequest(command: .list))
        }) else { return }
        XCTAssertEqual(
            ligneRequete.filter { $0 == 0x0A }.count, 1,
            contrat + " — une requête tient sur une seule ligne")
        XCTAssertEqual(
            ligneRequete.last, 0x0A,
            contrat + " — la ligne est terminée par son saut de ligne (c'est ce qui rend la"
                + " troncature détectable)")
        XCTAssertEqual(
            resultat("decodeRequest de la ligne écrite", {
                try ControlProtocol.decodeRequest(line: ligneRequete)
            }),
            ControlRequest(command: .list),
            contrat + " — la ligne écrite doit se relire à l'identique")
        XCTAssertThrowsError(
            try ControlProtocol.decodeRequest(line: ligneRequete + ligneRequete),
            contrat + " — deux messages collés ne sont pas un message"
        ) { erreur in
            // Le cas est vérifié par **forme**, pas par égalité : le texte du motif est libre.
            guard let protocole = erreur as? ControlProtocolError,
                case .malformedLine = protocole
            else {
                return XCTFail(contrat + " — attendu .malformedLine, obtenu \(erreur)")
            }
            XCTAssertEqual(
                ControlProtocol.exitCode(for: erreur), .usage,
                contrat + " — un message illisible sort en code d'usage (2)")
        }
    }

    /// Carte QA L11 — **une réponse tronquée n'est jamais acceptée comme valide**. Le contrôle
    /// positif est dans le même test, et il porte le poids : *aucune* troncature ne doit passer,
    /// alors que la ligne complète, elle, doit se relire.
    func testProtocole_UneReponseTronqueeNestJamaisAccepteeCommeValide() throws {
        let attendue = ControlResponse(
            exitCode: .success,
            listing: ControlListing(
                directory: base.path,
                transcripts: [
                    ControlTranscriptSummary(
                        id: "bonjour-2026-09-22-aaaaaaaa", title: "Bonjour", status: .complete,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 20,
                        jsonPath: base.appendingPathComponent("bonjour-2026-09-22-aaaaaaaa.json").path,
                        markdownPath: base.appendingPathComponent("bonjour-2026-09-22-aaaaaaaa.md")
                            .path)
                ],
                unreadableCount: 0),
            text: "ok")

        guard let ligne = resultat("encodeResponse", {
            try ControlProtocol.encodeResponse(attendue)
        }) else { return }
        XCTAssertFalse(ligne.isEmpty, contrat + " — encodeResponse doit produire une ligne")
        XCTAssertEqual(
            ligne.last, 0x0A, contrat + " — la ligne de réponse est terminée par un saut de ligne")
        XCTAssertEqual(
            resultat("decodeResponse de la ligne complète") {
                try ControlProtocol.decodeResponse(line: ligne)
            },
            attendue, contrat + " — la ligne complète doit se relire à l'identique")

        // La troncature nommée : la ligne privée de son terminateur.
        XCTAssertThrowsError(
            try ControlProtocol.decodeResponse(line: ligne.dropLast()),
            contrat + " — une réponse sans son terminateur est une réponse tronquée"
        ) { erreur in
            XCTAssertEqual(
                erreur as? ControlProtocolError, .truncatedLine,
                contrat + " — attendu .truncatedLine, obtenu \(erreur)")
        }

        // Et la propriété, pour toutes les longueurs : **aucun préfixe** n'est une réponse valide.
        for longueur in 0..<ligne.count {
            XCTAssertThrowsError(
                try ControlProtocol.decodeResponse(line: ligne.prefix(longueur)),
                contrat + " — une réponse tronquée à \(longueur) octet(s) ne doit jamais être"
                    + " acceptée comme valide")
        }
    }

    /// §2.5 — la version est un champ **obligatoire** des deux messages : une version inconnue est
    /// refusée des deux côtés, jamais interprétée au mieux.
    func testVersion_UneVersionInconnueEstRefuseeDansLesDeuxSens() throws {
        verifierRefus("requête d'une autre version", .unsupportedVersion(2), {
            try ControlProtocol.decodeRequest(line: Data("{\"version\":2,\"command\":\"list\"}\n".utf8))
        })

        guard let ligneReponse = resultat("encodeResponse(version 2)", {
            try ControlProtocol.encodeResponse(ControlResponse(version: 2, exitCode: .success))
        }) else { return }
        XCTAssertThrowsError(
            try ControlProtocol.decodeResponse(line: ligneReponse),
            contrat + " — une réponse d'une autre version doit être refusée"
        ) { erreur in
            XCTAssertEqual(
                erreur as? ControlProtocolError, .unsupportedVersion(2),
                contrat + " — attendu .unsupportedVersion(2), obtenu \(erreur)")
            XCTAssertEqual(
                ControlProtocol.exitCode(for: erreur), .usage,
                contrat + " — un message d'une version inconnue sort en code d'usage (2)")
        }
    }

    // MARK: - Critère 12 : la langue optionnelle

    /// Cr 12 — `--language xx` est porté par la requête `transcribe` ; **sans** l'option, la
    /// requête ne force aucune langue (le document de reprise fait foi, §2.4/N1 : jamais de
    /// re-détection).
    func testCritere12_LaLangueOptionnelleEstPorteeParLaRequete() throws {
        guard let avec = resultat("request(fromArguments: --language fr)", {
            try ControlProtocol.request(
                fromArguments: ["transcribe", "https://exemple.test/v", "--language", "fr"])
        }) else { return }
        XCTAssertEqual(avec.command, .transcribe, contrat + " — la commande est `transcribe`")
        XCTAssertEqual(avec.source, "https://exemple.test/v", contrat + " — la source est l'opérande")
        XCTAssertEqual(
            avec.language, "fr",
            contrat + " — critère 12 : `--language fr` est transmis par la requête")

        guard let sans = resultat("request(fromArguments: sans --language)", {
            try ControlProtocol.request(fromArguments: ["transcribe", "https://exemple.test/v"])
        }) else { return }
        XCTAssertNil(
            sans.language,
            contrat + " — critère 12 : sans option, la requête ne force aucune langue")

        guard let complet = resultat("request(fromArguments: options complètes)", {
            try ControlProtocol.request(fromArguments: [
                "transcribe", "chemin/local.wav", "--language", "en", "--wait",
                "--output", "/tmp/sortie", "--format", "md", "--json",
            ])
        }) else { return }
        XCTAssertEqual(complet.language, "en", contrat + " — la langue suit l'option, pas un défaut")
        XCTAssertTrue(complet.wait, contrat + " — `--wait` est transmis")
        XCTAssertEqual(complet.output, "/tmp/sortie", contrat + " — `--output` est transmis")
        XCTAssertEqual(complet.format, .md, contrat + " — `--format md` est transmis")
        XCTAssertTrue(complet.json, contrat + " — `--json` est transmis")

        verifierRefus("`--language` sans valeur", .optionRequiresValue("--language"), {
            try ControlProtocol.request(fromArguments: ["transcribe", "src", "--language"])
        })
    }

    /// §2.5 — les **cinq** commandes se parsent, y compris une option placée **avant** son
    /// opérande (c'est la forme que le plan écrit pour `read`).
    func testArguments_LesCinqCommandesDuCLISeParsent() throws {
        let cas: [([String], ControlRequest)] = [
            (["list"], ControlRequest(command: .list)),
            (["list", "--json"], ControlRequest(command: .list, json: true)),
            (["read", "ma-tige"], ControlRequest(command: .read, source: "ma-tige")),
            (["read", "--format", "md", "ma-tige"],
             ControlRequest(command: .read, source: "ma-tige", format: .md)),
            (["status"], ControlRequest(command: .status)),
            (["version"], ControlRequest(command: .version)),
            (["transcribe", "/tmp/local.wav"], ControlRequest(command: .transcribe, source: "/tmp/local.wav")),
        ]
        for (arguments, attendue) in cas {
            guard let lue = resultat("request(fromArguments: \(arguments))", {
                try ControlProtocol.request(fromArguments: arguments)
            }) else { return }
            XCTAssertEqual(
                lue, attendue,
                contrat + " — \(arguments) doit se parser en \(attendue), obtenu \(lue)")
        }
    }

    // MARK: - R4 : le socket de contrôle

    /// R4 — le socket vit dans `Application Support/Murmure/`, en `0600`, dans un répertoire
    /// `0700` : la décision du §0, vérifiée **sans ouvrir de socket**.
    func testR4_LeSocketEstEn0600DansUnRepertoireEn0700SousApplicationSupport() {
        XCTAssertEqual(
            ControlEndpoint.socketURL.path, cheminAttenduDuSocket,
            contrat + " — R4 : le socket est `~/Library/Application Support/Murmure/control.sock`")
        XCTAssertEqual(
            ControlEndpoint.directory.path,
            "\(NSHomeDirectory())/Library/Application Support/Murmure",
            contrat + " — R4 : le répertoire du socket est `Application Support/Murmure`")
        XCTAssertEqual(
            ControlEndpoint.socketURL.deletingLastPathComponent().path,
            ControlEndpoint.directory.path,
            contrat + " — R4 : le socket est bien DANS ce répertoire")
        XCTAssertEqual(
            ControlEndpoint.socketPermissions, 0o600,
            contrat + " — R4 : permissions du socket `0600`, lu \(ControlEndpoint.socketPermissions)")
        XCTAssertEqual(
            ControlEndpoint.directoryPermissions, 0o700,
            contrat + " — R4 : permissions du répertoire `0700`, lu \(ControlEndpoint.directoryPermissions)")
    }

    /// R4 — seul un pair du **même UID** peut commander : le cas qui compte est l'autre compte de
    /// la machine, refusé.
    func testR4_SeulUnPairDuMemeUIDPeutCommander() {
        XCTAssertTrue(
            ControlEndpoint.acceptsPeer(ownUID: 501, peerUID: 501),
            contrat + " — R4 : un pair du même UID que nous est accepté")
        XCTAssertTrue(
            ControlEndpoint.acceptsPeer(ownUID: 0, peerUID: 0),
            contrat + " — R4 : le mêmeUID est accepté quel qu'il soit")
        XCTAssertFalse(
            ControlEndpoint.acceptsPeer(ownUID: 501, peerUID: 502),
            contrat + " — R4 : un autre compte de la machine est refusé")
        XCTAssertFalse(
            ControlEndpoint.acceptsPeer(ownUID: 501, peerUID: 0),
            contrat + " — R4 : un pair plus privilégié que nous n'est pas un pair de confiance")
    }
}
