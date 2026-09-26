import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 4 : les trois usages de `ffmpeg` et la lecture de `silencedetect`
/// (plan §4 lot 4).
///
/// Ce que ces tests protègent :
///
/// - **le ffmpeg embarqué**, jamais un nom nu ni un binaire du `PATH` (critère 4) ;
/// - **la carte de silence est lue sur une sortie réelle d'`ffmpeg`** — les fixtures
///   `Fixtures/silencedetect-*.txt` sont des captures véritables (`ffmpeg -af
///   silencedetect=noise=-30dB:duration=0.5` sur un WAV synthétique de 7,5 s : 2 s de ton, 2 s de
///   silence, 2 s de ton, 1,5 s de silence), avec leur en-tête, leurs adresses
///   `[silencedetect @ 0x…]` et leurs valeurs décimales exactes (`4.000063`). Un analyseur écrit
///   contre une sortie idéalisée échoue sur ces fichiers ;
/// - **la tranche est copiée sans ré-encodage** (`-c copy`) et lue par `-ss` **avant** `-i` : sur
///   le WAV décodé 16 kHz mono, c'est ce qui donne des coupes échantillon-exactes et des
///   horodatages qui ne dérivent pas sur 48 unités (§2.1) ;
/// - la sortie d'une analyse **interrompue** (un `silence_start` sans `silence_end`) ne fabrique
///   pas un silence de durée inventée.
///
/// Tous ces tests échouent sur une **assertion explicite** tant que les corps sentinelles de
/// `FfmpegCommand.swift` n'ont pas été remplacés.
final class FfmpegCommandTests: XCTestCase {
    private var racine: URL!
    private var travail: URL!
    private var ffmpeg: URL!

    override func setUpWithError() throws {
        racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FfmpegCommandTests-\(UUID().uuidString)")
        travail = racine.appendingPathComponent("Transcripts/work/9f2c1a")
        ffmpeg = racine.appendingPathComponent("Murmure.app/Contents/Resources/ffmpeg")
        try FileManager.default.createDirectory(at: travail, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: racine)
    }

    // MARK: - Outils

    private func valeur(_ drapeau: String, dans arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: drapeau),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private func nombre(_ drapeau: String, dans arguments: [String]) -> Double? {
        valeur(drapeau, dans: arguments).flatMap(Double.init)
    }

    private func chaineFixture(_ nom: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: nom, withExtension: "txt", subdirectory: "Fixtures"),
            "fixture absente du bundle de tests : Fixtures/\(nom).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Décodage

    /// WAV 16 kHz mono PCM signé 16 bits, dans le répertoire de travail, avec le ffmpeg injecté.
    func testLeDecodageProduitUnWavSeizeKiloMono() {
        let entree = travail.appendingPathComponent("source.webm")
        let sortie = travail.appendingPathComponent("source.wav")
        let inv = FfmpegCommand.decodeToWav16kMono(entree, to: sortie, ffmpeg: ffmpeg)

        XCTAssertEqual(
            inv.executable.path, ffmpeg.path,
            "contrat lot 4 : non implémenté — binaire rendu : « \(inv.executable.path) »")
        XCTAssertEqual(
            valeur("-i", dans: inv.arguments), entree.path,
            "contrat lot 4 : non implémenté — entrée rendue : « \(valeur("-i", dans: inv.arguments) ?? "absente") »")
        XCTAssertEqual(
            valeur("-ac", dans: inv.arguments), "1",
            "contrat lot 4 : non implémenté — canaux rendus : « \(valeur("-ac", dans: inv.arguments) ?? "absents") »")
        XCTAssertEqual(
            valeur("-ar", dans: inv.arguments), "16000",
            "contrat lot 4 : non implémenté — fréquence rendue : « \(valeur("-ar", dans: inv.arguments) ?? "absente") »")
        XCTAssertEqual(
            valeur("-c:a", dans: inv.arguments), "pcm_s16le",
            "contrat lot 4 : non implémenté — codec rendu : « \(valeur("-c:a", dans: inv.arguments) ?? "absent") »")
        XCTAssertEqual(
            inv.arguments.last, sortie.path,
            "contrat lot 4 : non implémenté — sortie rendue : « \(inv.arguments.last ?? "aucune") »")
        XCTAssertTrue(
            inv.arguments.contains("-y"),
            "contrat lot 4 : non implémenté — `-y` absent (l'écrasement serait une question posée à un processus sans terminal) : \(inv.arguments)")
    }

    // MARK: - Détection de silence

    /// `-af silencedetect`, avec les valeurs par défaut **gelées par l'arbitrage `t_e3167e58`**
    /// (`-30dB`, 0,5 s — plan §2.1 révision 6) puis des valeurs injectées (§2.1 : le seuil et la durée
    /// doivent être re-mesurables).
    func testLaDetectionDeSilenceDemandeSilencedetect() throws {
        let entree = travail.appendingPathComponent("source.wav")

        let defaut = FfmpegCommand.silences(of: entree, ffmpeg: ffmpeg)
        XCTAssertEqual(
            defaut.executable.path, ffmpeg.path,
            "contrat lot 4 : non implémenté — binaire rendu : « \(defaut.executable.path) »")
        XCTAssertEqual(
            valeur("-i", dans: defaut.arguments), entree.path,
            "contrat lot 4 : non implémenté — entrée rendue : « \(valeur("-i", dans: defaut.arguments) ?? "absente") »")
        let filtre = try XCTUnwrap(
            valeur("-af", dans: defaut.arguments),
            "contrat lot 4 : non implémenté — aucun `-af` : \(defaut.arguments)")
        XCTAssertTrue(
            filtre.hasPrefix("silencedetect=noise=-30dB:duration="),
            "contrat lot 4 : non implémenté — filtre rendu : « \(filtre) »")
        XCTAssertEqual(
            Double(filtre.components(separatedBy: "duration=").last ?? "") ?? -1, 0.5, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — durée du silence rendue : « \(filtre) »")

        let injecte = FfmpegCommand.silences(of: entree, threshold: "-40dB", duration: 1.25, ffmpeg: ffmpeg)
        let filtreInjecte = try XCTUnwrap(
            valeur("-af", dans: injecte.arguments),
            "contrat lot 4 : non implémenté — aucun `-af` : \(injecte.arguments)")
        XCTAssertTrue(
            filtreInjecte.hasPrefix("silencedetect=noise=-40dB:duration="),
            "contrat lot 4 : non implémenté — filtre rendu : « \(filtreInjecte) »")
        XCTAssertEqual(
            Double(filtreInjecte.components(separatedBy: "duration=").last ?? "") ?? -1, 1.25,
            accuracy: 0.0001,
            "contrat lot 4 : non implémenté — durée du silence rendue : « \(filtreInjecte) »")
    }

    /// **La sortie réelle** (capture de 7,5 s avec deux silences : 2→4.000063 et 6→7.5).
    func testLesSilencesSontLusDansUneSortieReelleDffmpeg() throws {
        let silences = FfmpegCommand.silenceIntervals(
            inFfmpegOutput: try chaineFixture("silencedetect-silences"))

        XCTAssertEqual(
            silences.count, 2,
            "contrat lot 4 : non implémenté — silences lus : \(silences)")
        guard silences.count == 2 else { return }

        XCTAssertEqual(
            silences[0].start, 2, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — début du premier silence : \(silences[0].start)")
        XCTAssertEqual(
            silences[0].end, 4.000063, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — fin du premier silence : \(silences[0].end)")
        XCTAssertEqual(
            silences[1].start, 6, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — début du second silence : \(silences[1].start)")
        XCTAssertEqual(
            silences[1].end, 7.5, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — fin du second silence : \(silences[1].end)")
    }

    /// Une analyse interrompue : la fixture est un **préfixe réel** de la capture précédente,
    /// coupé juste après un `silence_start` (ce qu'écrit `ffmpeg` quand le délai expire). Le
    /// silence sans fin n'a pas de durée : il est ignoré, et le silence complet qui le précède
    /// reste rendu.
    func testUnSilenceSansFinEstIgnore() throws {
        let silences = FfmpegCommand.silenceIntervals(
            inFfmpegOutput: try chaineFixture("silencedetect-tronquee"))

        XCTAssertEqual(
            silences.count, 1,
            "contrat lot 4 : non implémenté — silences lus : \(silences)")
        guard silences.count == 1 else { return }

        XCTAssertEqual(
            silences[0].start, 2, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — début du silence rendu : \(silences[0].start)")
        XCTAssertEqual(
            silences[0].end, 4.000063, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — fin du silence rendu : \(silences[0].end)")
    }

    // MARK: - Tranche

    /// Une unité de 5 min à 300,25 s, copiée du WAV décodé : `-ss` avant `-i`, `-c copy`, aucune
    /// transformation d'échantillonnage.
    func testLaTrancheCopieLePcmSansReencoder() throws {
        let entree = travail.appendingPathComponent("source.wav")
        let sortie = travail.appendingPathComponent("units/0000.wav")
        let inv = FfmpegCommand.slice(entree, at: 300.25, duration: 300, to: sortie, ffmpeg: ffmpeg)

        XCTAssertEqual(
            inv.executable.path, ffmpeg.path,
            "contrat lot 4 : non implémenté — binaire rendu : « \(inv.executable.path) »")
        XCTAssertEqual(
            valeur("-c", dans: inv.arguments), "copy",
            "contrat lot 4 : non implémenté — la tranche ré-encode : « \(valeur("-c", dans: inv.arguments) ?? "aucun codec") »")
        XCTAssertEqual(
            valeur("-i", dans: inv.arguments), entree.path,
            "contrat lot 4 : non implémenté — entrée rendue : « \(valeur("-i", dans: inv.arguments) ?? "absente") »")

        let position = try XCTUnwrap(
            inv.arguments.firstIndex(of: "-ss"),
            "contrat lot 4 : non implémenté — aucun `-ss` : \(inv.arguments)")
        let entreeIndex = try XCTUnwrap(
            inv.arguments.firstIndex(of: "-i"),
            "contrat lot 4 : non implémenté — aucun `-i` : \(inv.arguments)")
        XCTAssertLessThan(
            position, entreeIndex,
            "contrat lot 4 : non implémenté — `-ss` doit précéder `-i` (recherche dans le PCM, "
                + "pas saut de paquets après décodage) : \(inv.arguments)")

        XCTAssertEqual(
            nombre("-ss", dans: inv.arguments) ?? -1, 300.25, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — début rendu : « \(valeur("-ss", dans: inv.arguments) ?? "absent") »")
        XCTAssertEqual(
            nombre("-t", dans: inv.arguments) ?? -1, 300, accuracy: 0.0001,
            "contrat lot 4 : non implémenté — durée rendue : « \(valeur("-t", dans: inv.arguments) ?? "absente") »")
        XCTAssertEqual(
            inv.arguments.last, sortie.path,
            "contrat lot 4 : non implémenté — sortie rendue : « \(inv.arguments.last ?? "aucune") »")
        XCTAssertFalse(
            inv.arguments.contains("-ar"),
            "contrat lot 4 : non implémenté — la tranche ré-échantillonne : \(inv.arguments)")
        XCTAssertFalse(
            inv.arguments.contains("-ac"),
            "contrat lot 4 : non implémenté — la tranche remixe les canaux : \(inv.arguments)")
    }
}
