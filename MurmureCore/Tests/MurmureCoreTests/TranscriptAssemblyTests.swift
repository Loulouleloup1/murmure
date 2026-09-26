import Foundation
import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 3 : **l'assemblage** des unités transcrites en un flux absolu (plan §2.1 et
/// §4 lot 3, critère 9).
///
/// Chaque unité est transcrite séparément et horodatée depuis son propre début : sans ce recollage,
/// le JSON d'un film de 2 h aurait 24 séries d'horodatages qui repartent de zéro et des phrases en
/// double à chaque frontière. Ce que ces tests gèlent est exactement ce que le critère 9 exige du
/// fichier livré : horodatages **absolus** et **strictement croissants** (`début < fin`, aucune
/// régression), aucun segment dupliqué, et une couverture qui se recalcule sans perte.
///
/// Tous ces tests échouent sur une **assertion explicite** (message « contrat lot 3 : non
/// implémenté ») tant que le corps sentinelle de `TranscriptAssembly.swift` n'a pas été remplacé —
/// jamais sur une erreur de compilation (plan §7.1, règle 4).
final class TranscriptAssemblyTests: XCTestCase {
    // MARK: - Outils

    private func unite(
        depart: Double, duree: Double = 300, quality: UnitBoundary.Quality = .silence,
        segments: [(Double, Double, String)]
    ) -> TranscribedUnit {
        TranscribedUnit(
            boundary: UnitBoundary(start: depart, duration: duree, quality: quality),
            segments: segments.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) })
    }

    /// Une unité « réelle » : dix segments presque jointifs, comme WhisperKit en rend — donc une
    /// couverture proche de 100 %, ce qui permet d'éprouver le seuil de 97 % du critère 9.
    private func uniteDense(depart: Double, prefixe: String) -> TranscribedUnit {
        let segments = (0..<10).map { index -> TranscriptSegment in
            let debut = Double(index) * 29.9
            return TranscriptSegment(start: debut, end: debut + 29.8, text: "\(prefixe)\(index)")
        }
        return TranscribedUnit(
            boundary: UnitBoundary(start: depart, duration: 300, quality: .silence),
            segments: segments)
    }

    /// La couverture **recalculée indépendamment** : l'union des intervalles absolus des segments
    /// d'entrée. C'est la quantité que l'assemblage doit rendre sans perte et sans double compte.
    private func couverture(_ unites: [TranscribedUnit]) -> Double {
        var intervalles =
            unites.flatMap { unite in
                unite.segments.map { segment in
                    (unite.boundary.start + segment.start, unite.boundary.start + segment.end)
                }
            }
        intervalles.sort { $0.0 < $1.0 }
        var total = 0.0
        var finCourante = -Double.infinity
        for (debut, fin) in intervalles {
            if debut > finCourante {
                total += fin - debut
            } else if fin > finCourante {
                total += fin - finCourante
            }
            finCourante = max(finCourante, fin)
        }
        return total
    }

    /// Les invariants du critère 9, sur **toute** sortie de l'assemblage : `start < end`, débuts
    /// strictement croissants, et aucune paire de segments qui se chevauchent (règles 2 et 3).
    private func verifierInvariants(_ segments: [TranscriptSegment], contexte: String) {
        for (index, segment) in segments.enumerated() {
            XCTAssertTrue(
                segment.start < segment.end,
                "contrat lot 3 : non implémenté — \(contexte) : le segment \(index) va de \(segment.start) s à \(segment.end) s")
            if index > 0 {
                XCTAssertGreaterThan(
                    segment.start, segments[index - 1].start,
                    "contrat lot 3 : non implémenté — \(contexte) : le début du segment \(index) (\(segment.start) s) n'est pas strictement supérieur à celui du précédent (\(segments[index - 1].start) s)")
            }
        }
        for premier in 0..<segments.count {
            if premier + 1 < segments.count {
                for suivant in (premier + 1)..<segments.count {
                    XCTAssertFalse(
                        segments[suivant].start < segments[premier].end,
                        "contrat lot 3 : non implémenté — \(contexte) : le segment \(premier) [\(segments[premier].start), \(segments[premier].end)] et le segment \(suivant) [\(segments[suivant].start), \(segments[suivant].end)] se chevauchent")
                }
            }
        }
    }

    // MARK: - Le cas obligatoire de la carte : trois unités

    /// **Le cas obligatoire de la carte QA L3.** Trois unités de 5 min, dix segments chacune : le
    /// flux assemblé est strictement croissant, chaque horodatage vaut « début d'unité + horodatage
    /// local », aucun segment n'est dupliqué, et la couverture recalculée reste celle des entrées —
    /// donc au-dessus des 97 % du critère 9.
    func testTroisUnitesDensesDonnentUnFluxCroissantSansDoublonEtCouvert() {
        let unites = [
            uniteDense(depart: 0, prefixe: "a"),
            uniteDense(depart: 300, prefixe: "b"),
            uniteDense(depart: 600, prefixe: "c"),
        ]
        let segments = TranscriptAssembly.merge(units: unites)

        guard segments.count == 30 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 3 unités de 10 segments doivent donner 30 segments, obtenu \(segments.count)"
            )
            return
        }

        verifierInvariants(segments, contexte: "trois unités")

        // Le recollage lui-même : la onzième et la vingt-et-unième phrase appartiennent aux
        // deuxième et troisième unités, donc à 300 s et 600 s — pas à 0 s.
        XCTAssertEqual(
            segments[10].start, 300, accuracy: 1e-9,
            "contrat lot 3 : non implémenté — le premier segment de la deuxième unité commence à \(segments[10].start) s au lieu de 300 s")
        XCTAssertEqual(
            segments[20].start, 600, accuracy: 1e-9,
            "contrat lot 3 : non implémenté — le premier segment de la troisième unité commence à \(segments[20].start) s au lieu de 600 s")

        // Aucun segment dupliqué : trois unités distinctes, donc trente clés distinctes.
        let cles = segments.map { "\($0.start)-\($0.end)-\($0.text)" }
        XCTAssertEqual(
            Set(cles).count, 30,
            "contrat lot 3 : non implémenté — \(30 - Set(cles).count) segment(s) en double dans un assemblage sans chevauchement")

        // Couverture recalculée : aucune seconde perdue, aucune seconde comptée deux fois, et le
        // seuil du critère 9 tenu.
        let couverte = segments.reduce(0.0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(
            couverte, couverture(unites), accuracy: 1e-6,
            "contrat lot 3 : non implémenté — \(couverte) s couvertes par l'assemblage contre \(couverture(unites)) s couvertes par les unités")
        XCTAssertGreaterThanOrEqual(
            couverte / 900, 0.97,
            "contrat lot 3 : non implémenté — couverture de \(couverte / 900) pour un seuil de 97 % (critère 9)")
    }

    // MARK: - Le dédoublonnage à la frontière

    /// **Le cas obligatoire de la carte QA L3.** Une unité dont le dernier segment déborde sur la
    /// suivante — c'est ce que fait WhisperKit quand il repart de son chevauchement — rend la même
    /// phrase deux fois. L'assemblage n'en garde qu'une : c'est le dédoublonnage du plan §2.1.
    func testUnSegmentRepeteALaFrontiereNEStRenduQuUneFois() {
        let premiere = unite(
            depart: 0,
            segments: [(0, 5, "Bonjour"), (294, 305, "Et voilà la suite")])
        let seconde = unite(
            depart: 300,
            segments: [(0, 10, "Et voilà la suite"), (10.5, 20, "puis autre chose")])

        let segments = TranscriptAssembly.merge(units: [premiere, seconde])

        guard segments.count == 3 else {
            XCTFail(
                "contrat lot 3 : non implémenté — la phrase répétée à la frontière doit être rendue une seule fois : 3 segments attendus, obtenu \(segments.count) (\(segments.map { $0.text }))"
            )
            return
        }
        XCTAssertEqual(
            segments.map { $0.text },
            ["Bonjour", "Et voilà la suite", "puis autre chose"],
            "contrat lot 3 : non implémenté — le dédoublonnage a perdu ou réordonné du texte : \(segments.map { $0.text })")
        let premiereOccurrence = segments[1]
        XCTAssertEqual(
            premiereOccurrence.start, 294, accuracy: 1e-9,
            "contrat lot 3 : non implémenté — c'est la première occurrence qui est gardée, elle commence à 294 s, obtenu \(premiereOccurrence.start) s")
        XCTAssertEqual(
            premiereOccurrence.end, 305, accuracy: 1e-9,
            "contrat lot 3 : non implémenté — la première occurrence va jusqu'à 305 s, obtenu \(premiereOccurrence.end) s")
        XCTAssertEqual(
            segments[2].start, 310.5, accuracy: 1e-9,
            "contrat lot 3 : non implémenté — le segment suivant la frontière commence à 310,5 s, obtenu \(segments[2].start) s")
        verifierInvariants(segments, contexte: "frontière dédoublonnée")
    }

    // MARK: - L'arithmétique absolue

    /// L'horodatage absolu est **le début de l'unité plus l'horodatage local** — et le début de
    /// l'unité vient du plan, il n'est pas recalculé depuis le pas nominal : une coupe à 285 s
    /// (celle du plan de morceaux) donne un flux qui commence à 285 s, pas à 300 s.
    func testLHorodatageAbsoluVautLeDebutDeLUnitePlusLHorodatageLocal() {
        let premiere = unite(depart: 0, segments: [(0, 2, "a")])
        let seconde = unite(depart: 285, duree: 15, segments: [(0, 3, "b")])
        let segments = TranscriptAssembly.merge(units: [premiere, seconde])

        guard segments.count == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 2 unités d'un segment doivent donner 2 segments, obtenu \(segments.count)")
            return
        }
        XCTAssertEqual(
            segments[0], TranscriptSegment(start: 0, end: 2, text: "a"),
            "contrat lot 3 : non implémenté — premier segment obtenu : [\(segments[0].start), \(segments[0].end)] « \(segments[0].text) »")
        XCTAssertEqual(
            segments[1], TranscriptSegment(start: 285, end: 288, text: "b"),
            "contrat lot 3 : non implémenté — le segment local [0, 3] de l'unité qui commence à 285 s doit devenir [285, 288], obtenu [\(segments[1].start), \(segments[1].end)]")

        // Un travail interrompu avant sa première unité reste assemblé : la liste vide rend une
        // liste vide, pas un plantage.
        XCTAssertEqual(
            TranscriptAssembly.merge(units: []), [],
            "contrat lot 3 : non implémenté — aucune unité, aucun segment")
    }

    // MARK: - Les cas dégénérés

    /// Un segment de durée nulle ou négative ne peut pas satisfaire « début < fin » : il n'est pas
    /// rendu. Le segment au texte vide, lui, **est** rendu — c'est une pause, pas une erreur, et
    /// le distinguer est ce qui rend le filtre exact.
    func testUnSegmentDeDureeNulleOuNegativeNEstPasRendu() {
        let seule = unite(
            depart: 0,
            segments: [
                (10, 10, "durée nulle"), (20, 18, "inversée"), (30, 32, "bonne"), (40, 45, ""),
            ])
        let segments = TranscriptAssembly.merge(units: [seule])

        guard segments.count == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 2 segments rendus attendus (le valide et celui au texte vide), obtenu \(segments.count) : \(segments.map { "[\($0.start), \($0.end)] « \($0.text) »" })"
            )
            return
        }
        XCTAssertEqual(
            segments.map { $0.text }, ["bonne", ""],
            "contrat lot 3 : non implémenté — textes obtenus : \(segments.map { $0.text })")
        XCTAssertEqual(
            segments[0], TranscriptSegment(start: 30, end: 32, text: "bonne"),
            "contrat lot 3 : non implémenté — segment obtenu : [\(segments[0].start), \(segments[0].end)]")
        verifierInvariants(segments, contexte: "entrée dégénérée")
    }
}
