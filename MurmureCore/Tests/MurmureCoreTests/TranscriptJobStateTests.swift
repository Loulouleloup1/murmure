import Foundation
import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 3 : **l'état d'un travail et la reprise** (plan §2.1, §2.4 arbitrage N1,
/// §4 lot 3).
///
/// C'est le fichier qui porte la réponse au piège n°1 de la SPEC. WhisperKit n'a aucune API de
/// pause/reprise : ce qui rend un travail interrompu reprenable, c'est `progress.json` — la liste
/// des unités, l'état, la dernière unité terminée. Ces tests gèlent la seule chose que le moteur
/// (lot 8) ait à demander après un arrêt : **l'index de la première unité non terminée**, et le
/// fait qu'aucune unité déjà terminée ne soit rejouée.
///
/// Tous ces tests échouent sur une **assertion explicite** (message « contrat lot 3 : non
/// implémenté ») tant que les corps sentinelles de `TranscriptJobState.swift` n'ont pas été
/// remplacés — jamais sur une erreur de compilation (plan §7.1, règle 4).
final class TranscriptJobStateTests: XCTestCase {
    // MARK: - Outils

    private func unites(_ nombre: Int, pas: Double = 300) -> [UnitBoundary] {
        (0..<nombre).map { index in
            UnitBoundary(start: Double(index) * pas, duration: pas, quality: .silence)
        }
    }

    private func json(_ etat: TranscriptJobState) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let donnees = try? encoder.encode(etat) else { return nil }
        return try? JSONSerialization.jsonObject(with: donnees) as? [String: Any]
    }

    // MARK: - Le point de reprise

    /// Avant tout travail, le point de reprise est l'unité 0 ; chaque `advance()` marque la
    /// première unité non terminée et **ne recule jamais** : la progression obtenue est 0, 1, 2.
    func testLePointDeRepriseEstLaPremiereUniteNonTerminee() {
        var etat = TranscriptJobState(units: unites(5))

        XCTAssertNil(
            etat.lastCompletedUnit,
            "contrat lot 3 : non implémenté — un travail neuf n'a aucune unité terminée, obtenu \(String(describing: etat.lastCompletedUnit))")
        XCTAssertEqual(
            etat.nextUnitIndex, 0,
            "contrat lot 3 : non implémenté — un travail neuf de 5 unités reprend à l'unité 0, obtenu \(String(describing: etat.nextUnitIndex))")

        var progression: [Int] = []
        for attendu in 0..<3 {
            etat.advance()
            guard let dernier = etat.lastCompletedUnit else {
                XCTFail(
                    "contrat lot 3 : non implémenté — advance() n'a marqué aucune unité terminée (lastCompletedUnit reste nil)")
                return
            }
            progression.append(dernier)
            XCTAssertEqual(
                dernier, attendu,
                "contrat lot 3 : non implémenté — après \(attendu + 1) advance(), la dernière unité terminée doit être l'unité \(attendu), obtenu \(dernier)")
        }
        XCTAssertEqual(
            progression, [0, 1, 2],
            "contrat lot 3 : non implémenté — la progression obtenue saute ou recule : \(progression)")
        XCTAssertEqual(
            etat.nextUnitIndex, 3,
            "contrat lot 3 : non implémenté — trois unités terminées sur cinq, la reprise est à l'unité 3, obtenu \(String(describing: etat.nextUnitIndex))")
        XCTAssertEqual(
            etat.state, .running,
            "contrat lot 3 : non implémenté — un travail qui avance est en cours, état obtenu \(etat.state.rawValue)")
    }

    // MARK: - La reprise après pause

    /// **Le cas obligatoire de la carte QA L3.** Après trois unités et une pause, le progrès est
    /// écrit et relu tel quel (c'est ce que fait `progress.json`), et la reprise repart de la
    /// **première unité non terminée** : ni l'unité 0, ni une unité déjà écrite sur disque.
    func testUneRepriseApresPauseRepartALaPremiereUniteNonTermineeSansEnRejouerAucune() {
        var etat = TranscriptJobState(units: unites(5))
        for _ in 0..<3 { etat.advance() }

        guard etat.lastCompletedUnit == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — trois advance() doivent terminer les unités 0 à 2, dernière obtenue : \(String(describing: etat.lastCompletedUnit))")
            return
        }

        etat.pause()
        XCTAssertEqual(
            etat.state, .paused,
            "contrat lot 3 : non implémenté — après pause, l'état doit être paused, obtenu \(etat.state.rawValue)")
        XCTAssertEqual(
            etat.lastCompletedUnit, 2,
            "contrat lot 3 : non implémenté — une pause ne perd pas les unités terminées, dernière obtenue : \(String(describing: etat.lastCompletedUnit))")

        // Le travail est interrompu : ce qui survit, c'est le fichier.
        guard let donnees = try? JSONEncoder().encode(etat),
            let relu = try? JSONDecoder().decode(TranscriptJobState.self, from: donnees)
        else {
            XCTFail(
                "contrat lot 3 : non implémenté — l'état ne survit pas à un aller-retour JSON, donc progress.json est illisible en reprise")
            return
        }
        XCTAssertEqual(
            relu, etat,
            "contrat lot 3 : non implémenté — l'état relu depuis progress.json n'est pas celui qui a été écrit")
        XCTAssertEqual(
            relu.nextUnitIndex, 3,
            "contrat lot 3 : non implémenté — la reprise repart de la première unité non terminée (3), obtenue \(String(describing: relu.nextUnitIndex))")

        var repris = relu
        repris.resume()
        XCTAssertEqual(
            repris.state, .running,
            "contrat lot 3 : non implémenté — après resume(), l'état doit être running, obtenu \(repris.state.rawValue)")
        XCTAssertEqual(
            repris.lastCompletedUnit, 2,
            "contrat lot 3 : non implémenté — une reprise ne rejoue aucune unité : la dernière terminée doit rester 2, obtenue \(String(describing: repris.lastCompletedUnit))")
        XCTAssertEqual(
            repris.nextUnitIndex, 3,
            "contrat lot 3 : non implémenté — après reprise, le point de reprise doit rester l'unité 3 (et non 0), obtenu \(String(describing: repris.nextUnitIndex))")

        repris.advance()
        XCTAssertEqual(
            repris.lastCompletedUnit, 3,
            "contrat lot 3 : non implémenté — le premier advance() après reprise termine l'unité 3, obtenu \(String(describing: repris.lastCompletedUnit))")
        repris.advance()
        XCTAssertEqual(
            repris.lastCompletedUnit, 4,
            "contrat lot 3 : non implémenté — l'unité 4 reste à terminer, obtenu \(String(describing: repris.lastCompletedUnit))")
        XCTAssertEqual(
            repris.state, .complete,
            "contrat lot 3 : non implémenté — plus aucune unité à faire : l'état doit être complete, obtenu \(repris.state.rawValue)")
        XCTAssertNil(
            repris.nextUnitIndex,
            "contrat lot 3 : non implémenté — toutes les unités sont terminées, le point de reprise doit être nil, obtenu \(String(describing: repris.nextUnitIndex))")
    }

    // MARK: - Le fichier progress.json

    /// `progress.json` est lu par le CLI (lot 11) et par un contrôle qualité ultérieur : ses **clés**
    /// et ses **valeurs brutes** comptent. Les frontières gardent celles du document (lot 1), et une
    /// clé sans valeur n'est pas écrite — c'est la convention du schéma.
    func testLeProgresEstEcritDansProgressJSONAvecLesClesDuSchema() {
        var etat = TranscriptJobState(units: unites(5))
        etat.advance()
        etat.advance()
        etat.pause()

        guard let objet = json(etat) else {
            XCTFail("contrat lot 3 : non implémenté — progress.json n'est pas encodable en JSON")
            return
        }
        XCTAssertEqual(
            objet["state"] as? String, "paused",
            "contrat lot 3 : non implémenté — la clé « state » vaut \(String(describing: objet["state"])) au lieu de « paused »")
        XCTAssertEqual(
            objet["lastCompletedUnit"] as? Int, 1,
            "contrat lot 3 : non implémenté — deux unités terminées sur cinq, la dernière est l'unité 1, obtenu \(String(describing: objet["lastCompletedUnit"]))")
        XCTAssertNil(
            objet["error"],
            "contrat lot 3 : non implémenté — une clé sans valeur (nil) ne s'écrit pas, « error » est présente : \(String(describing: objet["error"]))")

        guard let unitesEcrites = objet["units"] as? [[String: Any]] else {
            XCTFail(
                "contrat lot 3 : non implémenté — la clé « units » est absente ou n'est pas une liste : \(String(describing: objet["units"]))")
            return
        }
        XCTAssertEqual(
            unitesEcrites.count, 5,
            "contrat lot 3 : non implémenté — 5 unités attendues dans progress.json, obtenu \(unitesEcrites.count)")
        XCTAssertEqual(
            unitesEcrites.first?["quality"] as? String, "silence",
            "contrat lot 3 : non implémenté — une frontière écrite garde la valeur brute du schéma du document (« silence »), obtenu \(String(describing: unitesEcrites.first?["quality"]))")
        XCTAssertEqual(
            unitesEcrites.first?["duration"] as? Double, 300,
            "contrat lot 3 : non implémenté — la durée de la première unité vaut \(String(describing: unitesEcrites.first?["duration"])) au lieu de 300")

        // Un échec s'enregistre dans la même forme, sans perdre le point de reprise.
        etat.fail("modèle illisible")
        guard let apresEchec = json(etat) else {
            XCTFail("contrat lot 3 : non implémenté — l'état en échec n'est pas encodable en JSON")
            return
        }
        XCTAssertEqual(
            apresEchec["state"] as? String, "failed",
            "contrat lot 3 : non implémenté — après fail(), la clé « state » vaut \(String(describing: apresEchec["state"])) au lieu de « failed »")
        XCTAssertEqual(
            apresEchec["error"] as? String, "modèle illisible",
            "contrat lot 3 : non implémenté — le message d'échec doit être écrit dans « error », obtenu \(String(describing: apresEchec["error"]))")
        XCTAssertEqual(
            apresEchec["lastCompletedUnit"] as? Int, 1,
            "contrat lot 3 : non implémenté — un échec ne fait pas reculer le point de reprise : \(String(describing: apresEchec["lastCompletedUnit"])) au lieu de 1")
        XCTAssertEqual(
            (apresEchec["units"] as? [[String: Any]])?.count, 5,
            "contrat lot 3 : non implémenté — un échec ne perd pas la liste des unités")
    }

    // MARK: - L'échec

    /// Un échec **ne marque pas** l'unité en cours comme terminée : la reprise repart de cette unité
    /// et non de la suivante (arbitrage N1 : un transcript `failed` est repris, pas relancé à froid).
    func testUnEchecNeMarquePasLUniteEnCoursEtSeReprendAlaMemeUnite() {
        var etat = TranscriptJobState(units: unites(5))
        etat.advance()
        etat.advance()

        guard etat.lastCompletedUnit == 1 else {
            XCTFail(
                "contrat lot 3 : non implémenté — deux advance() doivent terminer les unités 0 et 1, dernière obtenue : \(String(describing: etat.lastCompletedUnit))")
            return
        }

        etat.fail("modèle illisible : whisper-large-v3-turbo")
        XCTAssertEqual(
            etat.state, .failed,
            "contrat lot 3 : non implémenté — après fail(), l'état doit être failed, obtenu \(etat.state.rawValue)")
        XCTAssertEqual(
            etat.error, "modèle illisible : whisper-large-v3-turbo",
            "contrat lot 3 : non implémenté — le message d'échec obtenu : \(String(describing: etat.error))")
        XCTAssertEqual(
            etat.lastCompletedUnit, 1,
            "contrat lot 3 : non implémenté — l'unité en cours d'échec n'est pas terminée : la dernière terminée reste 1, obtenue \(String(describing: etat.lastCompletedUnit))")
        XCTAssertEqual(
            etat.nextUnitIndex, 2,
            "contrat lot 3 : non implémenté — après un échec, la reprise repart de l'unité en échec (2) et non de la suivante (3), obtenue \(String(describing: etat.nextUnitIndex))")

        etat.resume()
        XCTAssertEqual(
            etat.state, .running,
            "contrat lot 3 : non implémenté — un travail en échec se reprend (arbitrage N1), état obtenu \(etat.state.rawValue)")
        XCTAssertEqual(
            etat.nextUnitIndex, 2,
            "contrat lot 3 : non implémenté — la reprise après échec rejoue l'unité en échec (2), obtenue \(String(describing: etat.nextUnitIndex))")
        XCTAssertEqual(
            etat.lastCompletedUnit, 1,
            "contrat lot 3 : non implémenté — la reprise ne rejoue aucune unité terminée : dernière obtenue \(String(describing: etat.lastCompletedUnit))")
    }
}
