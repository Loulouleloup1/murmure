import XCTest
@testable import MurmureCore

/// One bar per slot, and the wing is as wide as the number of bars. Everything below is therefore
/// a statement about the *shape of the notch*, not about a data structure: a history that grew, or
/// that came back short, would move the width of a surface lot 3 promises never moves.
final class LevelHistoryTests: XCTestCase {
    func testItOpensFullOfTheFloorSoTheWingIsNeverNarrowerThanItsBars() {
        // Not "empty until the microphone speaks": the wings draw one bar per slot, so a history
        // that filled up over the first half-second would widen the notch for the first six
        // frames of every dictation -- the one thing the recording state must not do.
        let history = LevelHistory()
        XCTAssertEqual(history.values.count, history.capacity)
        XCTAssertEqual(history.values, [Float](repeating: AudioLevelMeter.floorHeight, count: history.capacity))
    }

    func testItDropsTheOldestAndNeverGrows() {
        var history = LevelHistory(capacity: 3)
        for value in [Float](arrayLiteral: 0.1, 0.2, 0.3, 0.4, 0.5) {
            history.append(value)
            XCTAssertEqual(history.values.count, 3)
        }
        // 0.1 and 0.2 fell off the end; what is left is the last three, oldest first.
        XCTAssertEqual(history.values, [0.3, 0.4, 0.5])
    }

    func testItStaysOrderedOldestFirstAcrossManyWraps() {
        // The order is what the wing draws left to right, so a ring that read out rotated would
        // show a waveform scrolling from a different place on every wrap.
        var history = LevelHistory(capacity: 4)
        for step in 0..<21 {
            history.append(Float(step))
        }
        XCTAssertEqual(history.values, [17, 18, 19, 20])
    }
}
