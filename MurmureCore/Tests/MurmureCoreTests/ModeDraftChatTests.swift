import XCTest
@testable import MurmureCore

final class ModeDraftChatTests: XCTestCase {
    // MARK: - The request

    func testEndpointAppendsTheChatRoute() {
        XCTAssertEqual(
            ModeDraftChat.endpoint(base: URL(string: "http://localhost:11434")!).absoluteString,
            "http://localhost:11434/api/chat")
    }

    func testTheRequestStreamsAndPinsTheSameFloorsOllamaChatMeasured() throws {
        let turns: [ModeDraftingConversation.Turn] = [
            .init(role: .user, content: "A mode for Slack messages."),
        ]
        let body = ModeDraftChat.requestBody(
            model: "gemma4:12b-it-qat", systemPrompt: "You draft modes.", turns: turns)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gemma4:12b-it-qat")
        // The one deliberate difference from `OllamaChat`'s own request: this call streams.
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["think"] as? Bool, false)

        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["temperature"] as? Double, OllamaChat.temperature)
        XCTAssertEqual(options["seed"] as? Int, OllamaChat.seed)
        XCTAssertEqual(options["num_predict"] as? Int, OllamaChat.numPredict)
        XCTAssertEqual(options["num_ctx"] as? Int, OllamaChat.numContext)
    }

    func testMessagesAreTheSystemPromptThenEveryTurnInOrder() throws {
        let turns: [ModeDraftingConversation.Turn] = [
            .init(role: .user, content: "first"),
            .init(role: .assistant, content: "second"),
            .init(role: .user, content: "third"),
        ]
        let body = ModeDraftChat.requestBody(model: "gemma4:12b-it-qat", systemPrompt: "SYSTEM", turns: turns)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])

        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["SYSTEM", "first", "second", "third"])
    }

    // MARK: - Reading one streamed line

    private func line(_ json: String) -> Data { Data(json.utf8) }

    func testABlankLineIsNil() {
        XCTAssertNil(ModeDraftChat.outcome(line: Data(), model: "gemma4:12b-it-qat"))
        XCTAssertNil(ModeDraftChat.outcome(line: line("   \n"), model: "gemma4:12b-it-qat"))
    }

    func testAContentLineIsADelta() {
        let outcome = ModeDraftChat.outcome(
            line: line(#"{"message":{"role":"assistant","content":"Bonjour"},"done":false}"#),
            model: "gemma4:12b-it-qat")
        XCTAssertEqual(outcome, .delta("Bonjour"))
    }

    func testADoneLineWithNoReasonIsNotTruncated() {
        let outcome = ModeDraftChat.outcome(
            line: line(#"{"done":true,"done_reason":"stop"}"#), model: "gemma4:12b-it-qat")
        XCTAssertEqual(outcome, .done("", truncated: false))
    }

    func testADoneLineWithLengthReasonIsTruncated() {
        let outcome = ModeDraftChat.outcome(
            line: line(#"{"done":true,"done_reason":"length"}"#), model: "gemma4:12b-it-qat")
        XCTAssertEqual(outcome, .done("", truncated: true))
    }

    /// Lot 5 review, item 9: Ollama's own final line can carry BOTH `message.content` and
    /// `done: true` together -- reading only the `done` half and discarding the content would
    /// silently drop the reply's last fragment.
    func testADoneLineThatAlsoCarriesContentKeepsThatContent() {
        let outcome = ModeDraftChat.outcome(
            line: line(#"{"message":{"role":"assistant","content":"."},"done":true,"done_reason":"stop"}"#),
            model: "gemma4:12b-it-qat")
        XCTAssertEqual(outcome, .done(".", truncated: false))
    }

    func testUnreadableJSONIsMalformed() {
        let outcome = ModeDraftChat.outcome(line: line("not json at all"), model: "gemma4:12b-it-qat")
        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected malformedResponse, got \(String(describing: outcome))")
        }
    }

    func testALineWithNeitherMessageNorDoneIsADeltaOfEmptyText() {
        // A line naming neither is unusual but not itself a failure -- `message` is optional and
        // `done` defaults to not-done, so this reads as an empty fragment rather than an error.
        let outcome = ModeDraftChat.outcome(line: line(#"{"model":"gemma4:12b-it-qat"}"#), model: "gemma4:12b-it-qat")
        XCTAssertEqual(outcome, .delta(""))
    }

    // MARK: - Status and transport

    func testStatusFailureDelegatesToOllamaChat() {
        let body = Data(#"{"error":"model 'nope' not found"}"#.utf8)
        XCTAssertEqual(
            ModeDraftChat.statusFailure(status: 404, body: body, model: "nope"),
            OllamaChat.statusFailure(status: 404, body: body, model: "nope"))
    }
}
