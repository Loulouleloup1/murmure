import Foundation
import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 11, seconde moitié : **la résolution d'un transcript par le CLI** (plan
/// §2.5 `murmure read <id|chemin>`, §2.4, §4 lot 11, critère 20).
///
/// Ce que ces tests gèlent :
/// - **résoudre par identifiant, par tige de nom de fichier, ou par chemin** désigne le **même**
///   transcript, et ses deux fichiers (§2.4 : l'`id` d'un document est la tige de son fichier) ;
/// - **hors ligne** : la résolution ne connaît que la racine et ce qu'elle contient — aucune
///   application, aucun index, aucun socket (§2.4 : « l'index, c'est le dossier ») ;
/// - **aucun chemin hors de la bibliothèque** : une requête qui sortirait de la racine
///   (`../…`, chemin absolu ailleurs) est **refusée explicitement** (`outsideLibrary`), et un
///   chemin relatif se résout depuis la racine — la même commande veut dire la même chose d'où
///   qu'elle soit lancée ;
/// - **une tige ambiguë est refusée** (`ambiguous`, candidats listés) : jamais arbitrée en silence ;
/// - **un transcript supprimé échoue proprement** (`notFound`), et un `.json` illisible n'est pas un
///   document (§2.4, invariant d'`id`).
///
/// Tous ces tests échouent sur une **assertion explicite** (message « contrat lot 11 : non
/// implémenté ») tant que les corps sentinelles de `TranscriptQuery.swift` n'ont pas été remplacés —
/// jamais sur une erreur de compilation (plan §7.1, règle 4).
final class TranscriptQueryTests: XCTestCase {
    private let contrat = "contrat lot 11 : non implémenté"

    private var espace: URL!
    private var base: URL!
    private var bibliotheque: TranscriptLibrary!
    private var interrogeur: TranscriptQuery!

    override func setUpWithError() throws {
        espace = try Self.bacASable("TranscriptQueryTests")
        base = espace.appendingPathComponent("Transcripts", isDirectory: true)
        bibliotheque = TranscriptLibrary(base: base)
        interrogeur = TranscriptQuery(library: bibliotheque)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: espace)
    }

    // MARK: - Outils

    /// Le seul endroit du fichier qui nomme un dossier, et il ne peut pas en nommer un vrai : tout
    /// vit sous `NSTemporaryDirectory()` — ni `Application Support/Murmure` ni un dossier de
    /// l'utilisateur ne sont approchés.
    private static func bacASable(_ nom: String) throws -> URL {
        let temporaire = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let racine = temporaire.appendingPathComponent("\(nom)-\(UUID().uuidString)", isDirectory: true)
        precondition(
            racine.resolvingSymlinksInPath().path.hasPrefix(temporaire.path),
            "un test de résolution ne travaille que sous NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        return racine
    }

    private static func encodeur() -> JSONEncoder {
        let encodeur = JSONEncoder()
        encodeur.dateEncodingStrategy = .iso8601
        return encodeur
    }

    /// Écrit un transcript **directement sur disque**, sous une tige choisie : ces tests portent sur
    /// la lecture du dossier, donc ils ne dépendent pas de la règle de nommage de la bibliothèque —
    /// et n'en figent aucune (révision 8 du plan : la tige d'un travail reprisable est réutilisée
    /// telle quelle, ce n'est pas le sujet ici).
    private func ecrire(_ tige: String, titre: String = "Démonstration") throws {
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
            completedAt: date.addingTimeInterval(20),
            status: .complete,
            segments: [TranscriptSegment(start: 0, end: 20, text: "Bonjour tout le monde")],
            coverage: TranscriptDocument.Coverage(coveredSeconds: 20, ratio: 1),
            boundaries: [])
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Self.encodeur().encode(document)
            .write(to: base.appendingPathComponent("\(tige).json"))
        try Data("# \(tige)\n\nBonjour tout le monde.\n".utf8)
            .write(to: base.appendingPathComponent("\(tige).md"))
    }

    /// Sème un `.json` **illisible** sous une tige : le fichier existe, ce n'est pas un document.
    private func semerIllisible(_ tige: String) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("{ \"id\": \"\(tige)\",".utf8)
            .write(to: base.appendingPathComponent("\(tige).json"))
    }

    /// Exécute un appel du contrat qui peut jeter. Une levée devient une **assertion explicite**
    /// (message du contrat) : c'est ce que §7.1 règle 4 exige d'un rouge, et c'est ce qui évite
    /// qu'une sentinelle qui jette fasse sortir le test par une erreur non attribuée.
    private func resultat<T>(_ objet: String, _ corps: () throws -> T) -> T? {
        do {
            return try corps()
        } catch {
            XCTFail(contrat + " — \(objet) a levé \(error)")
            return nil
        }
    }

    /// Vérifie que la résolution **refuse** par le cas attendu — un cas nommé, avec sa charge : une
    /// requête hors de la bibliothèque n'est pas une requête introuvable, et une tige ambiguë dit
    /// lesquelles.
    private func verifierRefus(
        _ objet: String, _ attendu: TranscriptQueryError, _ corps: () throws -> TranscriptQueryTarget,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try corps(), contrat + " — \(objet) : doit être refusé", file: file, line: line
        ) { erreur in
            XCTAssertEqual(
                erreur as? TranscriptQueryError, attendu,
                contrat + " — \(objet) : refus attendu \(attendu), obtenu \(erreur)",
                file: file, line: line)
        }
    }

    // MARK: - Résoudre par identifiant, par tige de nom, par chemin

    /// Résolution par **identifiant** : l'id est la tige du fichier (§2.4, invariant de la
    /// révision 8), et la cible porte les deux chemins de cette tige.
    func testResolutionParIdentifiant() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        guard let cible = resultat("resolve(\(tige))", { try interrogeur.resolve(tige) }) else {
            return
        }
        XCTAssertEqual(
            cible.id, tige, contrat + " — l'id résolu est celui demandé, qui est la tige du fichier")
        XCTAssertEqual(
            cible.jsonURL.path, base.appendingPathComponent("\(tige).json").path,
            contrat + " — la cible porte le JSON de cette tige")
        XCTAssertEqual(
            cible.markdownURL.path, base.appendingPathComponent("\(tige).md").path,
            contrat + " — la cible porte le Markdown de la MÊME tige (critère 21)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cible.jsonURL.path),
            contrat + " — le JSON de la cible existe sur disque")
    }

    /// Résolution par **tige de nom de fichier** : `read <tige>.json` et `read <tige>.md` désignent
    /// le même transcript — un agent qui a trouvé l'un n'a pas besoin de deviner l'autre (§2.4).
    func testResolutionParTigeDeNomDeFichier() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        for nom in ["\(tige).json", "\(tige).md"] {
            guard let cible = resultat("resolve(\(nom))", { try interrogeur.resolve(nom) }) else {
                return
            }
            XCTAssertEqual(
                cible.id, tige,
                contrat + " — `\(nom)` doit désigner le transcript de tige \(tige)")
        }
    }

    /// Résolution par **chemin absolu** dans la bibliothèque — la forme qu'un agent recopie de
    /// `murmure list`.
    func testResolutionParCheminAbsoluDansLaBibliotheque() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")
        let chemin = base.appendingPathComponent("\(tige).json").path

        guard let cible = resultat("resolve(\(chemin))", { try interrogeur.resolve(chemin) }) else {
            return
        }
        XCTAssertEqual(
            cible.id, tige, contrat + " — un chemin absolu dans la bibliothèque résout son id")
        XCTAssertEqual(
            cible.jsonURL.path, chemin, contrat + " — la cible rend le chemin demandé")
    }

    /// **Hors ligne** : la résolution et la commande complète tiennent au dossier seul — aucune
    /// application n'est lancée pendant ces tests, et `read` est routée en local.
    func testResolutionHorsLigne_LeDossierSuffitEtReadEstLocale() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        XCTAssertEqual(
            ControlProtocol.route(for: .read), .local,
            contrat + " — critère 20 : `read` ne dépend pas de l'application")

        guard let cible = resultat("resolve hors ligne", { try interrogeur.resolve(tige) }) else {
            return
        }
        XCTAssertEqual(cible.id, tige, contrat + " — la résolution ne tient qu'au dossier")

        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .read, source: cible.id), library: bibliotheque)
        XCTAssertEqual(
            reponse.exitCode, .success,
            contrat + " — critère 20 : `read` d'un transcript présent retourne 0, app fermée")
        XCTAssertEqual(
            reponse.document?.id, tige, contrat + " — le document rendu est celui du dossier")
    }

    // MARK: - Jamais de chemin hors de la bibliothèque

    /// **Le refus explicite du `../`** : une requête qui sortirait de la racine est refusée en tant
    /// que telle — et le contrôle positif, dans le même test, montre que la fonction résout bel et
    /// bien un chemin **dans** la racine (un refus systématique ne passerait pas).
    func testRefusExpliciteDUneRequeteHorsDeLaBibliotheque() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")
        let dedans = base.appendingPathComponent("\(tige).json").path

        verifierRefus("`../hors.json`", .outsideLibrary(query: "../hors.json"), {
            try interrogeur.resolve("../hors.json")
        })
        verifierRefus("`../../etc/passwd`", .outsideLibrary(query: "../../etc/passwd"), {
            try interrogeur.resolve("../../etc/passwd")
        })
        verifierRefus("répertoire voisin", .outsideLibrary(query: "../Transcripts-voisins/x.json"), {
            try interrogeur.resolve("../Transcripts-voisins/x.json")
        })
        verifierRefus("chemin absolu hors de la bibliothèque", .outsideLibrary(query: "/etc/passwd"), {
            try interrogeur.resolve("/etc/passwd")
        })
        verifierRefus("remontée au milieu d'un chemin", .outsideLibrary(query: "work/../../hors.json"), {
            try interrogeur.resolve("work/../../hors.json")
        })

        // Contrôle positif, dans le même test : dans la racine, il n'y a pas de refus.
        guard let cible = resultat("resolve(chemin absolu dans la racine)", {
            try interrogeur.resolve(dedans)
        }) else { return }
        XCTAssertEqual(
            cible.id, tige, contrat + " — un chemin DANS la bibliothèque doit résoudre son id")

        // Un chemin qui reste dans la racine mais ne désigne aucun transcript n'est pas un refus
        // de périmètre : c'est une absence.
        verifierRefus("chemin interne inexistant", .notFound(query: "essais/absent.json"), {
            try interrogeur.resolve("essais/absent.json")
        })
    }

    /// **Une tige ambiguë est refusée explicitement**, avec ses candidats ; l'égalité exacte, elle,
    /// l'emporte toujours, et un préfixe qui ne désigne qu'un transcript le résout.
    func testTigeAmbigueRefuseeExplicitement() throws {
        let premiere = "bonjour-2026-09-21-aaaaaaaa"
        let seconde = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(seconde, titre: "Bonjour")
        try ecrire(premiere, titre: "Bonjour")

        verifierRefus(
            "préfixe qui désigne deux transcripts",
            .ambiguous(query: "bonjour", candidates: [premiere, seconde].sorted()),
            { try interrogeur.resolve("bonjour") }
        )

        guard let exacte = resultat("resolve(tige exacte)", { try interrogeur.resolve(seconde) }) else {
            return
        }
        XCTAssertEqual(
            exacte.id, seconde,
            contrat + " — la tige exacte résout ce transcript, sans être gênée par son voisin")

        guard let parPrefixe = resultat("resolve(préfixe unique)", {
            try interrogeur.resolve("bonjour-2026-09-21")
        }) else { return }
        XCTAssertEqual(
            parPrefixe.id, premiere,
            contrat + " — un préfixe qui ne désigne qu'un transcript le résout")

        verifierRefus("préfixe sans correspondance", .notFound(query: "conference"), {
            try interrogeur.resolve("conference")
        })
    }

    /// **Un transcript supprimé échoue proprement** : la résolution le dit (`notFound`), et la
    /// commande complète sort en travail en échec avec un message — pas un document vide, pas un
    /// plantage.
    func testTranscriptSupprimeEchoueProprement() throws {
        let tige = "disparu-2026-09-22-dddddddd"
        try ecrire(tige, titre: "Disparu")

        // Le Markdown seul peut manquer : le JSON est la source de vérité machine (§2.4).
        try FileManager.default.removeItem(at: base.appendingPathComponent("\(tige).md"))
        guard let sansMarkdown = resultat("resolve sans le Markdown", {
            try interrogeur.resolve(tige)
        }) else { return }
        XCTAssertEqual(
            sansMarkdown.id, tige,
            contrat + " — la résolution tient au JSON : un Markdown absent n'empêche pas de lire")

        try FileManager.default.removeItem(at: base.appendingPathComponent("\(tige).json"))
        verifierRefus("transcript supprimé", .notFound(query: tige), {
            try interrogeur.resolve(tige)
        })

        let reponse = ControlProtocol.respondLocally(
            to: ControlRequest(command: .read, source: tige), library: bibliotheque)
        XCTAssertEqual(
            reponse.exitCode, .jobFailed,
            contrat + " — un `read` d'un transcript disparu sort en travail en échec (1)")
        XCTAssertNil(reponse.document, contrat + " — et ne rend aucun document")
        XCTAssertFalse(
            (reponse.error ?? "").isEmpty, contrat + " — et le dit (aucun échec silencieux)")
        XCTAssertEqual(
            ControlProtocol.exitCode(for: TranscriptQueryError.notFound(query: tige)), .jobFailed,
            contrat + " — un transcript introuvable n'est pas une faute d'usage : code 1, pas 2")
    }

    /// Un chemin **interne** qui contient un `..` reste dans la bibliothèque : le refus porte sur
    /// la sortie de la racine, pas sur la présence d'un `..`.
    func testUnCheminInterneQuiRemonteResteDansLaBibliotheque() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        for requete in ["work/../\(tige).json", "./\(tige).json"] {
            guard let cible = resultat("resolve(\(requete))", { try interrogeur.resolve(requete) }) else {
                return
            }
            XCTAssertEqual(
                cible.id, tige,
                contrat + " — `\(requete)` normalise en un chemin de la racine : il résout \(tige)")
        }
    }

    // MARK: - Les refus de saisie

    /// Une requête vide ne désigne rien, et le dit (`emptyQuery`) — ce n'est pas une absence.
    func testRequeteVideRefusee() {
        for requete in ["", "   ", "\n\t "] {
            verifierRefus("requête vide \(requete.debugDescription)", .emptyQuery, {
                try interrogeur.resolve(requete)
            })
        }
    }

    /// La tige est un nom de fichier : la comparaison est **sensible à la casse** — mieux vaut ne
    /// rien résoudre que résoudre le mauvais fichier. Le contrôle positif est dans le même test.
    func testResolutionSensibleALaCasse() throws {
        let tige = "bonjour-2026-09-22-aaaaaaaa"
        try ecrire(tige, titre: "Bonjour")

        guard let cible = resultat("resolve(\(tige))", { try interrogeur.resolve(tige) }) else {
            return
        }
        XCTAssertEqual(cible.id, tige, contrat + " — la tige telle qu'elle est écrite résout")

        let majuscules = tige.uppercased()
        verifierRefus("tige à la casse approximative", .notFound(query: majuscules), {
            try interrogeur.resolve(majuscules)
        })
    }

    /// Un `.json` **illisible** à la tige demandée n'est pas un document (§2.4 : l'invariant d'`id`
    /// et le compte des illisibles) : la résolution le refuse au lieu de rendre un fichier qu'elle
    /// n'a pas su lire.
    func testUnJsonIllisibleNestPasUnDocument() throws {
        let bonne = "bonjour-2026-09-22-aaaaaaaa"
        let cassee = "casse-2026-09-21-bbbbbbbb"
        try ecrire(bonne, titre: "Bonjour")
        try semerIllisible(cassee)

        guard let cible = resultat("resolve(\(bonne))", { try interrogeur.resolve(bonne) }) else {
            return
        }
        XCTAssertEqual(
            cible.id, bonne,
            contrat + " — le transcript lisible de la racine résout (contrôle positif)")

        verifierRefus("`.json` illisible à la tige demandée", .notFound(query: cassee), {
            try interrogeur.resolve(cassee)
        })
    }
}
