import XCTest
@testable import MurmureCore

final class StatusPanelTextTests: XCTestCase {
    /// Every phase that has a panel has something to say in it. `hidden` is the exception because
    /// there is no panel; anything else showing a blank strip would be Murmure on screen saying
    /// nothing, which is the state this whole task exists to remove.
    func testEveryVisiblePhaseSaysSomething() {
        XCTAssertEqual(StatusPanelText.label(for: .hidden), "")
        let visible: [NotchPhase] = [
            .recording,
            .preparingModel(.downloading(ModelDownload(expectedBytes: 1_638_467_188))),
            .preparingModel(.loading),
            .transcribing, .refining, .inserting,
            .completed(insertedCharacters: 42), .nothingHeard,
            .failed(message: "clipboard lost", recoveredText: nil),
            .alert(message: "Accessibility is off"),
        ]
        for phase in visible {
            XCTAssertFalse(
                StatusPanelText.label(for: phase).isEmpty, "\(phase) shows an empty panel")
        }
    }

    /// The two phases the panel exists to tell apart. A dictation that pasted nothing takes as
    /// long, makes the same noises and ends the same way as one that worked; on an external
    /// display the sentence is the only difference Louis gets.
    func testNothingHeardCannotBeReadAsASuccess() {
        let heard = StatusPanelText.label(for: .completed(insertedCharacters: 42))
        let silent = StatusPanelText.label(for: .nothingHeard)
        XCTAssertNotEqual(heard, silent)
        XCTAssertFalse(
            silent.localizedCaseInsensitiveContains("inserted"),
            "a silence must not borrow the completion's verb")
        XCTAssertTrue(silent.localizedCaseInsensitiveContains("nothing"))
    }

    /// The count, not just the fact. It is what says whether the sentence under the cursor is the
    /// one that was spoken or three characters of it.
    func testACompletionCarriesItsCount() {
        XCTAssertTrue(
            StatusPanelText.label(for: .completed(insertedCharacters: 137)).contains("137"))
        XCTAssertEqual(
            StatusPanelText.label(for: .completed(insertedCharacters: 1)), "Inserted 1 character")
        XCTAssertEqual(
            StatusPanelText.label(for: .completed(insertedCharacters: 2)), "Inserted 2 characters")
    }

    /// The long wait and the short one are different words. On the panel there are no wings and no
    /// waveform, so the word carries the distinction on its own.
    func testTheTwoWaitsAreDifferentWords() {
        XCTAssertNotEqual(
            StatusPanelText.label(for: .transcribing), StatusPanelText.label(for: .refining))
    }

    /// A failure says what failed. The panel is the surface Louis actually sees; sending him to a
    /// menu to find out is what lot 3 exists to stop.
    func testAFailureShowsItsOwnMessage() {
        let label = StatusPanelText.label(
            for: .failed(message: "Accessibility permission was revoked", recoveredText: "bonjour"))
        XCTAssertEqual(label, "Accessibility permission was revoked")
        XCTAssertFalse(label.contains("bonjour"), "the recovered text needs a control, not a strip")
    }

    /// Nothing upstream promises a one-line message: `failed` carries an `Error`'s description.
    /// A newline in a 34 pt strip pushes the rest of the sentence out of the panel, so the half
    /// after the break would be gone with no sign it existed.
    func testAMultiLineMessageIsFlattenedToOneLine() {
        let label = StatusPanelText.label(
            for: .alert(message: "Ollama refused:\n  connection reset\n"))
        XCTAssertEqual(label, "Ollama refused: connection reset")
    }
}
