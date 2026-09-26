import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 9 : **les mesures de la grille de transcripts** (critère 16, plan §4
/// lot 9). Motif `WindowLayout` / `WaveformLayout` — une constante dessinée dans une vue est une
/// décision que rien ne peut vérifier.
///
/// Ce qui est gelé ici n'est pas seulement quatre chiffres, c'est la **relation** entre eux et la
/// fenêtre : combien de colonnes tiennent dans un panneau, quelle largeur chaque tuile reçoit, et
/// ce que cela donne à la largeur minimale de la fenêtre. Les chiffres sont ceux du contrat
/// (200 / 340 / 16 / 20) ; les relations sont ce qui empêche de les bouger sans décision.
///
/// Tous ces cas échouent sur une **assertion explicite** — jamais sur une erreur de compilation —
/// tant que les corps sentinelles de `TranscriptsLayout.swift` n'ont pas été remplacés.
final class TranscriptsLayoutTests: XCTestCase {
    private let contrat = "contrat lot 9 : non implémenté"

    /// Le panneau réel : la fenêtre moins la barre latérale, moins la marge de la grille sur ses
    /// deux bords.
    private func panneau(largeurFenetre: CGFloat, barreLaterale: CGFloat) -> CGFloat {
        largeurFenetre - barreLaterale - 2 * TranscriptsLayout.contentPadding
    }

    /// Toutes les largeurs qu'une fenêtre peut réellement donner à la grille, plus quelques-unes
    /// en dessous — la relation doit tenir sur l'intervalle, pas sur un point choisi.
    private var largeursReelles: [CGFloat] {
        Array(stride(from: TranscriptsLayout.minimumTileWidth, through: 2_000, by: 37))
    }

    // MARK: - Combien de colonnes

    /// Une grille à zéro colonne n'est pas une grille vide : c'est une surface blanche, sans rien
    /// qui explique pourquoi. `WaveformLayout.barCount(inWidth:)` ne rend jamais zéro barre pour la
    /// même raison, et ce qui n'a jamais de barre n'a jamais de tuile non plus.
    func testTheGridNeverHasFewerThanOneColumn() {
        for largeur: CGFloat in [0, 1, 40, 199, 200, 480] {
            XCTAssertGreaterThanOrEqual(TranscriptsLayout.columns(inWidth: largeur), 1, contrat)
        }
    }

    /// Le nombre de colonnes est le **plus grand** qui tienne à la largeur minimale d'une tuile :
    /// `N × 200 + (N − 1) × 16 ≤ largeur`, et une colonne de plus ne tiendrait pas. Les deux
    /// moitiés de la phrase sont vérifiées, sinon un compte trop petit passerait pour un compte
    /// prudent alors qu'il laisse un trou à droite de la grille.
    func testTheColumnsAreTheMostThatFitAtTheMinimumTileWidth() {
        for largeur in largeursReelles {
            let colonnes = TranscriptsLayout.columns(inWidth: largeur)
            let occupe = CGFloat(colonnes) * TranscriptsLayout.minimumTileWidth
                + CGFloat(colonnes - 1) * TranscriptsLayout.tileSpacing
            XCTAssertLessThanOrEqual(occupe, largeur, contrat)

            let uneDePlus = occupe + TranscriptsLayout.minimumTileWidth
                + TranscriptsLayout.tileSpacing
            XCTAssertGreaterThan(uneDePlus, largeur, contrat)
        }
    }

    /// Élargir la fenêtre ne peut pas faire disparaître une colonne : c'est la propriété qu'une
    /// grille doit au redimensionnement, et elle est vérifiée à chaque pas, pas sur deux points.
    func testAWiderPaneNeverGetsFewerColumns() {
        var precedent = 0
        for largeur in stride(from: CGFloat(0), through: 2_000, by: 23) {
            let colonnes = TranscriptsLayout.columns(inWidth: largeur)
            XCTAssertGreaterThanOrEqual(colonnes, precedent, contrat)
            XCTAssertGreaterThanOrEqual(colonnes, 1, contrat)
            precedent = colonnes
        }
    }

    // MARK: - Quelle largeur pour chaque tuile

    /// Le plafond, pris là où il se voit : une seule colonne dans un panneau de 380 pt donnerait
    /// une tuile de 380 pt, et c'est **340** que le contrat a gelé. Plus large, une tuile cesse
    /// d'être une tuile et devient une ligne de texte bordée.
    func testATileIsNeverWiderThanTheMaximum() {
        XCTAssertEqual(
            TranscriptsLayout.tileWidth(inWidth: 380, columns: 1),
            TranscriptsLayout.maximumTileWidth, contrat)
        XCTAssertEqual(
            TranscriptsLayout.tileWidth(inWidth: 2_400, columns: 1),
            TranscriptsLayout.maximumTileWidth, contrat)

        for largeur in largeursReelles {
            let largeurTuile = TranscriptsLayout.tileWidth(
                inWidth: largeur, columns: TranscriptsLayout.columns(inWidth: largeur))
            XCTAssertLessThanOrEqual(
                largeurTuile, TranscriptsLayout.maximumTileWidth, contrat)
            XCTAssertGreaterThanOrEqual(
                largeurTuile, TranscriptsLayout.minimumTileWidth, contrat)
            XCTAssertLessThanOrEqual(largeurTuile, largeur, contrat)
        }
    }

    /// Les tuiles et leurs écarts tiennent dans le panneau qu'on leur a donné : la grille ne
    /// déborde pas à droite, et la dernière colonne n'est pas coupée par le bord de la fenêtre.
    func testTheTilesAndTheirGapsFitThePaneTheyWereGiven() {
        for largeur in largeursReelles {
            let colonnes = TranscriptsLayout.columns(inWidth: largeur)
            let occupe = CGFloat(colonnes)
                * TranscriptsLayout.tileWidth(inWidth: largeur, columns: colonnes)
                + CGFloat(colonnes - 1) * TranscriptsLayout.tileSpacing
            XCTAssertLessThanOrEqual(occupe, largeur, contrat)
        }
    }

    /// **La relation qui compte pour la fenêtre** : à la largeur minimale où l'application peut
    /// être redimensionnée, le panneau porte encore **deux colonnes**. Une seule colonne à cette
    /// largeur serait une liste — c'est-à-dire un autre écran, et pas celui que le plan §4 lot 9
    /// décrit. À la largeur par défaut, il en tient trois, et ce n'est pas une seconde décision :
    /// c'est la conséquence des quatre chiffres ci-dessous.
    func testTheGridFitsTheSmallestWindowTheAppCanBeResizedTo() {
        let etroit = panneau(
            largeurFenetre: WindowLayout.minimumSize.width,
            barreLaterale: WindowLayout.sidebarWidth.maximum)
        XCTAssertGreaterThanOrEqual(TranscriptsLayout.columns(inWidth: etroit), 2, contrat)

        let habituel = panneau(
            largeurFenetre: WindowLayout.defaultSize.width,
            barreLaterale: WindowLayout.sidebarWidth.ideal)
        XCTAssertGreaterThanOrEqual(TranscriptsLayout.columns(inWidth: habituel), 3, contrat)
    }

    /// Les quatre chiffres, gelés par ce contrat comme les valeurs de `WindowLayout` le sont par le
    /// sien. Ce sont eux que la carte `dev` doit écrire dans la grille : les déplacer est une
    /// décision, pas un détail d'implémentation — et la relation à la largeur de lecture (660 pt)
    /// dit pourquoi le plafond n'est pas plus haut.
    func testTheFrozenMeasurementsAreTheOnesTheGridDraws() {
        XCTAssertEqual(TranscriptsLayout.minimumTileWidth, 200, contrat)
        XCTAssertEqual(TranscriptsLayout.maximumTileWidth, 340, contrat)
        XCTAssertEqual(TranscriptsLayout.tileSpacing, 16, contrat)
        XCTAssertEqual(TranscriptsLayout.contentPadding, 20, contrat)

        XCTAssertGreaterThan(TranscriptsLayout.tileSpacing, 0, contrat)
        XCTAssertGreaterThan(TranscriptsLayout.contentPadding, 0, contrat)
        XCTAssertGreaterThanOrEqual(
            TranscriptsLayout.maximumTileWidth, TranscriptsLayout.minimumTileWidth, contrat)
        XCTAssertLessThan(
            TranscriptsLayout.maximumTileWidth, HistoryLayout.transcriptMeasure, contrat)
    }
}
