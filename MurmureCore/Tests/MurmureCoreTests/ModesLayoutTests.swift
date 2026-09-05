import XCTest
@testable import MurmureCore

/// The Modes pane's measurements, pinned the same way `WindowLayoutTests` pins its own file: the
/// digits are Louis's to move, the relations between them are not.
final class ModesLayoutTests: XCTestCase {
    func testTheIconGridHasAtLeastOneColumnAndSomeGap() {
        XCTAssertGreaterThan(ModesLayout.iconGridColumns, 0)
        XCTAssertGreaterThan(ModesLayout.iconGridSpacing, 0)
    }

    func testThePreviewHeightIsARange() {
        XCTAssertLessThan(ModesLayout.previewHeight.minimum, ModesLayout.previewHeight.maximum)
    }
}
