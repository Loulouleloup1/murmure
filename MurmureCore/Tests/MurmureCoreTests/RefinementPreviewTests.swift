import XCTest
@testable import MurmureCore

final class RefinementPreviewTests: XCTestCase {
    // MARK: - No refiner

    func testNoRefinerModeShowsTheFixedSentenceAndNothingElse() {
        let preview = RefinementPreview.render(mode: .voice)

        XCTAssertEqual(preview.turns.count, 1)
        XCTAssertEqual(preview.turns[0].body, "No refiner: the transcript is inserted as recognised.")
    }

    // MARK: - Chat, no context

    func testChatModeWithNoContextShowsInstructionsVerbatimAndTheUserTurn() {
        var mode = Mode.voice
        mode.llm = .init(
            enabled: true, endpoint: "http://localhost:11434", model: "gemma4:12b-it-qat", api: .chat)
        mode.instructions = "Clean up the transcript."

        let preview = RefinementPreview.render(mode: mode)

        XCTAssertEqual(preview.turns.count, 2)
        XCTAssertEqual(preview.turns[0].heading, "System turn")
        XCTAssertEqual(preview.turns[0].body, "Clean up the transcript.")
        XCTAssertEqual(preview.turns[1].heading, "User turn")
        XCTAssertEqual(preview.turns[1].body, RefinementPreview.transcriptPlaceholder)
        XCTAssertEqual(RefinementPreview.transcriptPlaceholder, "<your transcript>")
    }

    // MARK: - Chat, every toggle on

    /// The exact text a reader would check against a real request: instructions, the preamble,
    /// then one placeholder per enabled toggle, in the declared order.
    func testChatModeWithEveryToggleOnShowsThreePlaceholdersInOrder() {
        var mode = Mode.voice
        mode.llm = .init(
            enabled: true, endpoint: "http://localhost:11434", model: "gemma4:12b-it-qat", api: .chat)
        mode.instructions = "Clean up the transcript."
        mode.context = .init(selectedText: true, clipboard: true, appContext: true)

        let systemTurn = RefinementPreview.render(mode: mode).turns[0].body

        let expected = SystemTurnAssembly.assemble(
            instructions: "Clean up the transcript.",
            sections: [
                "[Selected text — captured when you start recording]",
                "[Clipboard — captured when you start recording]",
                "[Frontmost application — captured when you start recording]",
            ])
        XCTAssertEqual(systemTurn, expected)
        XCTAssertTrue(systemTurn.contains(SystemTurnAssembly.contextPreamble))

        let instructionsRange = systemTurn.range(of: "Clean up the transcript.")!
        let selectedRange = systemTurn.range(of: "[Selected text")!
        let clipboardRange = systemTurn.range(of: "[Clipboard")!
        let appRange = systemTurn.range(of: "[Frontmost application")!
        XCTAssertTrue(instructionsRange.lowerBound < selectedRange.lowerBound)
        XCTAssertTrue(selectedRange.lowerBound < clipboardRange.lowerBound)
        XCTAssertTrue(clipboardRange.lowerBound < appRange.lowerBound)
    }

    /// One toggle on is one placeholder, not three -- the same "enabled only" rule
    /// `RefinementRequestTests` pins for the real request.
    func testChatModeWithOneToggleOnShowsOnlyThatPlaceholder() {
        var mode = Mode.voice
        mode.llm = .init(
            enabled: true, endpoint: "http://localhost:11434", model: "gemma4:12b-it-qat", api: .chat)
        mode.instructions = "Clean up the transcript."
        mode.context = .init(selectedText: false, clipboard: true, appContext: false)

        let systemTurn = RefinementPreview.render(mode: mode).turns[0].body

        XCTAssertTrue(systemTurn.contains("[Clipboard — captured when you start recording]"))
        XCTAssertFalse(systemTurn.contains("Selected text"))
        XCTAssertFalse(systemTurn.contains("Frontmost application"))
    }

    // MARK: - s1

    func testS1ModeShowsTheFixedSystemPromptTheControlLineAndTheTranscript() {
        let preview = RefinementPreview.render(mode: .prompt)

        XCTAssertEqual(preview.turns.count, 3)
        XCTAssertEqual(preview.turns[0].heading, "System prompt")
        XCTAssertEqual(preview.turns[0].body, OllamaS1.systemPrompt)
        XCTAssertEqual(preview.turns[0].note, "Fixed by the s1-mini model card — Murmure cannot change it.")
        XCTAssertEqual(preview.turns[1].heading, "Control line")
        XCTAssertEqual(preview.turns[1].body, "[Context: general]")
        XCTAssertNil(preview.turns[1].note)
        XCTAssertEqual(preview.turns[2].heading, "Transcript")
        XCTAssertEqual(preview.turns[2].body, RefinementPreview.transcriptPlaceholder)
    }

    /// s1 never carries context (`RefinementRequestTests.testS1ModeNeverCarriesContextWhateverTheTogglesSay`):
    /// the preview must show the same absence, whatever the toggles say -- they are disabled in
    /// the editor, but a stale file could still have them on.
    func testS1ModeShowsNoContextPlaceholderEvenWithTogglesOn() {
        var mode = Mode.prompt
        mode.context = .init(selectedText: true, clipboard: true, appContext: true)

        let preview = RefinementPreview.render(mode: mode)

        for turn in preview.turns {
            XCTAssertFalse(turn.body.contains("captured when you start recording"), turn.heading)
        }
    }

    // MARK: - Sharing the assembler with RefinementRequest

    /// Not a mutation test by itself (that is done by hand, see the task's verification step), but
    /// the fixed point it protects: both types read the SAME preamble constant, so a change to one
    /// changes both without either duplicating the string.
    func testPreviewAndRequestPreambleAreTheSameConstant() {
        var mode = Mode.voice
        mode.llm = .init(
            enabled: true, endpoint: "http://localhost:11434", model: "gemma4:12b-it-qat", api: .chat)
        mode.context = .init(selectedText: true, clipboard: false, appContext: false)
        let captured = CapturedContext(selectedText: "quelque chose")

        let requestTurn = RefinementRequest(mode: mode, captured: captured).systemTurn
        let previewTurn = RefinementPreview.render(mode: mode).turns[0].body

        XCTAssertTrue(requestTurn.contains(SystemTurnAssembly.contextPreamble))
        XCTAssertTrue(previewTurn.contains(SystemTurnAssembly.contextPreamble))
    }
}
