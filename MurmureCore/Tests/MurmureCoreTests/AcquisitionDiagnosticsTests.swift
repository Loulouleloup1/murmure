import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 4 : le bloc copiable du critère 7 (plan §4 lot 4, §2.3).
///
/// Le bloc est ce que l'utilisateur colle à son agent IA quand une acquisition échoue : il doit
/// porter assez d'information pour que l'agent contourne le problème (versions des outils, URL,
/// code de sortie, sortie brute) et **rien de ce qui ne se recopie pas** — ni les chemins de
/// travail (l'audio téléchargé, les unités WAV, les fichiers de transcript y sont cités par `ffmpeg`
/// et `yt-dlp` spontanément), ni un contenu audio, ni un texte transcrit (AGENTS.md).
///
/// Les tests négatifs de ce fichier portent tous un **contrôle positif dans le même cas** (la
/// source et le code de sortie doivent s'y trouver) : une assertion du type « le bloc ne contient
/// pas ce chemin » est vraie sur un bloc vide, donc verte sans implémentation.
///
/// Tous ces tests échouent sur une **assertion explicite** tant que le corps sentinelle de
/// `AcquisitionDiagnostics.swift` n'a pas été remplacé.
final class AcquisitionDiagnosticsTests: XCTestCase {
    private let adresse = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    private let versions = [
        AcquisitionDiagnostics.ToolVersion(name: "yt-dlp", version: "2026.08.19"),
        AcquisitionDiagnostics.ToolVersion(name: "ffmpeg", version: "8.0.1-lgpl"),
    ]

    // MARK: - Ce que le bloc porte

    /// Versions des outils, URL, code de sortie, et le début de la sortie brute du `yt-dlp` — le
    /// message d'erreur lui-même, sans quoi le bloc ne sert à rien.
    func testLeBlocPorteLaSourceLeCodeDeSortieEtLesVersions() {
        let bloc = AcquisitionDiagnostics.block(
            source: adresse,
            toolVersions: versions,
            exitCode: 1,
            stderr: "ERROR: unable to download video data: HTTP Error 403: Forbidden\n",
            redacting: [])

        XCTAssertFalse(
            bloc.isEmpty, "contrat lot 4 : non implémenté — bloc vide")
        XCTAssertTrue(
            bloc.contains(adresse),
            "contrat lot 4 : non implémenté — l'URL est absente du bloc :\n\(bloc)")
        XCTAssertNotNil(
            bloc.range(of: #"yt-dlp[^\n]*2026\.08\.19"#, options: .regularExpression),
            "contrat lot 4 : non implémenté — version de yt-dlp absente du bloc :\n\(bloc)")
        XCTAssertNotNil(
            bloc.range(of: #"ffmpeg[^\n]*8\.0\.1-lgpl"#, options: .regularExpression),
            "contrat lot 4 : non implémenté — version de ffmpeg absente du bloc :\n\(bloc)")
        XCTAssertNotNil(
            bloc.range(of: #"(exit|code)[^\n]*1"#, options: .regularExpression),
            "contrat lot 4 : non implémenté — code de sortie absent du bloc :\n\(bloc)")
        XCTAssertTrue(
            bloc.contains("HTTP Error 403"),
            "contrat lot 4 : non implémenté — la sortie brute de l'outil est absente du bloc :\n\(bloc)")
    }

    /// **Aucun chemin de fichier produit par le travail** : ni l'audio téléchargé, ni les unités
    /// WAV, ni le fichier de transcript — même quand la sortie brute les cite.
    func testLeBlocNeContientAucunCheminDAudio() {
        let travail = URL(
            fileURLWithPath:
                "/Users/quelquun/Library/Application Support/Murmure/Transcripts/work/9f2c1a")
        let audio = travail.appendingPathComponent("source.m4a")
        let wav = travail.appendingPathComponent("units/0000.wav")
        let transcript = URL(
            fileURLWithPath:
                "/Users/quelquun/Library/Application Support/Murmure/Transcripts/demo-2026-09-20-ab12cd34.json")
        let brut =
            "ERROR: unable to download video data: HTTP Error 403: Forbidden\n"
            + "(downloaded audio: \(audio.path); silence map read from \(wav.path))\n"
            + "transcript: \(transcript.path)\n"

        let bloc = AcquisitionDiagnostics.block(
            source: adresse,
            toolVersions: versions,
            exitCode: 1,
            stderr: brut,
            redacting: [audio.path, wav.path, transcript.path, travail.path])

        XCTAssertFalse(
            bloc.isEmpty, "contrat lot 4 : non implémenté — bloc vide")
        XCTAssertTrue(
            bloc.contains(adresse),
            "contrat lot 4 : non implémenté — l'URL est absente du bloc :\n\(bloc)")
        XCTAssertTrue(
            bloc.contains("HTTP Error 403"),
            "contrat lot 4 : non implémenté — la sortie brute de l'outil est absente du bloc :\n\(bloc)")
        XCTAssertFalse(
            bloc.contains(audio.path),
            "contrat lot 4 : non implémenté — chemin de l'audio téléchargé recopié :\n\(bloc)")
        XCTAssertFalse(
            bloc.contains(wav.path),
            "contrat lot 4 : non implémenté — chemin d'une unité WAV recopié :\n\(bloc)")
        XCTAssertFalse(
            bloc.contains(transcript.path),
            "contrat lot 4 : non implémenté — chemin d'un transcript recopié :\n\(bloc)")
    }

    /// La sortie brute est **bornée** : le début reste lisible, la fin est coupée, et le bloc dit
    /// qu'il a tronqué.
    func testLeBlocBorneLaSortieBrute() {
        let brutal = String(repeating: "y", count: 50_000) + "TAIL-MARQUEUR"

        let bloc = AcquisitionDiagnostics.block(
            source: adresse,
            toolVersions: versions,
            exitCode: 1,
            stderr: brutal,
            redacting: [],
            stderrLimit: 1_000)

        XCTAssertFalse(
            bloc.isEmpty, "contrat lot 4 : non implémenté — bloc vide")
        XCTAssertTrue(
            bloc.contains(adresse),
            "contrat lot 4 : non implémenté — l'URL est absente du bloc")
        XCTAssertTrue(
            bloc.contains(String(repeating: "y", count: 100)),
            "contrat lot 4 : non implémenté — le début de la sortie brute est absent du bloc")
        XCTAssertFalse(
            bloc.contains("TAIL-MARQUEUR"),
            "contrat lot 4 : non implémenté — la sortie brute n'est pas bornée (limite : 1 000)")
        XCTAssertNotNil(
            bloc.range(of: "omitted|tronqu", options: [.regularExpression, .caseInsensitive]),
            "contrat lot 4 : non implémenté — le bloc ne dit pas qu'il a tronqué :\n\(bloc.suffix(200))")
        XCTAssertLessThan(
            bloc.count, 1_000 + 1_500,
            "contrat lot 4 : non implémenté — bloc de \(bloc.count) caractères pour une limite de 1 000")
    }

    /// Cas limite : aucun outil n'a pu rendre sa version (le binaire manque, `--version` a échoué).
    /// Le bloc reste utilisable — source, code de sortie et sortie brute — et n'invente pas de
    /// version.
    func testUnBlocSansVersionResteUtilisable() {
        let bloc = AcquisitionDiagnostics.block(
            source: adresse,
            toolVersions: [],
            exitCode: 127,
            stderr: "sh: yt-dlp: command not found\n",
            redacting: [])

        XCTAssertFalse(
            bloc.isEmpty, "contrat lot 4 : non implémenté — bloc vide")
        XCTAssertTrue(
            bloc.contains(adresse),
            "contrat lot 4 : non implémenté — l'URL est absente du bloc :\n\(bloc)")
        XCTAssertTrue(
            bloc.contains("command not found"),
            "contrat lot 4 : non implémenté — la sortie brute est absente du bloc :\n\(bloc)")
        XCTAssertNotNil(
            bloc.range(of: #"(exit|code)[^\n]*127"#, options: .regularExpression),
            "contrat lot 4 : non implémenté — code de sortie absent du bloc :\n\(bloc)")
    }

    /// Les remarques issues de l'analyse de la sortie sont portées par le bloc (plan §2.3 : la
    /// signature d'avertissement de `yt-dlp` sur l'absence de runtime JavaScript doit être
    /// signalée, pas seulement subie).
    ///
    /// Les deux notes assertées sont des **sentinelles absentes du `stderr` de ce cas** : asserter
    /// le texte de l'avertissement serait vert sans implémentation, puisque la sortie brute est
    /// recopiée par ailleurs (une implémentation qui ignore `notes` passerait alors le cas).
    func testLeBlocPorteLesNotesIssuesDeLaSortie() {
        let noteA = "ANALYSE-L4-A : certains formats sont indisponibles (aucun runtime JavaScript)"
        let noteB = "ANALYSE-L4-B : le choix de format a été réduit pour cette source"
        let brut = "WARNING: [youtube] some formats may be missing\n"

        let bloc = AcquisitionDiagnostics.block(
            source: adresse,
            toolVersions: versions,
            exitCode: 0,
            stderr: brut,
            redacting: [],
            notes: [noteA, noteB])

        XCTAssertFalse(
            bloc.isEmpty, "contrat lot 4 : non implémenté — bloc vide")
        XCTAssertTrue(
            bloc.contains(adresse),
            "contrat lot 4 : non implémenté — l'URL est absente du bloc :\n\(bloc)")
        XCTAssertTrue(
            bloc.contains("some formats may be missing"),
            "contrat lot 4 : non implémenté — la sortie brute est absente du bloc :\n\(bloc)")
        XCTAssertTrue(
            bloc.contains(noteA),
            "contrat lot 4 : non implémenté — la première note d'analyse est absente du bloc :\n\(bloc)")
        XCTAssertTrue(
            bloc.contains(noteB),
            "contrat lot 4 : non implémenté — la seconde note d'analyse est absente du bloc (toutes les notes sont portées) :\n\(bloc)")
    }
}

// MARK: - Lot 6 (motif `AcquisitionBootstrapDiagnostics`)

/// Contrat rouge du **lot 6** : l'acquisition de bout en bout — première utilisation de `yt-dlp`,
/// quarantaine et signature, mise à jour avant l'échec, sous-titres optionnels, texte copiable
/// (plan §4 lot 6, §2.3, §2.4, SPEC critères 5, 6, 7 et 8).
///
/// **POURQUOI CETTE CLASSE EST DANS CE FICHIER.** `AcquisitionDiagnosticsTests.swift` appartient au
/// lot 4 (§7.1 règle 9) : le lot 6 n'en est pas le créateur, il part de la copie (règle 10) et y
/// ajoute sa classe. Le motif `AcquisitionBootstrapDiagnostics` est donc **disjoint** du motif
/// `AcquisitionDiagnostics` — un rouge du lot 6 ne masque jamais les cas du lot 4, ni l'inverse, et
/// une copie manquée se voit tout de suite (règle 11 : un motif sans correspondance exécute zéro
/// test et sort en 0).
///
/// **TOUS CES CAS ÉCHOUENT SUR UNE ASSERTION EXPLICITE**, avec le message « contrat lot 6 : non
/// implémenté », tant que les corps sentinelles de l'extension du lot 6 dans
/// `AcquisitionDiagnostics.swift` n'ont pas été remplacés. Aucun ne peut échouer par une erreur de
/// compilation : un fichier de tests non compilable casserait la gate `swift test` de **toutes**
/// les cartes en parallèle (§7.1).
///
/// **TRAÇABILITÉ DES CRITÈRES.** Ce que cette classe porte elle-même :
///
/// - critère 8 (sous-titres optionnels + provenance) : les trois tests de sous-titres ;
/// - critère 6 (pas de re-téléchargement, mise à jour tentée avant l'échec) : les deux tests de
///   `BootstrapStep`, dont l'URL épinglée du binaire officiel ;
/// - critère 7 (bloc copiable, sans audio ni transcript) et plan §2.3 (avertissement de runtime
///   JavaScript) : les deux tests de `failureReport` et de `notes(inOutput:)` ;
/// - critère 2 (une URL X suit le même chemin) : le cas limite sans sous-titres passe par la
///   fixture X du benchmark ;
/// - critère 3 (fichier local, zéro réseau) : la classification `localFileUnreadable` existe pour
///   que le message d'un fichier local ne parle jamais de réseau ; le fond du critère (aucun
///   argument `yt-dlp` construit pour un chemin local) est tenu par `YtDlpCommandTests` (lot 4).
///
/// Ce que cette classe ne porte **pas**, et c'est assumé : critère 1 (durée `afinfo` ↔ annoncée à
/// ± 1 s) se mesure sur un fichier réellement produit — le décodage de `info.json` qui donne la
/// durée annoncée est celui du lot 4, et la confrontation est le script de la carte `dev` (plan §7).
/// Critères 5 (téléchargement réel, quarantaine, signature, sans dialogue Gatekeeper) : ce qui
/// s'observe d'un script est `scripts/checks/ytdlp-bootstrap.sh` — réseau, donc périmètre explicite
/// de la carte d'implémentation.
final class AcquisitionBootstrapDiagnosticsTests: XCTestCase {
    private let adresse = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    private let adresseX = "https://x.com/quelquun/status/1234567890"

    // MARK: - Fixtures

    private func fixture(_ nom: String, _ extensionFichier: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: nom, withExtension: extensionFichier, subdirectory: "Fixtures"),
            "fixture absente du bundle de tests : Fixtures/\(nom).\(extensionFichier)")
        return try Data(contentsOf: url)
    }

    /// La source YouTube du benchmark : trois pistes (`de` automatique, `en` et `fr` humaines).
    private func youtube() throws -> YtDlpMetadata {
        try YtDlpCommand.metadata(try fixture("ytdlp-info-youtube", "json"))
    }

    /// La source X du benchmark (critère 2) : aucune piste de sous-titres.
    private func x() throws -> YtDlpMetadata {
        try YtDlpCommand.metadata(try fixture("ytdlp-info-sans-sous-titres", "json"))
    }

    // MARK: - Critère 8 : l'offre, avec sa provenance

    /// Les pistes de `info.json` sont **proposées** avec leur provenance affichée, la
    /// retranscription locale est en tête, et rien n'est inventé (une entrée par piste, pas plus).
    func testLesSousTitresSontProposesAvecLeurProvenanceEtLeDefautEnTete() throws {
        let meta = try youtube()
        let options = AcquisitionDiagnostics.subtitleOptions(from: meta)

        XCTAssertFalse(
            options.isEmpty,
            "contrat lot 6 : non implémenté — aucune option proposée pour une source qui porte trois pistes")
        guard let locale = options.first else { return }

        // Les trois provenances affichables sont celles de la SPEC, et ce sont leurs valeurs brutes
        // qui s'affichent.
        XCTAssertEqual(
            AcquisitionDiagnostics.SubtitleProvenance.allCases.map(\.rawValue),
            ["human", "automatic", "local"],
            "contrat lot 6 : non implémenté — provenances rendues : \(AcquisitionDiagnostics.SubtitleProvenance.allCases.map(\.rawValue))")

        // Le défaut : en tête, sans langue, et sa provenance dit « local ».
        XCTAssertEqual(
            locale.provenance, .local,
            "contrat lot 6 : non implémenté — provenance de l'option de tête : \(locale.provenance.rawValue)")
        XCTAssertNil(
            locale.language,
            "contrat lot 6 : non implémenté — la retranscription locale porte une langue : « \(locale.language ?? "nil") »")
        XCTAssertTrue(
            locale.label.lowercased().contains("local"),
            "contrat lot 6 : non implémenté — le libellé du défaut ne porte pas sa provenance : « \(locale.label) »")

        // Une entrée par piste de `metadata.subtitles`, dans l'ordre, avec la provenance de
        // `info.json` — donc aucune piste inventée et aucune dupliquée.
        XCTAssertEqual(
            options.count, 1 + meta.subtitles.count,
            "contrat lot 6 : non implémenté — \(options.count) option(s) pour \(meta.subtitles.count) piste(s) de info.json")
        XCTAssertEqual(
            options.dropFirst().compactMap(\.language), meta.subtitles.map(\.language),
            "contrat lot 6 : non implémenté — langues proposées : \(options.dropFirst().compactMap(\.language)) au lieu de \(meta.subtitles.map(\.language))")

        for (option, piste) in zip(options.dropFirst(), meta.subtitles) {
            XCTAssertEqual(
                option.provenance.rawValue, piste.provenance.rawValue,
                "contrat lot 6 : non implémenté — provenance affichée pour « \(piste.language) » : \(option.provenance.rawValue) au lieu de \(piste.provenance.rawValue)")
            XCTAssertTrue(
                option.label.lowercased().contains(option.provenance.rawValue),
                "contrat lot 6 : non implémenté — le libellé de « \(piste.language) » ne porte pas sa provenance : « \(option.label) »")
        }

        // La règle du lot 4 reste visible dans l'offre : `fr` est humain ET automatique dans la
        // fixture, et c'est « human » qui s'affiche.
        XCTAssertEqual(
            options.first { $0.language == "fr" }?.provenance.rawValue, "human",
            "contrat lot 6 : non implémenté — provenance affichée pour « fr » (piste humaine ET automatique)")
        XCTAssertEqual(
            options.first { $0.language == "de" }?.provenance.rawValue, "automatic",
            "contrat lot 6 : non implémenté — provenance affichée pour « de » (piste automatique)")
    }

    // MARK: - Critère 8 : la décision

    /// Sans choix explicite, c'est la **retranscription locale** qui s'exécute ; un sous-titre n'est
    /// exécuté que s'il a été désigné.
    ///
    /// Le contrôle positif est dans le même cas : l'offre doit exister pour que le défaut soit
    /// exerçable (sinon « aucun choix → local » serait vert sur une offre vide, c'est-à-dire sur une
    /// implémentation absente).
    func testSansChoisExpliciteCestLaRetranscriptionLocaleQuiExecute() throws {
        let meta = try youtube()
        let options = AcquisitionDiagnostics.subtitleOptions(from: meta)

        guard let locale = options.first else {
            XCTFail(
                "contrat lot 6 : non implémenté — aucune option proposée : le défaut n'est pas exerçable")
            return
        }

        XCTAssertEqual(
            AcquisitionDiagnostics.subtitleChoice(for: nil), .localTranscription,
            "contrat lot 6 : non implémenté — choix rendu sans sélection : \(AcquisitionDiagnostics.subtitleChoice(for: nil))")
        XCTAssertEqual(
            AcquisitionDiagnostics.subtitleChoice(for: locale), .localTranscription,
            "contrat lot 6 : non implémenté — le choix de la ligne « \(locale.label) » ne rend pas la retranscription locale")

        guard let fr = options.first(where: { $0.language == "fr" }) else {
            XCTFail("contrat lot 6 : non implémenté — aucune option pour la piste « fr »")
            return
        }
        XCTAssertEqual(
            AcquisitionDiagnostics.subtitleChoice(for: fr),
            .subtitles(language: "fr", provenance: .human),
            "contrat lot 6 : non implémenté — choix rendu pour la piste « fr » : \(AcquisitionDiagnostics.subtitleChoice(for: fr))")
    }

    /// **Cas limite (critère 2 / critère 8)** : la source X du benchmark ne porte aucune piste.
    /// L'offre se réduit alors à la retranscription locale, et le défaut ne change pas.
    func testUneSourceSansSousTitresNOffreQueLaRetranscriptionLocale() throws {
        let meta = try x()
        XCTAssertTrue(
            meta.subtitles.isEmpty,
            "fixture invalide : la fixture X ne doit porter aucune piste de sous-titres")

        let options = AcquisitionDiagnostics.subtitleOptions(from: meta)
        XCTAssertEqual(
            options.map(\.provenance), [.local],
            "contrat lot 6 : non implémenté — options rendues pour \(adresseX) : \(options.map(\.provenance.rawValue))")
        XCTAssertNil(
            options.first?.language,
            "contrat lot 6 : non implémenté — la seule option d'une source sans piste porte une langue : « \(options.first?.language ?? "nil") »")
        XCTAssertEqual(
            AcquisitionDiagnostics.subtitleChoice(for: nil), .localTranscription,
            "contrat lot 6 : non implémenté — choix rendu sans sélection pour une source sans piste : \(AcquisitionDiagnostics.subtitleChoice(for: nil))")
    }

    // MARK: - Critères 5 et 6 : première utilisation, mise à jour

    /// Un `yt-dlp` déjà présent n'est **pas** retéléchargé (critère 6) ; son absence donne
    /// l'installation (critère 5) ; et l'URL épinglée est celle du binaire **officiel** — c'est
    /// elle que la carte d'implémentation téléchargera réellement.
    func testUnYtDlpPresentNestPasRetelechargeEtLUrlEstCelleDeLOfficiel() {
        XCTAssertEqual(
            AcquisitionDiagnostics.bootstrapStep(for: .present(version: "2026.08.19")), .reuse,
            "contrat lot 6 : non implémenté — étape rendue pour un yt-dlp déjà présent : \(AcquisitionDiagnostics.bootstrapStep(for: .present(version: "2026.08.19")))")
        XCTAssertEqual(
            AcquisitionDiagnostics.bootstrapStep(for: .absent), .install,
            "contrat lot 6 : non implémenté — étape rendue pour une première utilisation : \(AcquisitionDiagnostics.bootstrapStep(for: .absent))")
        XCTAssertEqual(
            AcquisitionDiagnostics.ytDlpDownloadURL.absoluteString,
            "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos",
            "contrat lot 6 : non implémenté — URL du binaire rendue : « \(AcquisitionDiagnostics.ytDlpDownloadURL.absoluteString) »")
    }

    /// Un échec d'acquisition déclenche **une** tentative de mise à jour **avant** que l'échec soit
    /// annoncé (critère 6) ; une fois la mise à jour tentée, l'échec est annoncé — sans seconde
    /// tentative, qui ferait boucler l'application sur une source durablement inaccessible.
    func testLaMiseAJourEstTenteeAvantDAnnoncerLEchec() {
        XCTAssertEqual(
            AcquisitionDiagnostics.recoveryStep(updateAlreadyAttempted: false), .update,
            "contrat lot 6 : non implémenté — réaction à un premier échec : \(AcquisitionDiagnostics.recoveryStep(updateAlreadyAttempted: false))")
        XCTAssertEqual(
            AcquisitionDiagnostics.recoveryStep(updateAlreadyAttempted: true), .report,
            "contrat lot 6 : non implémenté — réaction après une mise à jour déjà tentée : \(AcquisitionDiagnostics.recoveryStep(updateAlreadyAttempted: true))")
    }

    // MARK: - Critère 7 : le bloc copiable

    /// Un échec persistant produit un bloc copiable : **version** de `yt-dlp` réellement constatée,
    /// **URL** de la source, **code de sortie**, **début de la sortie brute** borné — et rien du
    /// travail privé de l'utilisateur : aucun chemin (audio téléchargé, répertoire de travail,
    /// transcript), aucun contenu audio, aucun texte transcrit.
    func testUnEchecPersistantProduitUnBlocCopiableSansAudioNiTranscript() {
        let travail = "/Users/quelquun/Library/Application Support/Murmure/Transcripts/work/9f2c1a"
        let audio = "\(travail)/source.m4a"
        let transcript =
            "/Users/quelquun/Library/Application Support/Murmure/Transcripts/demonstration-2026-09-20-ab12cd34.json"
        let texteTranscrit = "TEXTE TRANSCRIT QUI NE DOIT PAS FUITER"
        let brut =
            "ERROR: unable to download video data: HTTP Error 403: Forbidden\n"
            + "(downloaded audio: \(audio); units read from \(travail)/units/0000.wav)\n"
            + "transcript: \(transcript)\n"
            + String(repeating: "w", count: 20_000) + "TAIL-MARQUEUR"

        let bloc = AcquisitionDiagnostics.failureReport(
            kind: .sourceUnavailable,
            source: adresse,
            ytDlpVersion: "2026.08.19",
            exitCode: 1,
            stderr: brut,
            redacting: [audio, travail, transcript],
            stderrLimit: 1_000)

        XCTAssertFalse(
            bloc.isEmpty, "contrat lot 6 : non implémenté — bloc vide")
        XCTAssertTrue(
            bloc.contains(adresse),
            "contrat lot 6 : non implémenté — l'URL de la source est absente du bloc :\n\(bloc)")
        XCTAssertNotNil(
            bloc.range(of: #"yt-dlp[^\n]*2026\.08\.19"#, options: .regularExpression),
            "contrat lot 6 : non implémenté — la version de yt-dlp est absente du bloc :\n\(bloc)")
        XCTAssertNotNil(
            bloc.range(of: #"(exit|code)[^\n]*1"#, options: .regularExpression),
            "contrat lot 6 : non implémenté — le code de sortie est absent du bloc :\n\(bloc)")
        XCTAssertTrue(
            bloc.contains("HTTP Error 403"),
            "contrat lot 6 : non implémenté — la sortie brute de l'outil est absente du bloc :\n\(bloc)")
        XCTAssertFalse(
            bloc.contains("TAIL-MARQUEUR"),
            "contrat lot 6 : non implémenté — la sortie brute n'est pas bornée (limite : 1 000) :\n\(bloc.suffix(200))")
        XCTAssertNotNil(
            bloc.range(of: "omitted|tronqu", options: [.regularExpression, .caseInsensitive]),
            "contrat lot 6 : non implémenté — le bloc ne dit pas qu'il a tronqué :\n\(bloc.suffix(200))")
        XCTAssertLessThan(
            bloc.count, 1_000 + 2_000,
            "contrat lot 6 : non implémenté — bloc de \(bloc.count) caractères pour une limite de 1 000")
        XCTAssertFalse(
            bloc.contains(audio),
            "contrat lot 6 : non implémenté — chemin de l'audio téléchargé recopié :\n\(bloc)")
        XCTAssertFalse(
            bloc.contains(travail),
            "contrat lot 6 : non implémenté — chemin du répertoire de travail recopié :\n\(bloc)")
        XCTAssertFalse(
            bloc.contains(transcript),
            "contrat lot 6 : non implémenté — chemin d'un transcript recopié :\n\(bloc)")
        XCTAssertFalse(
            bloc.contains(texteTranscrit),
            "contrat lot 6 : non implémenté — un texte transcrit se retrouve dans le bloc :\n\(bloc)")
    }

    /// **Critère 7** — le texte nomme la cause (la classification n'est pas décorative) ; **plan
    /// §2.3** — l'avertissement de `yt-dlp` sur l'absence de runtime JavaScript devient une remarque
    /// du bloc, au lieu d'un échec muet.
    func testLaClassificationDecideDuMessageEtDesNotes() {
        let brut = "ERROR: unable to download video data: HTTP Error 403: Forbidden\n"

        // Tout est identique d'un appel à l'autre, **sauf la classification** : si les deux textes
        // sont égaux, c'est que `kind` n'est pas utilisé.
        let pasInstalle = AcquisitionDiagnostics.failureReport(
            kind: .toolNotInstalled, source: adresse, ytDlpVersion: "2026.08.19", exitCode: 1,
            stderr: brut, redacting: [])
        let sourceInaccessible = AcquisitionDiagnostics.failureReport(
            kind: .sourceUnavailable, source: adresse, ytDlpVersion: "2026.08.19", exitCode: 1,
            stderr: brut, redacting: [])

        XCTAssertFalse(
            pasInstalle.isEmpty,
            "contrat lot 6 : non implémenté — bloc vide pour un yt-dlp jamais installé")
        XCTAssertFalse(
            sourceInaccessible.isEmpty,
            "contrat lot 6 : non implémenté — bloc vide pour une source inaccessible")
        XCTAssertNotNil(
            pasInstalle.range(of: "yt-dlp", options: [.regularExpression, .caseInsensitive]),
            "contrat lot 6 : non implémenté — le message ne nomme pas l'outil en cause :\n\(pasInstalle)")
        XCTAssertNotEqual(
            pasInstalle, sourceInaccessible,
            "contrat lot 6 : non implémenté — deux classifications différentes rendent le même texte : la classification n'est pas utilisée")

        // Plan §2.3 : la signature d'avertissement devient une remarque qui nomme ce qui manque.
        let avertissement =
            "WARNING: [youtube] Some formats may be missing. Install a JavaScript runtime, e.g. Deno\n"
        let notes = AcquisitionDiagnostics.notes(inOutput: avertissement)
        XCTAssertFalse(
            notes.isEmpty,
            "contrat lot 6 : non implémenté — aucune remarque tirée de l'avertissement §2.3 :\n\(avertissement)")
        XCTAssertTrue(
            notes.contains { $0.lowercased().contains("javascript") },
            "contrat lot 6 : non implémenté — la remarque ne nomme pas ce qui manque (le runtime JavaScript, plan §2.3) : \(notes)")

        // Contrôle négatif apparié : le bloc porte déjà la sortie brute et son code de sortie ; une
        // sortie sans signature connue n'invente aucune remarque (et « rendre la sortie comme
        // remarque » ne passe donc pas ce cas).
        XCTAssertTrue(
            AcquisitionDiagnostics.notes(inOutput: brut).isEmpty,
            "contrat lot 6 : non implémenté — remarques inventées sur une sortie sans signature connue : \(AcquisitionDiagnostics.notes(inOutput: brut))")
    }
}
