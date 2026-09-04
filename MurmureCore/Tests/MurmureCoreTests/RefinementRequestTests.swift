import XCTest
@testable import MurmureCore

/// A `.chat` mode with every context toggle on, so a test that wants a subset switches the ones
/// it does not need back off rather than building the toggles from scratch each time.
private func chatMode(
    instructions: String = "Clean up the transcript.",
    selectedText: Bool = true, clipboard: Bool = true, appContext: Bool = true
) -> Mode {
    var mode = Mode.voice
    mode.llm = .init(
        enabled: true, endpoint: "http://localhost:11434", model: "gemma4:12b-it-qat", api: .chat)
    mode.instructions = instructions
    mode.context = .init(selectedText: selectedText, clipboard: clipboard, appContext: appContext)
    return mode
}

final class RefinementRequestTests: XCTestCase {
    // MARK: - Wiring: each toggle independently controls what reaches the system turn

    /// The test that would have caught `Mode.Context` being three toggles read by nobody: with
    /// every toggle OFF and a value captured anyway (standing in for whatever upstream bug once
    /// left it there), the system turn must still be exactly the written instructions. Flip the
    /// guard in `RefinementRequest.contextSections` to ignore a toggle and this goes red.
    func testAllTogglesOffProducesInstructionsUnchangedEvenWithContextCaptured() {
        let mode = chatMode(selectedText: false, clipboard: false, appContext: false)
        let captured = CapturedContext(
            selectedText: "texte sélectionné", clipboard: "presse-papiers",
            frontmostAppName: "Xcode")

        XCTAssertEqual(
            RefinementRequest(mode: mode, captured: captured).systemTurn, mode.instructions)
    }

    func testSelectedTextToggleControlsInclusion() {
        let captured = CapturedContext(selectedText: "Bonjour, peux-tu regarder ce paragraphe ?")

        let on = chatMode(selectedText: true, clipboard: false, appContext: false)
        XCTAssertTrue(
            RefinementRequest(mode: on, captured: captured).systemTurn
                .contains("Bonjour, peux-tu regarder ce paragraphe ?"))

        let off = chatMode(selectedText: false, clipboard: false, appContext: false)
        XCTAssertEqual(
            RefinementRequest(mode: off, captured: captured).systemTurn, off.instructions)
    }

    func testClipboardToggleControlsInclusion() {
        let captured = CapturedContext(clipboard: "https://example.com/report.pdf")

        let on = chatMode(selectedText: false, clipboard: true, appContext: false)
        XCTAssertTrue(
            RefinementRequest(mode: on, captured: captured).systemTurn
                .contains("https://example.com/report.pdf"))

        let off = chatMode(selectedText: false, clipboard: false, appContext: false)
        XCTAssertEqual(
            RefinementRequest(mode: off, captured: captured).systemTurn, off.instructions)
    }

    func testFrontmostAppToggleControlsInclusion() {
        let captured = CapturedContext(frontmostAppName: "Slack")

        let on = chatMode(selectedText: false, clipboard: false, appContext: true)
        XCTAssertTrue(RefinementRequest(mode: on, captured: captured).systemTurn.contains("Slack"))

        let off = chatMode(selectedText: false, clipboard: false, appContext: false)
        XCTAssertEqual(
            RefinementRequest(mode: off, captured: captured).systemTurn, off.instructions)
    }

    // MARK: - Empty is not the same as switched off, but it is the same as absent

    /// A toggle on with an empty clipboard (not nil -- a real read that found nothing, e.g. an
    /// image on the pasteboard) must not send a section saying "the clipboard is empty": that is
    /// a sentence about Murmure's internals, and it is exactly as unhelpful to the model as an
    /// empty labelled section would be to a human reading it.
    func testAnEmptyCapturedValueProducesNoSectionAtAll() {
        let mode = chatMode(selectedText: false, clipboard: true, appContext: false)
        let captured = CapturedContext(clipboard: "   ")

        let systemTurn = RefinementRequest(mode: mode, captured: captured).systemTurn

        XCTAssertEqual(systemTurn, mode.instructions)
        XCTAssertFalse(systemTurn.lowercased().contains("clipboard"))
    }

    func testANilCapturedValueProducesNoSectionAtAll() {
        let mode = chatMode(selectedText: true, clipboard: false, appContext: false)
        let captured = CapturedContext(selectedText: nil)

        XCTAssertEqual(
            RefinementRequest(mode: mode, captured: captured).systemTurn, mode.instructions)
    }

    // MARK: - s1: context has nowhere to go

    /// Whatever the toggles say and whatever was captured, an `s1` mode's system turn is its
    /// instructions verbatim -- the control line the model copies rather than reads
    /// (`Mode/LLM/API/s1`). Context appended there would be copied into Louis's text exactly like
    /// the prose `Mode.validationError` already refuses.
    func testS1ModeNeverCarriesContextWhateverTheTogglesSay() {
        var mode = chatMode()
        mode.llm.api = .s1
        mode.instructions = "[Context: general]"
        let captured = CapturedContext(
            selectedText: "sélection", clipboard: "presse-papiers", frontmostAppName: "Terminal")

        XCTAssertEqual(
            RefinementRequest(mode: mode, captured: captured).systemTurn, "[Context: general]")
    }

    // MARK: - Ordering and labelling: context cannot be mistaken for the transcript

    /// The failure mode with real consequences: selected text that reads exactly like something
    /// Louis might have said, sitting in the same system turn as the instructions. The system
    /// turn has to say, in words, that this is background and not the dictation -- the transcript
    /// itself never appears in this type at all, it travels as its own message
    /// (`OllamaChat.requestBody`), so the only thing that can blur the line is the system turn
    /// failing to say what the selected text IS.
    func testSelectedTextThatReadsLikeADictationIsLabelledAsContextNotTranscript() {
        let dictationLike = "Bonjour, peux-tu reformater ce paragraphe en trois points distincts ?"
        let mode = chatMode(selectedText: true, clipboard: false, appContext: false)
        let captured = CapturedContext(selectedText: dictationLike)

        let systemTurn = RefinementRequest(mode: mode, captured: captured).systemTurn

        // The captured text is there --
        XCTAssertTrue(systemTurn.contains(dictationLike))
        // -- but never unlabelled: it is introduced by "Selected text:" and preceded by a
        // sentence saying plainly that none of what follows is something the user said.
        XCTAssertTrue(systemTurn.contains("Selected text:\n\(dictationLike)"))
        XCTAssertTrue(systemTurn.contains("is NOT something the user said"))
        XCTAssertTrue(systemTurn.contains("Only the transcript in the next message is"))
        // The instructions -- the job -- come first, the context after: a reader (or a model)
        // scanning top to bottom meets the task before the background for it.
        let instructionsRange = systemTurn.range(of: mode.instructions)!
        let contextRange = systemTurn.range(of: "Selected text:")!
        XCTAssertTrue(instructionsRange.lowerBound < contextRange.lowerBound)
    }

    // MARK: - The cap

    /// Pinned to the derivation in the doc comment, so a change to either constant it is built
    /// from has to be a deliberate edit of this number too, not a silent drift.
    func testCharacterCapIsHalfTheNonCompletionBudgetAtFourCharsPerToken() {
        let expected = (OllamaChat.numContext - OllamaChat.numPredict) / 2 * 4
        XCTAssertEqual(RefinementRequest.characterCap, expected)
        XCTAssertEqual(RefinementRequest.characterCap, 12_288)
    }

    /// Kept whole, right up to the cap.
    func testTextAtExactlyTheCapIsNotTruncated() {
        let text = String(repeating: "a", count: RefinementRequest.characterCap)
        let mode = chatMode(selectedText: true, clipboard: false, appContext: false)
        let captured = CapturedContext(selectedText: text)

        let systemTurn = RefinementRequest(mode: mode, captured: captured).systemTurn

        XCTAssertTrue(systemTurn.contains("Selected text:\n\(text)"))
        XCTAssertFalse(systemTurn.contains("truncated"))
    }

    /// Over the cap: kept from the BEGINNING (`.prefix`, matching every other truncation already
    /// in this package), dropped from the end, and marked -- never silently, unlike the truncation
    /// `OllamaS1.truncate` exists to refuse at the model's own end.
    func testTextOverTheCapIsTruncatedFromTheEndAndMarked() {
        let text = String(repeating: "b", count: RefinementRequest.characterCap + 500)
        let mode = chatMode(selectedText: false, clipboard: true, appContext: false)
        let captured = CapturedContext(clipboard: text)

        let systemTurn = RefinementRequest(mode: mode, captured: captured).systemTurn

        let kept = String(text.prefix(RefinementRequest.characterCap))
        XCTAssertTrue(systemTurn.contains(kept))
        XCTAssertTrue(systemTurn.contains("truncated"))
        XCTAssertTrue(systemTurn.contains("\(text.count) characters captured"))
        // Not the full text: the drop actually happened, this is not just an appended note.
        XCTAssertFalse(systemTurn.contains(text))
    }

    // MARK: - effectiveMode

    /// Only `instructions` changes; every other field -- including the toggles that produced the
    /// difference -- survives untouched, because this is a value built for one call and never
    /// written back to `ModeStore`.
    func testEffectiveModeChangesOnlyInstructions() {
        let mode = chatMode(selectedText: true, clipboard: false, appContext: false)
        let captured = CapturedContext(selectedText: "quelque chose")

        let effective = RefinementRequest(mode: mode, captured: captured).effectiveMode

        XCTAssertNotEqual(effective.instructions, mode.instructions)
        var expectedUnchanged = mode
        expectedUnchanged.instructions = effective.instructions
        XCTAssertEqual(effective, expectedUnchanged)
        XCTAssertEqual(effective.key, mode.key)
        XCTAssertEqual(effective.context, mode.context)
        XCTAssertEqual(effective.llm, mode.llm)
    }
}
