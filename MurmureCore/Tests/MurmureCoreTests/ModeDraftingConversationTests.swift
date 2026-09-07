import XCTest
@testable import MurmureCore

final class ModeDraftingConversationTests: XCTestCase {
    func testStartsWithNoTurnsAndNoTruncation() {
        let conversation = ModeDraftingConversation(model: "gemma4:12b-it-qat", systemPromptCharacterCount: 0)
        XCTAssertEqual(conversation.turns, [])
        XCTAssertEqual(conversation.truncatedTurnCount, 0)
    }

    func testAppendingUserThenAssistantKeepsBothInOrder() {
        var conversation = ModeDraftingConversation(model: "gemma4:12b-it-qat", systemPromptCharacterCount: 0)
        conversation.appendUser("A mode for dictating Slack messages.")
        conversation.appendAssistant("What language should it use?")

        XCTAssertEqual(conversation.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(conversation.turns.map(\.content), [
            "A mode for dictating Slack messages.", "What language should it use?",
        ])
    }

    /// The exact derivation `RefinementRequest.characterCap` uses, minus the halving that cap
    /// applies for a different reason (`ModeDraftingConversation.rawCharacterBudget`'s own doc
    /// comment) -- pinned so nobody "simplifies" this into a fresh, unmeasured number.
    func testTheRawBudgetIsDerivedFromOllamaChatsOwnFloorsNotInvented() {
        XCTAssertEqual(
            ModeDraftingConversation.rawCharacterBudget,
            (OllamaChat.numContext - OllamaChat.numPredict) * 4)
    }

    /// Lot 5 review, item 2: the system prompt is not free -- it occupies the same request as the
    /// history, and the history's own budget has to leave room for it.
    func testCharacterBudgetSubtractsTheSystemPromptsOwnCharacterCount() {
        let conversation = ModeDraftingConversation(
            model: "gemma4:12b-it-qat", systemPromptCharacterCount: 1_000)
        XCTAssertEqual(
            conversation.characterBudget, ModeDraftingConversation.rawCharacterBudget - 1_000)
    }

    /// The concrete failure item 2 named: a REAL system prompt (every installed speech model and
    /// every installed chat model listed by name, the shape that measured 7 565 characters on one
    /// real machine) plus a conversation filled to exactly its own budget must still land under
    /// `rawCharacterBudget` -- the ceiling Ollama's `num_ctx` actually enforces for the request as
    /// a whole, system prompt included.
    func testASystemPromptPlusAFullBudgetOfHistoryFitsUnderTheRawCeiling() {
        let systemPrompt = ModeDraftSystemPrompt.build(
            installedSpeechModels: [
                "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo",
                "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930",
            ],
            installedOllamaModels: [
                "gemma4:12b-it-qat", "gemma4:e2b-it-qat", "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
                "nomic-embed-text:latest", "mxbai-embed-large:latest",
            ])
        var conversation = ModeDraftingConversation(
            model: "gemma4:12b-it-qat", systemPromptCharacterCount: systemPrompt.count)
        conversation.appendUser(String(repeating: "a", count: conversation.characterBudget))

        XCTAssertEqual(conversation.truncatedTurnCount, 0)
        let historyCharacters = conversation.turns.reduce(0) { $0 + $1.content.count }
        XCTAssertLessThanOrEqual(
            systemPrompt.count + historyCharacters, ModeDraftingConversation.rawCharacterBudget)
    }

    func testOverBudgetTurnsAreDroppedFromTheOldestFirst() {
        var conversation = ModeDraftingConversation(model: "gemma4:12b-it-qat", systemPromptCharacterCount: 0)
        // Three turns, each holding just over a third of the budget -- together they overshoot it,
        // so the oldest has to go.
        let third = String(repeating: "a", count: conversation.characterBudget / 3 + 10)
        conversation.appendUser(third)
        conversation.appendAssistant(third)
        conversation.appendUser(third)

        XCTAssertEqual(conversation.turns.count, 2)
        XCTAssertEqual(conversation.truncatedTurnCount, 1)
        // The turn that was kept is the two most recent ones, not the first.
        XCTAssertEqual(conversation.turns.map(\.role), [.assistant, .user])
    }

    /// The one turn that matters most -- what was just typed -- is never dropped, even alone over
    /// budget: the caller still has one full turn to send, rather than an empty conversation.
    func testASingleTurnAloneOverBudgetIsNeverDropped() {
        var conversation = ModeDraftingConversation(model: "gemma4:12b-it-qat", systemPromptCharacterCount: 0)
        let tooLong = String(repeating: "a", count: conversation.characterBudget * 2)
        conversation.appendUser(tooLong)

        XCTAssertEqual(conversation.turns.count, 1)
        XCTAssertEqual(conversation.truncatedTurnCount, 0)
    }

    func testModelIsMutableAcrossTheConversation() {
        var conversation = ModeDraftingConversation(model: "gemma4:e2b-it-qat", systemPromptCharacterCount: 0)
        conversation.model = "gemma4:12b-it-qat"
        XCTAssertEqual(conversation.model, "gemma4:12b-it-qat")
    }
}
