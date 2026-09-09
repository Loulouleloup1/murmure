import XCTest
@testable import MurmureCore

final class HomeLayoutTests: XCTestCase {
    func testConstantsArePinned() {
        XCTAssertEqual(HomeLayout.panePadding, 16)
        XCTAssertEqual(HomeLayout.contentMaxWidth, 920)
        XCTAssertEqual(HomeLayout.cardCornerRadius, 12)
        XCTAssertEqual(HomeLayout.cardPadding, 16)
        XCTAssertEqual(HomeLayout.gridSpacing, 12)
        XCTAssertEqual(HomeLayout.figureFontSize, 30)
        XCTAssertEqual(HomeLayout.heatmapCellSize, 11)
        XCTAssertEqual(HomeLayout.heatmapCellGap, 3)
        XCTAssertEqual(HomeLayout.heatBrightness, [0.35, 0.55, 0.75, 1.0])
    }
}
