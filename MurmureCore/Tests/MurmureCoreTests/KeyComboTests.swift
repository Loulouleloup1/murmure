import XCTest
@testable import MurmureCore

final class KeyComboTests: XCTestCase {
    func testDefaultToggleIsOptionSpace() {
        XCTAssertEqual(KeyCombo.defaultToggle.keyCode, 49) // kVK_Space
        XCTAssertEqual(KeyCombo.defaultToggle.carbonModifiers, 2048) // optionKey
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(KeyCombo.defaultToggle)
        let back = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(back, KeyCombo.defaultToggle)
    }
}
