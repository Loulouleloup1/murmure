import XCTest
@testable import MurmureCore

private let base = URL(string: "http://localhost:11434")!

private func chatAnswer(_ content: String) -> Data {
    Data(#"{"message":{"role":"assistant","content":"\#(content)"},"done_reason":"stop"}"#.utf8)
}

private func generateAnswer(_ response: String) -> Data {
    Data(#"{"response":"\#(response)","done_reason":"stop"}"#.utf8)
}

final class OllamaCallTests: XCTestCase {
    func testAChatModeIsSentToTheChatApiWithTheInstructionsAsTheSystemTurn() throws {
        let call = OllamaCall(
            api: .chat, model: "gemma4:12b-it-qat", instructions: "Clean this up.",
            transcript: "euh bonjour", endpoint: base)

        XCTAssertEqual(call.url.absoluteString, "http://localhost:11434/api/chat")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0], ["role": "system", "content": "Clean this up."])
        XCTAssertNil(json["prompt"])
    }

    func testAnS1ModeIsSentToTheGenerateApiWithTheConversationWrittenOut() throws {
        let call = OllamaCall(
            api: .s1, model: "s1", instructions: "[Context: general]",
            transcript: "euh bonjour", endpoint: base)

        XCTAssertEqual(call.url.absoluteString, "http://localhost:11434/api/generate")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertEqual(
            json["prompt"] as? String,
            OllamaS1.conversation(control: "[Context: general]", transcript: "euh bonjour"))
        XCTAssertNil(json["messages"])
    }

    /// The reason this is one value and not three functions a caller picks from.
    ///
    /// The URL, the body and the reading of the answer are one decision. Split across three call
    /// sites, the way they go wrong is a mode sent to one dialect and read as the other -- and
    /// both directions of that produce a *plausible-looking* result rather than an error: an
    /// `s1` template posted to `/api/chat` comes back with empty content, and a chat body read as
    /// a generate one is "this is a bug". Here the pairing cannot be got wrong, and these two
    /// assertions are what says so.
    func testEachDialectReadsItsOwnAnswerAndRefusesTheOthers() {
        let chat = OllamaCall(
            api: .chat, model: "m", instructions: "Clean this up.",
            transcript: "euh bonjour tout le monde", endpoint: base)
        let s1 = OllamaCall(
            api: .s1, model: "m", instructions: "[Context: general]",
            transcript: "euh bonjour tout le monde", endpoint: base)

        XCTAssertEqual(
            chat.outcome(status: 200, body: chatAnswer("Bonjour tout le monde.")),
            .refined("Bonjour tout le monde."))
        XCTAssertEqual(
            s1.outcome(status: 200, body: generateAnswer("Bonjour tout le monde.")),
            .refined("Bonjour tout le monde."))

        guard case .failed(.malformedResponse) = chat.outcome(
            status: 200, body: generateAnswer("Bonjour tout le monde."))
        else { return XCTFail("a chat call must not read a generate body") }
        guard case .failed(.malformedResponse) = s1.outcome(
            status: 200, body: chatAnswer("Bonjour tout le monde."))
        else { return XCTFail("an s1 call must not read a chat body") }
    }

    /// The transcript and the model are captured when the call is built, so the two verdicts
    /// that compare the answer to the request survive without the caller carrying them around.
    func testTheCallRemembersWhatItSentSoTheVerdictsStillHaveSomethingToCompareTo() {
        let call = OllamaCall(
            api: .s1, model: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
            instructions: "[Context: general]",
            transcript: String(repeating: "il faudrait qu'on revoie le pipeline. ", count: 20),
            endpoint: base)

        guard case .failed(.refused) = call.outcome(status: 200, body: generateAnswer("Non."))
        else { return XCTFail("the collapse rule lost the transcript it compares against") }

        XCTAssertEqual(
            call.outcome(status: 404, body: Data(#"{"error":"model 'x' not found"}"#.utf8)),
            .failed(.modelNotPulled(model: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M")))
    }
}
