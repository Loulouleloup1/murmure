import XCTest
@testable import MurmureCore

/// The window's measurements, pinned where they can be found rather than left in a `.frame(...)`
/// nothing can read. The digits are Louis's to move; the relations between them are not.
final class WindowLayoutTests: XCTestCase {
    /// A window that opened smaller than it can be resized to would be resized by AppKit on the
    /// first frame, and the size it opened at would be a number nobody ever sees.
    func testTheWindowNeverOpensSmallerThanItCanBeResizedTo() {
        XCTAssertGreaterThanOrEqual(
            WindowLayout.defaultSize.width, WindowLayout.minimumSize.width)
        XCTAssertGreaterThanOrEqual(
            WindowLayout.defaultSize.height, WindowLayout.minimumSize.height)
    }

    /// `NavigationSplitView` takes the three as a range and silently prefers whichever it can
    /// satisfy, so an ideal outside its own bounds is a value that never applies.
    func testTheSidebarWidthsAreARange() {
        XCTAssertLessThanOrEqual(WindowLayout.sidebarWidth.minimum, WindowLayout.sidebarWidth.ideal)
        XCTAssertLessThanOrEqual(WindowLayout.sidebarWidth.ideal, WindowLayout.sidebarWidth.maximum)
        // The sidebar cannot be allowed to eat the pane it is next to.
        XCTAssertLessThan(WindowLayout.sidebarWidth.maximum, WindowLayout.minimumSize.width / 2)
    }

    /// §2.3: a contextual toolbar, not a titlebar. Tall enough to hold a search field and a mode
    /// name — which is what the sections that have one will put there — and short enough that it
    /// does not read as a second title bar under the real one.
    func testTheHeaderIsARowAndNotASecondTitlebar() {
        XCTAssertGreaterThanOrEqual(WindowLayout.headerHeight, 38)
        XCTAssertLessThanOrEqual(WindowLayout.headerHeight, 56)
    }

    /// The tile has to fit inside the row it sits in, with room left for the row's own padding.
    func testTheSidebarTileFitsInTheRowItSitsIn() {
        XCTAssertLessThan(WindowLayout.sidebarTileSize, WindowLayout.headerHeight)
        // A radius past half the side stops being a rounded square and becomes a circle, which is
        // a different mark: §2.3's chip tier is a *chip*.
        XCTAssertLessThan(WindowLayout.chipCornerRadius, WindowLayout.sidebarTileSize / 2)
    }

    /// The whole Models table has to fit inside the smallest window the app can be resized to.
    /// A table whose action column falls off the right edge is a table with no delete button, and
    /// the window is resizable precisely so that this can happen.
    func testTheModelsTableFitsInsideTheSmallestWindow() {
        let columns = WindowLayout.modelsColumns
        let table = WindowLayout.modelsNameMinimum + columns.type + columns.size + columns.action

        XCTAssertLessThanOrEqual(
            WindowLayout.sidebarWidth.ideal + table, WindowLayout.minimumSize.width)
        // The name is the column being read; none of the other three may outgrow it.
        XCTAssertGreaterThan(WindowLayout.modelsNameMinimum, columns.size)
    }

    /// A header's own lines (heading, subtitle) must read tighter than the gap that separates
    /// Vocabulary's two groups, or the header would look like a third group rather than one
    /// paragraph describing the row beneath it.
    func testTheVocabularyHeaderSpacingIsTighterThanTheGapBetweenGroups() {
        XCTAssertGreaterThan(WindowLayout.vocabularyHeaderSpacing, 0)
        XCTAssertLessThan(WindowLayout.vocabularyHeaderSpacing, WindowLayout.vocabularyGroupSpacing)
    }

    /// The drafting sheet is wider and taller than the Inspect sheet -- a conversation needs more
    /// room than a candidate list -- and its own height is a real range.
    func testTheDraftSheetIsWiderAndTallerThanTheInspectSheet() {
        XCTAssertGreaterThan(WindowLayout.draftSheetWidth, WindowLayout.inspectSheetWidth)
        XCTAssertLessThan(WindowLayout.draftSheetHeight.minimum, WindowLayout.draftSheetHeight.maximum)
        XCTAssertGreaterThan(WindowLayout.draftSheetHeight.maximum, WindowLayout.inspectSheetHeight.maximum)
    }
}
