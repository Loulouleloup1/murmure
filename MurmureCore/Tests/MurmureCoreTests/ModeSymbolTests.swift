import XCTest
@testable import MurmureCore

final class ModeSymbolTests: XCTestCase {
    /// Pinned against `ModesLayout.iconGridColumns`: the grid is meant to end on a full row, and
    /// a library whose count is not a multiple of the column count would leave a short last row.
    ///
    /// **`+ 1`, not the bare count** (review, lot 3a leftovers, item 2): the grid itself
    /// (`ModesPaneView.iconPicker`) draws one more tile than `library` has entries -- the "Default"
    /// tile that clears `symbol` back to nil -- so it is `library.count + 1` that has to land on a
    /// full row, not `library.count` alone. Eleven library entries plus that one tile is twelve,
    /// exactly two rows of six.
    func testTheLibraryFillsAWholeNumberOfGridRows() {
        XCTAssertEqual((ModeSymbol.library.count + 1) % ModesLayout.iconGridColumns, 0)
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
