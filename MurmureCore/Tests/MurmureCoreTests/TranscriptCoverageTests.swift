import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 2 : **la mesure du critère 9** — « la couverture cumulée des segments est
/// ≥ 97 % de la durée audio et les horodatages sont strictement croissants (début < fin, aucune
/// régression), avec ≥ 1 segment pour 30 s » (SPEC, critères d'acceptation).
///
/// Ces tests figent ce que le seuil ne dit pas et qui décide pourtant du verdict :
/// - la couverture est une **union** d'intervalles, jamais la somme des durées — sinon deux copies
///   de la moitié de l'audio passeraient pour 100 %, soit un faux vert sur le seul critère qui dit
///   si l'audio a été transcrit en entier ;
/// - deux segments **jointifs** ne sont pas une régression, un **chevauchement** en est une ;
/// - une durée nulle rend `0` (jamais une division par zéro, jamais un `NaN`).
///
/// Tous ces cas échouent sur une **assertion explicite** tant que le corps sentinelle de
/// `TranscriptCoverage.of(segments:duration:)` n'a pas été remplacé.
final class TranscriptCoverageTests: XCTestCase {
    private let contrat = "contrat lot 2 : non implémenté"

    // MARK: - Outils

    /// Des segments **jointifs** qui couvrent exactement `[0, total]`, découpés en tranches de
    /// `longueur` secondes : la couverture attendue est `total`.
    private func couvre(_ total: Double, par longueur: Double) -> [TranscriptSegment] {
        let compte = Int((total / longueur).rounded())
        return (0..<compte).map { rang in
            TranscriptSegment(
                start: Double(rang) * longueur, end: Double(rang + 1) * longueur,
                text: "segment \(rang)")
        }
    }

    private func segments(_ intervalles: [(Double, Double)]) -> [TranscriptSegment] {
        intervalles.enumerated().map { rang, bornes in
            TranscriptSegment(start: bornes.0, end: bornes.1, text: "segment \(rang)")
        }
    }

    // MARK: - Le cas nominal du critère

    /// 38 minutes d'audio (2 280 s), transcrites à 98 % : le critère 9 est satisfait — la
    /// couverture dépasse 97 %, les horodatages sont croissants, et il y a plus d'un segment par
    /// demi-minute. C'est la mesure que le lot 8 lira pour accepter une transcription.
    func testTrenteHuitMinutesCouvertesAQuatreVingtDixHuitPourCent() {
        let mesure = TranscriptCoverage.of(segments: couvre(2234.4, par: 22.8), duration: 2280)

        XCTAssertEqual(mesure.ratio, 0.98, accuracy: 1e-9, contrat)
        XCTAssertTrue(mesure.ratio >= 0.97, contrat)
        XCTAssertTrue(mesure.isMonotonic, contrat)
        XCTAssertTrue(mesure.segmentsPer30s >= 1, contrat)
    }

    /// Le seuil lui-même : 970 s couvertes sur 1 000 s valent **exactement** 0,97, donc le critère
    /// passe au ras du seuil. Un calcul qui perdrait un centième ici refuserait une transcription
    /// complète.
    func testLaCouvertureAuSeuilDeQuatreVingtDixSeptPourCentPasse() {
        let mesure = TranscriptCoverage.of(segments: couvre(970, par: 10), duration: 1000)

        XCTAssertEqual(mesure.ratio, 0.97, accuracy: 1e-12, contrat)
        XCTAssertTrue(mesure.ratio >= 0.97, contrat)
        XCTAssertTrue(mesure.isMonotonic, contrat)
    }

    /// Deux segments jointifs couvrent toute la durée : la jointure n'est pas une régression et la
    /// seconde n'est pas « en trop ».
    func testDeuxSegmentsJointifsCouvrentTouteLaDuree() {
        let mesure = TranscriptCoverage.of(segments: couvre(100, par: 50), duration: 100)

        XCTAssertEqual(mesure.ratio, 1, accuracy: 1e-12, contrat)
        XCTAssertTrue(mesure.isMonotonic, contrat)
    }

    // MARK: - L'union, pas la somme

    /// 60 s + 60 s sur un audio de 100 s : la seconde moitié du second segment recouvre la
    /// première du premier. La couverture vaut 100 %, pas 120 % — et `ratio` reste dans `[0, 1]`.
    func testUnChevauchementNeComptePasDeuxFois() {
        let mesure = TranscriptCoverage.of(
            segments: segments([(0, 60), (40, 100)]), duration: 100)

        XCTAssertEqual(mesure.ratio, 1, accuracy: 1e-12, contrat)
        XCTAssertLessThanOrEqual(mesure.ratio, 1, contrat)
    }

    /// Un segment qui dépasse la fin de l'audio ne couvre pas plus que l'audio : le surplus est
    /// hors de la fenêtre, et la partie couverte se mesure toujours depuis le début.
    func testUnSegmentQuiDepasseLaDureeNeCouvrePasPlusQueLAudio() {
        let debordant = TranscriptCoverage.of(segments: segments([(0, 120)]), duration: 100)
        let partiel = TranscriptCoverage.of(segments: segments([(50, 120)]), duration: 100)

        XCTAssertEqual(debordant.ratio, 1, accuracy: 1e-12, contrat)
        XCTAssertEqual(partiel.ratio, 0.5, accuracy: 1e-12, contrat)
    }

    /// Le ratio ne dépend pas de l'ordre des segments : c'est une propriété de l'ensemble, et le
    /// document peut très bien les porter dans un autre ordre après un recollage (lot 3).
    func testLeRatioNeDependPasDeLOrdreDesSegments() {
        let dansLOrdre = TranscriptCoverage.of(
            segments: segments([(0, 30), (70, 100)]), duration: 100)
        let aLEnvers = TranscriptCoverage.of(
            segments: segments([(70, 100), (0, 30)]), duration: 100)

        XCTAssertEqual(dansLOrdre.ratio, 0.6, accuracy: 1e-12, contrat)
        XCTAssertEqual(aLEnvers.ratio, dansLOrdre.ratio, accuracy: 1e-12, contrat)
    }

    // MARK: - Zéro segment, durée nulle

    /// Aucun segment : rien ne régresse (vacuité), donc `isMonotonic` est vrai et c'est `ratio` qui
    /// dit qu'il n'y a rien à couvrir — y compris à durée nulle, où rien ne se divise par zéro.
    func testAucunSegmentEstCroissantParVacuiteEtCouvreZero() {
        let aDureeNulle = TranscriptCoverage.of(segments: [], duration: 0)
        let aDureeValide = TranscriptCoverage.of(segments: [], duration: 300)

        XCTAssertTrue(aDureeNulle.isMonotonic, contrat)
        XCTAssertEqual(aDureeNulle.ratio, 0, accuracy: 1e-12, contrat)
        XCTAssertEqual(aDureeNulle.segmentsPer30s, 0, accuracy: 1e-12, contrat)
        XCTAssertTrue(aDureeValide.isMonotonic, contrat)
        XCTAssertEqual(aDureeValide.ratio, 0, accuracy: 1e-12, contrat)
        XCTAssertEqual(aDureeValide.segmentsPer30s, 0, accuracy: 1e-12, contrat)
    }

    /// Durée nulle avec des segments : `0` partout, aucun `NaN` — et le **contrôle** au même
    /// instant avec une durée valide rend bien une mesure non nulle, sans quoi ce test serait vert
    /// même sans implémentation.
    func testUneDureeNulleRendZeroSansNaNEtLeControleADureeValideMesure() {
        let nulle = TranscriptCoverage.of(segments: segments([(0, 100)]), duration: 0)
        let controle = TranscriptCoverage.of(segments: segments([(0, 100)]), duration: 200)

        XCTAssertEqual(nulle.ratio, 0, accuracy: 1e-12, contrat)
        XCTAssertEqual(nulle.segmentsPer30s, 0, accuracy: 1e-12, contrat)
        XCTAssertFalse(nulle.ratio.isNaN, contrat)
        XCTAssertFalse(nulle.segmentsPer30s.isNaN, contrat)
        XCTAssertEqual(controle.ratio, 0.5, accuracy: 1e-12, contrat)
    }

    // MARK: - Les horodatages

    /// Un segment qui commence avant la fin du précédent est une régression : `isMonotonic` est
    /// faux. Le **contrôle** juste derrière (deux segments jointifs) est vrai, sinon l'assertion
    /// serait verte avec une implémentation qui rend toujours `false`.
    func testUnChevauchementEstUneRegressionEtUneJointureNon() {
        let chevauche = TranscriptCoverage.of(segments: segments([(0, 10), (8, 20)]), duration: 20)
        let jointif = TranscriptCoverage.of(segments: segments([(0, 10), (10, 20)]), duration: 20)

        XCTAssertFalse(chevauche.isMonotonic, contrat)
        XCTAssertTrue(jointif.isMonotonic, contrat)
    }

    /// « début < fin » : un segment de longueur nulle ou inversée n'est pas croissant, même seul
    /// dans la liste. Le **contrôle** d'un segment bien formé est vrai.
    func testUnSegmentDeLongueurNulleOuInverseeNEstPasCroissant() {
        let nul = TranscriptCoverage.of(segments: segments([(10, 10)]), duration: 20)
        let inverse = TranscriptCoverage.of(segments: segments([(12, 10)]), duration: 20)
        let valide = TranscriptCoverage.of(segments: segments([(10, 11)]), duration: 20)

        XCTAssertFalse(nul.isMonotonic, contrat)
        XCTAssertFalse(inverse.isMonotonic, contrat)
        XCTAssertTrue(valide.isMonotonic, contrat)
    }

    // MARK: - La densité

    /// « ≥ 1 segment pour 30 s » : dix segments de 30 s sur 300 s valent exactement `1`, neuf
    /// valent `0,9` — c'est-à-dire en dessous du seuil du critère 9.
    func testUnSegmentParDemiMinuteEstLeSeuilDuCritere() {
        let dix = TranscriptCoverage.of(segments: couvre(300, par: 30), duration: 300)
        let neuf = TranscriptCoverage.of(segments: Array(couvre(300, par: 30).dropLast()), duration: 300)

        XCTAssertEqual(dix.segmentsPer30s, 1, accuracy: 1e-12, contrat)
        XCTAssertEqual(neuf.segmentsPer30s, 0.9, accuracy: 1e-12, contrat)
        XCTAssertTrue(dix.segmentsPer30s >= 1, contrat)
    }
}
