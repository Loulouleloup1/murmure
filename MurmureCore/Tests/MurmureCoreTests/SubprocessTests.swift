import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 4 : lancer un binaire externe et lire sa sortie (plan §4 lot 4).
///
/// Ce que ces tests protègent, au-delà du lancement : **la sortie arrive pendant que le processus
/// tourne** (la barre de progression du critère 18 n'existe pas si tout arrive à la fin), **le
/// délai arrête vraiment le processus** (une acquisition réseau qui ne rend jamais la main bloque
/// la file d'attente du lot 10), et **l'environnement est celui qu'on donne** (le critère 3, « zéro
/// réseau » sur un fichier local, ne doit pas dépendre du `PATH` ni des proxies de la session de
/// l'utilisateur).
///
/// Aucun contenu réel n'est manipulé ici : les processus lancés sont `/bin/sh`, `/bin/sleep` et un
/// chemin inexistant. C'est le seul endroit du lot où un binaire du système est légitime — le
/// contrat ne dit pas *quel* binaire s'exécute, il dit comment sa sortie est rendue.
///
/// Tous ces tests échouent sur une **assertion explicite** tant que le corps sentinelle de
/// `Subprocess.swift` n'a pas été remplacé.
final class SubprocessTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let sleep = URL(fileURLWithPath: "/bin/sleep")

    // MARK: - Sortie, code de sortie

    /// Les lignes de `stdout` sont rendues une par une (`onLine`) **et** recollées (`stdout`),
    /// et le code de sortie est celui du processus.
    func testLaSortieEstCaptureeLigneALigneEtLeCodeDeSortieRendu() throws {
        var lignes: [String] = []
        let resultat = try Subprocess.run(
            shell,
            arguments: ["-c", "printf 'a\\nb\\nc\\n'"],
            timeout: 30,
            onLine: { lignes.append($0) })

        XCTAssertEqual(
            resultat.exitCode, 0,
            "contrat lot 4 : non implémenté — code de sortie rendu : \(resultat.exitCode)")
        XCTAssertFalse(
            resultat.timedOut, "contrat lot 4 : non implémenté — expiration signalée à tort")
        XCTAssertEqual(
            resultat.stdout, "a\nb\nc\n",
            "contrat lot 4 : non implémenté — stdout rendu : « \(resultat.stdout) »")
        XCTAssertEqual(
            lignes, ["a", "b", "c"],
            "contrat lot 4 : non implémenté — lignes rendues en direct : \(lignes)")
    }

    /// Un code de sortie non nul est un **résultat**, pas une exception : les outils qui échouent
    /// (`yt-dlp` sur un 403, `ffmpeg` sur un format refusé) doivent être diagnosticables
    /// (critère 7).
    func testLeCodeDeSortieNonNulEstRenduTelQuel() throws {
        let resultat = try Subprocess.run(shell, arguments: ["-c", "exit 7"], timeout: 30)

        XCTAssertEqual(
            resultat.exitCode, 7,
            "contrat lot 4 : non implémenté — code de sortie rendu : \(resultat.exitCode)")
        XCTAssertFalse(resultat.timedOut, "contrat lot 4 : non implémenté — expiration signalée à tort")
    }

    /// Les deux flux ne sont pas mélangés : `ffmpeg` écrit `silencedetect` sur `stderr` et
    /// `yt-dlp` sa progression sur `stdout` ; les confondre rendrait la carte de silence illisible.
    func testStdoutEtStderrNeSontPasMelanges() throws {
        let resultat = try Subprocess.run(
            shell, arguments: ["-c", "echo out; echo err 1>&2"], timeout: 30)

        XCTAssertTrue(
            resultat.stdout.contains("out"),
            "contrat lot 4 : non implémenté — stdout rendu : « \(resultat.stdout) »")
        XCTAssertFalse(
            resultat.stdout.contains("err"),
            "contrat lot 4 : non implémenté — stderr est tombé dans stdout : « \(resultat.stdout) »")
        XCTAssertTrue(
            resultat.stderr.contains("err"),
            "contrat lot 4 : non implémenté — stderr rendu : « \(resultat.stderr) »")
    }

    /// Le délai **arrête** le processus : un `sleep 30` avec un délai d'une seconde ne doit pas
    /// rendre la main au bout de 30 s. La mesure du temps écoulé est ce qui distingue un vrai
    /// arrêt d'un drapeau posé après coup.
    func testLeDelaiArreteVraimentLeProcessus() throws {
        let debut = Date()
        let resultat = try Subprocess.run(sleep, arguments: ["30"], timeout: 1)
        let ecoule = Date().timeIntervalSince(debut)

        XCTAssertTrue(
            resultat.timedOut,
            "contrat lot 4 : non implémenté — expiration non signalée (code \(resultat.exitCode))")
        XCTAssertLessThan(
            ecoule, 5,
            "contrat lot 4 : non implémenté — le processus n'a pas été arrêté : \(ecoule) s")
        XCTAssertNotEqual(
            resultat.exitCode, 0, "contrat lot 4 : non implémenté — code de sortie nul après arrêt")
    }

    /// La première ligne arrive **pendant** l'exécution, pas à la fin : c'est la seule façon
    /// d'afficher une progression (critère 18) sur un téléchargement de 73 Mo.
    func testLaSortieArrivePendantLexecution() throws {
        var horodatages: [String: Date] = [:]
        let resultat = try Subprocess.run(
            shell,
            arguments: ["-c", "echo premier; sleep 0.6; echo second"],
            timeout: 30,
            onLine: { horodatages[$0] = Date() })
        let fin = Date()

        XCTAssertEqual(
            resultat.stdout, "premier\nsecond\n",
            "contrat lot 4 : non implémenté — stdout rendu : « \(resultat.stdout) »")
        let premier = try XCTUnwrap(
            horodatages["premier"],
            "contrat lot 4 : non implémenté — aucune ligne rendue en direct")
        XCTAssertGreaterThan(
            fin.timeIntervalSince(premier), 0.25,
            "contrat lot 4 : non implémenté — la première ligne n'est arrivée qu'à la fin "
                + "(écart mesuré : \(fin.timeIntervalSince(premier)) s)")
    }

    /// L'environnement donné **remplace** celui de l'appelant.
    func testLEnvironnementInjecteRemplaceCeluiDeLAppelant() throws {
        let resultat = try Subprocess.run(
            shell,
            arguments: ["-c", "printf '%s|%s' \"$MURMURE_TEST\" \"$HOME\""],
            timeout: 30,
            environment: ["MURMURE_TEST": "1"])

        XCTAssertEqual(
            resultat.stdout, "1|",
            "contrat lot 4 : non implémenté — stdout rendu : « \(resultat.stdout) »")
        XCTAssertTrue(
            resultat.stderr.isEmpty,
            "contrat lot 4 : non implémenté — stderr rendu : « \(resultat.stderr) »")
    }

    /// Un exécutable absent est **signalé**, pas rendu comme un code de sortie nul : c'est la
    /// différence entre « l'outil a échoué » et « l'outil n'est pas là » (critères 5 et 7).
    func testUnExecutableAbsentEstSignale() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("murmure-lot4-pas-un-binaire")

        do {
            let resultat = try Subprocess.run(absent, arguments: [], timeout: 5)
            XCTFail(
                "contrat lot 4 : non implémenté — aucun lancement signalé "
                    + "(code rendu : \(resultat.exitCode))")
        } catch let erreur as SubprocessError {
            if case .launchFailed = erreur { return }
            XCTFail("contrat lot 4 : non implémenté — échec inattendu : \(erreur)")
        } catch {
            XCTFail("contrat lot 4 : non implémenté — échec inattendu : \(error)")
        }
    }
}
