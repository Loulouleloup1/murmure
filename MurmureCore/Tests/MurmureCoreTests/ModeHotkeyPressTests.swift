import XCTest
@testable import MurmureCore

/// Every state, so the assertions that quantify over all of them quantify over a real domain and
/// a state added later has to be added here rather than being silently untested.
private let everyState: [DictationSession.State] = [
    .idle, .recording, .transcribing, .refining, .inserting,
    .completed(insertedCharacters: 42), .completed(insertedCharacters: 0),
    .copiedToClipboard(characters: 7),
    .cancelled,
    .failed(message: "insert failed", recoveredText: "bonjour"),
    .failed(message: "mic start failed", recoveredText: nil),
]

final class ModeHotkeyPressTests: XCTestCase {
    func testRecordingStops() {
        XCTAssertEqual(ModeHotkeyPress.action(for: .recording), .stop)
    }

    func testThePipelineRunningIsIgnoredExactlyLikeTheToggle() {
        XCTAssertEqual(ModeHotkeyPress.action(for: .transcribing), .ignore)
        XCTAssertEqual(ModeHotkeyPress.action(for: .refining), .ignore)
        XCTAssertEqual(ModeHotkeyPress.action(for: .inserting), .ignore)
    }

    func testEveryRestingStateStartsInTheMode() {
        let restingStates: [DictationSession.State] = [
            .idle,
            .completed(insertedCharacters: 42), .completed(insertedCharacters: 0),
            .copiedToClipboard(characters: 7),
            .cancelled,
            .failed(message: "insert failed", recoveredText: "bonjour"),
            .failed(message: "mic start failed", recoveredText: nil),
        ]

        for state in restingStates {
            XCTAssertEqual(ModeHotkeyPress.action(for: state), .startInMode, "\(state)")
        }
    }

    /// Quantifies over every state this package knows about -- the point is the same one
    /// `CancelHotkeyTests`'s own `everyState` array makes: a state added later without an entry
    /// here fails this test rather than silently defaulting somewhere.
    func testEveryStateProducesExactlyOneOfTheThreeActions() {
        for state in everyState {
            let action = ModeHotkeyPress.action(for: state)
            switch state {
            case .recording:
                XCTAssertEqual(action, .stop, "\(state)")
            case .transcribing, .refining, .inserting:
                XCTAssertEqual(action, .ignore, "\(state)")
            case .idle, .completed, .copiedToClipboard, .cancelled, .failed:
                XCTAssertEqual(action, .startInMode, "\(state)")
            }
        }
    }
}
