import XCTest
@testable import MurmureCore

final class ModeSymbolTests: XCTestCase {
    /// Pinned against `ModesLayout.iconGridColumns`: the grid is meant to end on a full row, and
    /// a library whose count is not a multiple of the column count would leave a short last row.
    ///
    /// The grid (`ModesPaneView.iconPicker`) draws exactly one tile per library entry since the
    /// Modes editor v2 -- the stage-default glyph carries the "Default" caption instead of a
    /// separate tile -- so eleven entries fill two rows of six with one empty cell at the end.
    /// Pinned as "at most two rows": a twelfth glyph would still fit, a thirteenth starts a third.
    func testTheLibraryFitsInTwoGridRows() {
        XCTAssertLessThanOrEqual(ModeSymbol.library.count, 2 * ModesLayout.iconGridColumns)
        XCTAssertGreaterThan(ModeSymbol.library.count, ModesLayout.iconGridColumns)
        XCTAssertEqual(ModeSymbol.library.count, 11)
    }

    func testTheLibraryHasNoDuplicate() {
        XCTAssertEqual(Set(ModeSymbol.library).count, ModeSymbol.library.count)
    }

    /// The two glyphs `ModeStage.symbolName` already derives are real choices in the grid too --
    /// picking one explicitly is not a value the picker refuses to offer just because a mode with
    /// no `symbol` at all would end up drawing the same glyph anyway.
    func testTheTwoStageDefaultsAreInTheLibrary() {
        XCTAssertTrue(ModeSymbol.library.contains(ModeStage.transcription.symbolName))
        XCTAssertTrue(ModeSymbol.library.contains(ModeStage.refinement.symbolName))
    }

    func testNoEntryIsBlank() {
        XCTAssertFalse(ModeSymbol.library.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // MARK: - Stage defaults (task 4)

    func testTheStageDefaultsAreInTheLibraryAndRecognised() {
        XCTAssertTrue(ModeSymbol.isStageDefault("mic.fill", for: .transcription))
        XCTAssertTrue(ModeSymbol.isStageDefault("sparkles", for: .refinement))
        XCTAssertFalse(ModeSymbol.isStageDefault("sparkles", for: .transcription))
        XCTAssertTrue(ModeSymbol.library.contains("mic.fill") && ModeSymbol.library.contains("sparkles"))
    }
}
