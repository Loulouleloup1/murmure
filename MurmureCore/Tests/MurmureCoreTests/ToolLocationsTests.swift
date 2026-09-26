import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 4 : où sont les deux binaires externes de l'acquisition (plan §4 lot 4).
///
/// Ce que ces tests protègent : **le `ffmpeg` qui s'exécute est celui du bundle** (critère 4 —
/// build LGPL ; la machine de développement porte un ffmpeg Homebrew GPL à
/// `/opt/homebrew/bin/ffmpeg`, donc une implémentation qui prendrait le premier `ffmpeg` venu
/// passerait à l'œil et échoue ici), et **`yt-dlp` vit sous `Application Support`** (critère 5),
/// là où il peut être téléchargé puis mis à jour sans re-signer l'application.
///
/// Les deux fonctions sont **pures** : les tests ne créent jamais l'arborescence qu'elles
/// décrivent. Une implémentation qui lirait le disque, créerait le dossier ou exigerait qu'il
/// existe échoue donc ici, même si son chemin rendu est exact.
///
/// Tous ces tests échouent sur une **assertion explicite** tant que les corps sentinelles de
/// `ToolLocations.swift` n'ont pas été remplacés.
final class ToolLocationsTests: XCTestCase {
    private var racine: URL!

    override func setUpWithError() throws {
        racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ToolLocationsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: racine)
    }

    private enum ErreurFixture: Error {
        case bundleIllisible
    }

    // MARK: - Fixture : un bundle synthétisé

    /// Un vrai `*.bundle` sur disque : `Contents/Info.plist` + `Contents/Resources/`. C'est la
    /// forme que `Bundle(url:)` sait résoudre (`url(forResource:withExtension:)` rend `nil` quand
    /// la ressource manque) — vérifié sur une sonde jetable hors dépôt avant d'écrire ce test,
    /// pour que l'échec éventuel vienne du contrat et pas de la fixture.
    private func bundleFixture(
        avecFfmpeg: Bool, nom: String = "FfmpegFixture.bundle"
    ) throws -> Bundle {
        let bundleURL = racine.appendingPathComponent(nom)
        let ressources = bundleURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: ressources, withIntermediateDirectories: true)
        try Data("lisez-moi\n".utf8).write(to: ressources.appendingPathComponent("lisez-moi.txt"))
        if avecFfmpeg {
            try Data("#!/bin/sh\nexit 0\n".utf8)
                .write(to: ressources.appendingPathComponent("ffmpeg"))
        }
        let info = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.murmure.tests.ffmpeg-fixture</string>
            <key>CFBundlePackageType</key><string>BNDL</string>
            </dict></plist>
            """
        try Data(info.utf8).write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        guard let bundle = Bundle(url: bundleURL) else { throw ErreurFixture.bundleIllisible }
        return bundle
    }

    // MARK: - yt-dlp

    /// `<base>/tools/yt-dlp`, où `base` est `Application Support/Murmure` (critère 5).
    func testLeBinaireYtDlpEstDansToolsSousApplicationSupport() {
        let base = racine.appendingPathComponent("Application Support/Murmure")
        let attendu = base.appendingPathComponent("tools").appendingPathComponent("yt-dlp")
        let obtenu = ToolLocations.ytDlp(in: base)

        XCTAssertEqual(
            obtenu.path, attendu.path,
            "contrat lot 4 : non implémenté — chemin obtenu : « \(obtenu.path) », attendu « \(attendu.path) »")

        // Pureté : la fonction vient de répondre alors que `tools/` n'existe pas, et elle ne l'a
        // pas créé. C'est la même séparation que `Storage.url(subfolder:)` /
        // `Storage.directory(subfolder:)` : demander un chemin ne construit rien.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: base.appendingPathComponent("tools").path),
            "contrat lot 4 : non implémenté — `ytDlp(in:)` a touché le disque")
    }

    /// La base est **injectée**, pas mémorisée : deux bases donnent deux chemins, et rien ne
    /// dépend du répertoire de l'application ni de celui de l'utilisateur.
    func testDeuxBasesDifferentesDonnentDeuxChemins() {
        let une = racine.appendingPathComponent("A/Murmure")
        let autre = racine.appendingPathComponent("B/Murmure")

        XCTAssertNotEqual(
            ToolLocations.ytDlp(in: une).path, ToolLocations.ytDlp(in: autre).path,
            "contrat lot 4 : non implémenté — la base injectée est ignorée")
        XCTAssertTrue(
            ToolLocations.ytDlp(in: une).path.hasSuffix("A/Murmure/tools/yt-dlp"),
            "contrat lot 4 : non implémenté — chemin obtenu : « \(ToolLocations.ytDlp(in: une).path) »")
    }

    // MARK: - ffmpeg

    /// `Murmure.app/Contents/Resources/ffmpeg`, rendu depuis le bundle injecté.
    func testFfmpegEstDansLesRessourcesDuBundle() throws {
        let bundle = try bundleFixture(avecFfmpeg: true)
        let url = ToolLocations.ffmpeg(inBundle: bundle)

        XCTAssertEqual(
            url?.path, bundle.bundlePath + "/Contents/Resources/ffmpeg",
            "contrat lot 4 : non implémenté — chemin obtenu : « \(url?.path ?? "nil") »")
    }

    /// Un bundle sans la ressource rend `nil` : le manque doit être **constaté**, pas remplacé
    /// par un binaire du système. Les deux bundles (avec et sans la ressource) sont dans le **même
    /// cas** : sans le premier, un `nil` de sentinelle passerait pour un vert — mesuré, ce test
    /// était le seul du fichier à passer avant implémentation.
    func testFfmpegAbsentDuBundleRendNil() throws {
        let avecFfmpeg = try bundleFixture(avecFfmpeg: true)
        let sansFfmpeg = try bundleFixture(avecFfmpeg: false, nom: "SansFfmpeg.bundle")

        XCTAssertNotNil(
            sansFfmpeg.url(forResource: "lisez-moi", withExtension: "txt"),
            "fixture invalide — le bundle synthétisé n'est pas résoluble")
        XCTAssertNotNil(
            ToolLocations.ffmpeg(inBundle: avecFfmpeg),
            "contrat lot 4 : non implémenté — un bundle qui porte `ffmpeg` doit le rendre")
        XCTAssertNil(
            ToolLocations.ffmpeg(inBundle: sansFfmpeg),
            "contrat lot 4 : non implémenté — un bundle sans ffmpeg doit rendre nil")
    }

    /// Le chemin rendu est **dans le bundle**, jamais celui du `PATH`.
    func testFfmpegNestJamaisPrisDansLePath() throws {
        let bundle = try bundleFixture(avecFfmpeg: true)
        let url = try XCTUnwrap(
            ToolLocations.ffmpeg(inBundle: bundle),
            "contrat lot 4 : non implémenté — aucun ffmpeg rendu pour un bundle qui en porte un")

        XCTAssertTrue(
            url.path.hasPrefix(bundle.bundlePath + "/"),
            "contrat lot 4 : non implémenté — ffmpeg hors du bundle : « \(url.path) »")
        XCTAssertNotEqual(
            url.path, "/opt/homebrew/bin/ffmpeg",
            "contrat lot 4 : non implémenté — c'est le ffmpeg GPL du PATH qui a été rendu")
        XCTAssertNotEqual(
            url.path, "/usr/bin/ffmpeg",
            "contrat lot 4 : non implémenté — c'est un ffmpeg du système qui a été rendu")
    }
}
