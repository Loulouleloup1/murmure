import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 4 : la commande `yt-dlp` et la lecture de `info.json` (plan §4 lot 4).
///
/// Trois choses y sont gelées, et les trois coûtent cher ailleurs si elles bougent :
///
/// 1. **Une seule invocation par acquisition.** Chaque appel de `yt-dlp` coûte 13-16 s
///    (auto-extraction PyInstaller, plan §8) : `--write-info-json` fait écrire les métadonnées
///    pendant le téléchargement, et un second appel pour lire la durée serait payé deux fois.
/// 2. **Aucune invocation pour un fichier local** (critère 3 : zéro réseau). Ce n'est pas une
///    promesse d'intention, c'est la forme du retour : `download(_:)` rend une `.localFile`, et il
///    n'existe alors aucun vecteur d'arguments à exécuter.
/// 3. **La durée annoncée est celle de `info.json`** (critère 1) : c'est elle que `afinfo`
///    confrontera à ± 1 s.
///
/// Les fixtures `Fixtures/ytdlp-info-*.json` sont un **sous-ensemble fidèle** de ce que `yt-dlp`
/// écrit (`id`, `title`, `duration`, `subtitles`, `automatic_captions`, `formats`) : la carte
/// interdit de lancer une vraie acquisition, donc elles ne sont pas une capture réseau — elles
/// portent les clés lues et leurs voisines, avec les valeurs du benchmark (38 min 13 s = 2293 s,
/// post X = 84 s).
///
/// Tous ces tests échouent sur une **assertion explicite** tant que les corps sentinelles de
/// `YtDlpCommand.swift` n'ont pas été remplacés.
final class YtDlpCommandTests: XCTestCase {
    private var racine: URL!
    private var outils: URL!
    private var travail: URL!

    private let adresseYouTube = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    override func setUpWithError() throws {
        racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("YtDlpCommandTests-\(UUID().uuidString)")
        outils = racine.appendingPathComponent("Application Support/Murmure/tools")
        travail = racine.appendingPathComponent("Transcripts/work/9f2c1a")
        try FileManager.default.createDirectory(at: travail, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: racine)
    }

    // MARK: - Sources et outils

    private func youtube() -> TranscriptSource {
        TranscriptSource(
            kind: .youtube, url: URL(string: adresseYouTube), identity: "dQw4w9WgXcQ")
    }

    private func x() -> TranscriptSource {
        TranscriptSource(
            kind: .x, url: URL(string: "https://x.com/quelquun/status/1234567890"),
            identity: "1234567890")
    }

    private func fichier() -> TranscriptSource {
        TranscriptSource(
            kind: .file, path: racine.appendingPathComponent("film.m4a").path, identity: "ab12cd34")
    }

    private func valeur(_ drapeau: String, dans arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: drapeau),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    /// L'invocation attendue pour une source distante ; échoue explicitement sinon.
    private func invocation(
        _ source: TranscriptSource, file: StaticString = #filePath, line: UInt = #line
    ) -> YtDlpCommand.Invocation? {
        do {
            switch try YtDlpCommand.download(source, toolsDirectory: outils, into: travail) {
            case .download(let invocation):
                return invocation
            case .localFile(let url):
                XCTFail(
                    "contrat lot 4 : non implémenté — aucune invocation construite "
                        + "(fichier local rendu : « \(url.path) »)",
                    file: file, line: line)
                return nil
            }
        } catch {
            XCTFail(
                "contrat lot 4 : non implémenté — refus inattendu : \(error)", file: file, line: line)
            return nil
        }
    }

    private func fixture(_ nom: String, _ extensionFichier: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: nom, withExtension: extensionFichier, subdirectory: "Fixtures"),
            "fixture absente du bundle de tests : Fixtures/\(nom).\(extensionFichier)")
        return try Data(contentsOf: url)
    }

    // MARK: - L'invocation

    /// Une URL YouTube produit **un seul** appel, complet : métadonnées et audio dans le même
    /// passage, progression lisible ligne à ligne, et le sélecteur que le ffmpeg embarqué rend
    /// possible (plus besoin de forcer `ext=m4a` : Opus/WebM se décodent, plan §2.6 et §8).
    func testUneUrlYouTubeProduitUneSeuleInvocationComplete() throws {
        let source = youtube()
        let inv = try XCTUnwrap(
            invocation(source),
            "contrat lot 4 : non implémenté — aucune invocation pour une URL YouTube")

        XCTAssertEqual(
            inv.executable.path, outils.appendingPathComponent("yt-dlp").path,
            "contrat lot 4 : non implémenté — binaire rendu : « \(inv.executable.path) »")
        XCTAssertEqual(
            inv.workingDirectory.path, travail.path,
            "contrat lot 4 : non implémenté — répertoire de travail rendu : « \(inv.workingDirectory.path) »")
        XCTAssertTrue(
            inv.arguments.contains(adresseYouTube),
            "contrat lot 4 : non implémenté — l'URL n'est pas dans les arguments : \(inv.arguments)")

        // Une seule invocation : les métadonnées viennent du même passage que l'audio.
        XCTAssertTrue(
            inv.arguments.contains("--write-info-json"),
            "contrat lot 4 : non implémenté — `--write-info-json` absent : \(inv.arguments)")
        XCTAssertEqual(
            inv.infoJSON.path, travail.appendingPathComponent("source.info.json").path,
            "contrat lot 4 : non implémenté — chemin de info.json rendu : « \(inv.infoJSON.path) »")
        let sortie = valeur("-o", dans: inv.arguments)
        XCTAssertTrue(
            sortie?.hasSuffix("source.%(ext)s") ?? false,
            "contrat lot 4 : non implémenté — modèle de sortie rendu : « \(sortie ?? "absent") »")
        if let sortie, sortie.hasPrefix("/") {
            XCTAssertEqual(
                URL(fileURLWithPath: sortie).deletingLastPathComponent().path, travail.path,
                "contrat lot 4 : non implémenté — la sortie ne tombe pas dans le travail : « \(sortie) »")
        }

        // Le sélecteur : `bestaudio/best`, et surtout plus de `ext=m4a`.
        XCTAssertEqual(
            valeur("-f", dans: inv.arguments), "bestaudio/best",
            "contrat lot 4 : non implémenté — sélecteur rendu : « \(valeur("-f", dans: inv.arguments) ?? "absent") »")
        XCTAssertFalse(
            inv.arguments.contains(where: { $0.contains("ext=m4a") }),
            "contrat lot 4 : non implémenté — le sélecteur force encore ext=m4a : \(inv.arguments)")

        // Progression et périmètre.
        XCTAssertTrue(
            inv.arguments.contains("--newline"),
            "contrat lot 4 : non implémenté — `--newline` absent : \(inv.arguments)")
        let modele = valeur("--progress-template", dans: inv.arguments)
        XCTAssertTrue(
            modele?.contains("progress") ?? false,
            "contrat lot 4 : non implémenté — modèle de progression rendu : « \(modele ?? "absent") »")
        XCTAssertTrue(
            inv.arguments.contains("--no-playlist"),
            "contrat lot 4 : non implémenté — `--no-playlist` absent : \(inv.arguments)")
    }

    /// Une URL X suit **le même chemin de code** (critère 2 : seule l'URL change).
    func testUneUrlXPrendLeMemeCheminDeCode() throws {
        let inv = try XCTUnwrap(
            invocation(x()), "contrat lot 4 : non implémenté — aucune invocation pour une URL X")

        XCTAssertEqual(
            inv.executable.path, outils.appendingPathComponent("yt-dlp").path,
            "contrat lot 4 : non implémenté — binaire rendu : « \(inv.executable.path) »")
        XCTAssertEqual(
            valeur("-f", dans: inv.arguments), "bestaudio/best",
            "contrat lot 4 : non implémenté — sélecteur rendu pour X : « \(valeur("-f", dans: inv.arguments) ?? "absent") »")
        XCTAssertTrue(
            inv.arguments.contains("--write-info-json"),
            "contrat lot 4 : non implémenté — `--write-info-json` absent pour X : \(inv.arguments)")
        XCTAssertTrue(
            inv.arguments.contains("https://x.com/quelquun/status/1234567890"),
            "contrat lot 4 : non implémenté — l'URL du statut n'est pas dans les arguments : \(inv.arguments)")
    }

    /// **Critère 3** : un fichier local ne construit aucun appel à `yt-dlp` — donc aucune socket,
    /// aucun accès réseau. Le contrôle positif (la même fonction, avec une URL, construit bien une
    /// invocation) est dans le même test : sans lui, un `download(_:)` qui rendrait toujours
    /// `.localFile` passerait pour un vert.
    func testUnFichierLocalNeConstruitAucunArgumentYtDlp() throws {
        let source = fichier()
        let attendu = URL(fileURLWithPath: try XCTUnwrap(source.path, "fixture invalide"))

        let action = try YtDlpCommand.download(source, toolsDirectory: outils, into: travail)
        XCTAssertEqual(
            action, .localFile(attendu),
            "contrat lot 4 : non implémenté — action rendue pour un fichier local : \(action)")

        guard case .download(let inv) = try YtDlpCommand.download(
            youtube(), toolsDirectory: outils, into: travail)
        else {
            XCTFail("contrat lot 4 : non implémenté — une URL ne construit plus d'invocation")
            return
        }
        XCTAssertTrue(
            inv.arguments.contains("--write-info-json"),
            "contrat lot 4 : non implémenté — invocation incomplète pour une URL : \(inv.arguments)")
    }

    /// Une source mal formée est **refusée** avant qu'un processus existe : dossier `.file` sans
    /// chemin, ou source distante sans URL (cas limite, mais c'est celui d'un glisser-déposer raté).
    func testUneSourceSansUrlOuSansCheminEstRefusee() {
        let sansChemin = TranscriptSource(kind: .file, path: nil, identity: "ab12cd34")
        let sansURL = TranscriptSource(kind: .youtube, url: nil, identity: "dQw4w9WgXcQ")

        for source in [sansChemin, sansURL] {
            do {
                let action = try YtDlpCommand.download(source, toolsDirectory: outils, into: travail)
                XCTFail(
                    "contrat lot 4 : non implémenté — source inexploitable acceptée (\(source.kind)) : \(action)")
            } catch let failure as YtDlpCommand.Failure {
                XCTAssertEqual(
                    failure, .missingSource,
                    "contrat lot 4 : non implémenté — refus rendu : \(failure)")
            } catch {
                XCTFail("contrat lot 4 : non implémenté — refus inattendu : \(error)")
            }
        }
    }

    // MARK: - info.json

    /// **Critère 1** : la durée annoncée est lue dans `info.json` et rendue en secondes — c'est
    /// elle que `afinfo` confrontera à ± 1 s.
    func testLaDureeAnnonceeEstLueDansLeInfoJson() throws {
        let meta = try YtDlpCommand.metadata(try fixture("ytdlp-info-youtube", "json"))

        XCTAssertEqual(
            meta.identifier, "dQw4w9WgXcQ",
            "contrat lot 4 : non implémenté — identifiant rendu : « \(meta.identifier) »")
        XCTAssertTrue(
            meta.title.contains("piliers"),
            "contrat lot 4 : non implémenté — titre rendu : « \(meta.title) »")
        XCTAssertEqual(
            meta.duration, 2293, accuracy: 1,
            "contrat lot 4 : non implémenté — durée annoncée rendue : \(meta.duration) s (attendu 2293 ± 1)")
        XCTAssertEqual(
            meta.webpageURL?.absoluteString, adresseYouTube,
            "contrat lot 4 : non implémenté — URL rendue : « \(meta.webpageURL?.absoluteString ?? "nil") »")
    }

    /// **Critère 8** : les sous-titres sont disponibles **avec leur provenance**, une seule ligne
    /// par langue (la version humaine l'emporte sur la version machine — `fr` est dans les deux
    /// dictionnaires de la fixture), et l'ordre est stable (tri par code de langue).
    func testLesSousTitresPortentLeurProvenance() throws {
        let meta = try YtDlpCommand.metadata(try fixture("ytdlp-info-youtube", "json"))

        XCTAssertEqual(
            meta.subtitles,
            [
                YtDlpMetadata.Subtitle(language: "de", provenance: .automatic),
                YtDlpMetadata.Subtitle(language: "en", provenance: .human),
                YtDlpMetadata.Subtitle(language: "fr", provenance: .human),
            ],
            "contrat lot 4 : non implémenté — sous-titres rendus : \(meta.subtitles)")
    }

    /// Une source sans sous-titres rend une liste vide — et le contrôle positif (la fixture qui en
    /// porte quatre n'en rend pas) est dans le même test.
    func testUnInfoJsonSansSousTitresDonneUneListeVide() throws {
        let sansSousTitres = try YtDlpCommand.metadata(
            try fixture("ytdlp-info-sans-sous-titres", "json"))
        let avecSousTitres = try YtDlpCommand.metadata(try fixture("ytdlp-info-youtube", "json"))

        XCTAssertFalse(
            avecSousTitres.subtitles.isEmpty,
            "contrat lot 4 : non implémenté — la fixture qui porte des sous-titres n'en rend aucun")
        XCTAssertTrue(
            sansSousTitres.subtitles.isEmpty,
            "contrat lot 4 : non implémenté — sous-titres inventés : \(sansSousTitres.subtitles)")
    }

    /// Un `info.json` sans durée est inutilisable (critère 1 : la durée annoncée est la
    /// référence) : il est refusé, pas décodé en zéro silencieux.
    func testUnInfoJsonSansDureeEstRefuse() {
        let cas = [
            Data("{}".utf8),
            Data(#"{"id": "dQw4w9WgXcQ", "title": "sans durée"}"#.utf8),
        ]

        for donnees in cas {
            do {
                let meta = try YtDlpCommand.metadata(donnees)
                XCTFail(
                    "contrat lot 4 : non implémenté — info.json sans durée accepté (durée rendue : \(meta.duration))")
            } catch let failure as YtDlpCommand.Failure {
                XCTAssertEqual(
                    failure, .malformedInfoJSON,
                    "contrat lot 4 : non implémenté — refus rendu : \(failure)")
            } catch {
                XCTFail("contrat lot 4 : non implémenté — refus inattendu : \(error)")
            }
        }
    }
}
