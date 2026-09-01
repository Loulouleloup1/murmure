import XCTest
@testable import MurmureCore

/// A body `/api/generate` sends back, with the fields the client reads. Shaped from a real
/// response captured against ollama 0.33.2, not from the documentation.
private func generateBody(response: String, doneReason: String = "stop") -> Data {
    Data("""
    {"model":"hf.co/superwhisper/s1-mini-GGUF:Q4_K_M","created_at":"2026-09-01T00:00:00Z",
     "response":\(quoted(response)),
     "done":true,"done_reason":"\(doneReason)",
     "total_duration":961376708,"load_duration":4232667,
     "prompt_eval_count":804,"eval_count":740}
    """.utf8)
}

private func quoted(_ text: String) -> String {
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
}

/// Verbatim from ollama 0.33.2, 2026-09-01: a 531-word dictation sent with `num_ctx` 512 and
/// `truncate: false`. Note the shape -- the `error` value is itself a JSON document, as a string.
private let exceedsContextBody = Data(#"""
{"error":"{\"error\":{\"code\":400,\"message\":\"request (804 tokens) exceeds the available context size (512 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":804,\"n_ctx\":512}}"}
"""#.utf8)

private let model = "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"

final class OllamaS1Tests: XCTestCase {
    // MARK: - The conversation

    /// The system turn is fixed by the model card, so it is a literal and not a prompt. Pinned
    /// character for character against the string the 784 benchmark generations ran under: it is
    /// the only thing that makes those numbers evidence about what Murmure ships.
    func testTheSystemTurnIsTheModelCardsAndNotAPromptWeWrote() {
        XCTAssertEqual(
            OllamaS1.systemPrompt,
            "You are a text normalizer for speech-to-text transcripts. The input begins with a "
                + "control line specifying the styling, structure, and context settings; clean "
                + "the transcript to match those settings and output only the cleaned text.")
    }

    /// The template, byte for byte. Written out in full rather than checked field by field
    /// because a hand-written conversation fails by *newline*: one missing `\n` before
    /// `<|im_start|>` and the model reads the control line as part of the previous turn, answers
    /// something plausible, and nothing downstream can tell.
    func testTheConversationIsTheTrainedFormatDownToEveryNewline() {
        let built = OllamaS1.conversation(
            control: "[Context: general]", transcript: "euh donc voilà")

        XCTAssertEqual(built, """
            <|im_start|>system
            \(OllamaS1.systemPrompt)<|im_end|>
            <|im_start|>user
            [Context: general]
            euh donc voilà<|im_end|>
            <|im_start|>assistant
            <think>

            </think>


            """)
    }

    /// The empty, already-closed `<think>` block is the reason this dialect exists rather than a
    /// detail of it: left to the model, the reasoning pass eats the whole token budget and
    /// `/api/chat` returns nothing but that. The template must end on it, with nothing after.
    func testTheAssistantTurnIsPrefilledWithAnEmptyClosedThinkBlock() {
        let built = OllamaS1.conversation(control: "[Context: general]", transcript: "bonjour")

        XCTAssertTrue(built.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"), built)
    }

    // MARK: - The request

    /// These five are floors, not preferences, and each one has a measured corruption behind it.
    /// The model's own modelfile defaults produce 2.52x the input's length on average -- a
    /// 44-word dictation answered with 1 402 words of repetition, HTTP 200 throughout.
    func testTheRequestPinsTheOptionsTheModelfileDefaultsCorrupt() throws {
        let body = OllamaS1.requestBody(
            model: model, instructions: "[Context: general]", transcript: "euh bonjour")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, model)
        // The whole point of the dialect: send the conversation through untouched.
        XCTAssertEqual(json["raw"] as? Bool, true)
        XCTAssertEqual(json["stream"] as? Bool, false)
        // Refuse an oversized dictation instead of silently dropping its beginning.
        XCTAssertEqual(json["truncate"] as? Bool, false)

        let options = try XCTUnwrap(json["options"] as? [String: Any])
        // 0.6 (the modelfile default) turned 44 dictated words into 1 402.
        XCTAssertEqual(options["temperature"] as? Double, 0)
        // 1.0 loops on 5 of 5 runs, 1.2 on 2 of 5. The window is this narrow.
        XCTAssertEqual(options["repeat_penalty"] as? Double, 1.1)
        XCTAssertEqual(options["seed"] as? Int, 20_260_901)
        XCTAssertEqual(options["num_predict"] as? Int, 2048)
        // 4096, not 8192: this is the number that holds the model at 1.08 GB resident.
        XCTAssertEqual(options["num_ctx"] as? Int, 4096)
        // Raw generation has no template to tell Ollama where a turn ends.
        XCTAssertEqual(options["stop"] as? [String], ["<|im_end|>", "<|im_start|>"])
    }

    func testTheControlLineAndTheTranscriptAreSentAsTheUserTurn() throws {
        let body = OllamaS1.requestBody(
            model: model, instructions: "[Context: email]", transcript: "euh donc voilà")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(
            json["prompt"] as? String,
            OllamaS1.conversation(control: "[Context: email]", transcript: "euh donc voilà"))
    }

    /// A dictation carries quotes, accents, newlines and the occasional emoji, and this dialect
    /// puts all of it inside a JSON string that also carries the template's own markup.
    func testATranscriptWithJsonHostileCharactersSurvivesEncoding() throws {
        let nasty = "il a dit \"euh\"\n\tpuis \\rien\\ — ça va 🙂 <tag> {\"k\":1}"
        let body = OllamaS1.requestBody(
            model: model, instructions: "[Context: general]", transcript: nasty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertTrue(try XCTUnwrap(json["prompt"] as? String).contains(nasty))
    }

    // MARK: - The endpoint

    func testTheEndpointIsTheGenerateApiAndNotTheChatOne() {
        XCTAssertEqual(
            OllamaS1.endpoint(base: URL(string: "http://localhost:11434")!).absoluteString,
            "http://localhost:11434/api/generate")
    }

    func testATrailingSlashOnTheBaseDoesNotDoubleTheSeparator() {
        XCTAssertEqual(
            OllamaS1.endpoint(base: URL(string: "http://localhost:11434/")!).absoluteString,
            "http://localhost:11434/api/generate")
    }

    // MARK: - The context window

    /// The failure this dialect's `truncate: false` was added to create.
    ///
    /// Without it the same call answers 200 with `done_reason: "stop"` and an answer that starts
    /// a third of the way into what Louis said -- measured, `prompt_eval_count` down from 804 to
    /// 258, nothing else different. The remedy has to be "dictate shorter", never "this is a bug".
    func testADictationTooLongForTheWindowIsNamedRatherThanReportedAsABug() {
        let outcome = OllamaS1.outcome(
            status: 400, body: exceedsContextBody, transcript: "euh bonjour", model: model)

        guard case .failed(.tooLongForTheContext(let window)) = outcome else {
            return XCTFail("expected .tooLongForTheContext, got \(outcome)")
        }
        XCTAssertEqual(window, OllamaS1.numContext)
        XCTAssertTrue(
            OllamaFailure.tooLongForTheContext(window: window).remedy.contains("\(window)"),
            "the remedy does not say how much fits")
    }

    /// The rule is `type: "exceed_context_size_error"`, a field, and never the sentence around
    /// it. Any other 400 is still a body this client could not use.
    func testAnotherKindOf400IsNotMistakenForAnOversizedDictation() {
        let outcome = OllamaS1.outcome(
            status: 400, body: Data(#"{"error":"invalid options: num_ctx"}"#.utf8),
            transcript: "euh bonjour", model: model)

        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected .malformedResponse, got \(outcome)")
        }
    }

    // MARK: - Reading the answer

    func testTheAnswerIsReadFromTheGenerateFieldRatherThanAChatMessage() {
        let outcome = OllamaS1.outcome(
            status: 200, body: generateBody(response: "Bonjour, il faudrait revoir le pipeline."),
            transcript: "euh bonjour, il faudrait euh revoir le pipeline", model: model)

        XCTAssertEqual(outcome, .refined("Bonjour, il faudrait revoir le pipeline."))
    }

    /// The two dialects are not interchangeable at the reading end either, and this is what
    /// stops a wrong ``Mode/LLM/api`` from turning into a plausible answer: a chat body has no
    /// `response` field, so it is refused rather than half-read.
    func testAChatAnswerReadAsAGenerateOneIsRefusedRatherThanHalfRead() {
        let chatBody = Data(#"""
        {"message":{"role":"assistant","content":"Bonjour."},"done":true,"done_reason":"stop"}
        """#.utf8)

        guard case .failed(.malformedResponse) = OllamaS1.outcome(
            status: 200, body: chatBody, transcript: "euh bonjour", model: model)
        else {
            return XCTFail("a chat body must not read as a generate one")
        }
    }

    /// The verdicts on the text itself are one judgement shared with ``OllamaChat``: what makes
    /// an answer unusable does not depend on the route it came back on. Exercised here so that
    /// unpicking the sharing shows up on this dialect too.
    func testTheSameVerdictsApplyToThisDialect() {
        let long = String(repeating: "alors donc euh il faudrait qu'on revoie le pipeline. ", count: 20)

        guard case .failed(.malformedResponse) = OllamaS1.outcome(
            status: 200, body: generateBody(response: "   \n  "), transcript: long, model: model)
        else { return XCTFail("an empty answer must be a failure") }

        guard case .failed(.truncated) = OllamaS1.outcome(
            status: 200, body: generateBody(response: String(repeating: "mot ", count: 300),
                                            doneReason: "length"),
            transcript: long, model: model)
        else { return XCTFail("a cut-off answer must be reported") }

        guard case .failed(.refused) = OllamaS1.outcome(
            status: 200, body: generateBody(response: "Je ne peux pas."),
            transcript: long, model: model)
        else { return XCTFail("a collapsed answer must be reported") }
    }

    /// The remedy is one `ollama pull`, and this dialect's model id is long enough that a
    /// generic message would send Louis reading logs.
    func testAMissingModelIsStillReportedByNameOnThisDialect() {
        let outcome = OllamaS1.outcome(
            status: 404, body: Data(#"{"error":"model 'x' not found"}"#.utf8),
            transcript: "euh bonjour", model: model)

        XCTAssertEqual(outcome, .failed(.modelNotPulled(model: model)))
    }
}
