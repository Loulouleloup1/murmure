import XCTest
@testable import MurmureCore

/// A body Ollama would send back on a successful `/api/chat` call, with the fields the client
/// actually reads. Shaped from a real response, not from the documentation.
private func successBody(content: String, doneReason: String = "stop") -> Data {
    Data("""
    {"model":"gemma4:12b-it-qat","created_at":"2026-09-01T00:00:00Z",
     "message":{"role":"assistant","content":\(quoted(content))},
     "done":true,"done_reason":"\(doneReason)",
     "total_duration":19000000000,"load_duration":900000000,
     "prompt_eval_count":420,"eval_count":380}
    """.utf8)
}

private func quoted(_ text: String) -> String {
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
}

final class OllamaChatTests: XCTestCase {
    // MARK: - The request

    /// The four options are floors, not preferences (lot 2 plan). Two of them were measured to
    /// corrupt a real dictation at Ollama's defaults, so this test is the regression that keeps
    /// them from being "tidied away" later.
    func testTheRequestPinsTheOptionsTheCorpusProvedNecessary() throws {
        let body = OllamaChat.requestBody(
            model: "gemma4:12b-it-qat", instructions: "Clean this up.", transcript: "euh bonjour"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gemma4:12b-it-qat")
        // Reasoning off: with it on, these models spend the whole budget on a reasoning field
        // and return empty content (spec §10).
        XCTAssertEqual(json["think"] as? Bool, false)
        // The answer is pasted whole; there is nothing to stream it into.
        XCTAssertEqual(json["stream"] as? Bool, false)

        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["temperature"] as? Double, 0)
        XCTAssertEqual(options["seed"] as? Int, 20_260_901)
        // 512 (the default) cut a 370-word dictation mid-sentence.
        XCTAssertEqual(options["num_predict"] as? Int, 2048)
        // 2048 (the default) drops everything past ~600 words with no error at all.
        XCTAssertEqual(options["num_ctx"] as? Int, 8192)
    }

    func testTheInstructionsAreTheSystemTurnAndTheTranscriptIsTheUserTurn() throws {
        let body = OllamaChat.requestBody(
            model: "m", instructions: "You are a cleaner.", transcript: "euh donc voilà")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], ["role": "system", "content": "You are a cleaner."])
        XCTAssertEqual(messages[1], ["role": "user", "content": "euh donc voilà"])
    }

    /// A dictation carries quotes, accents, newlines and the occasional emoji. The encoder is
    /// what stands between those and a request Ollama rejects.
    func testATranscriptWithJsonHostileCharactersSurvivesEncoding() throws {
        let nasty = "il a dit \"euh\"\n\tpuis \\rien\\ — ça va 🙂 <tag> {\"k\":1}"
        let body = OllamaChat.requestBody(model: "m", instructions: "i", transcript: nasty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])

        XCTAssertEqual(messages[1]["content"], nasty)
    }

    // MARK: - The endpoint

    func testTheEndpointIsTheNativeChatApi() {
        XCTAssertEqual(
            OllamaChat.endpoint(base: URL(string: "http://localhost:11434")!).absoluteString,
            "http://localhost:11434/api/chat")
    }

    /// Spec §5's example mode still carries `"endpoint": "http://localhost:11434/v1"`, written
    /// before §10 ruled that refinement goes through the native API. A mode copied from it must
    /// not produce `/v1/api/chat`, which Ollama answers with a plain-text 404.
    func testAnOpenAiCompatibleBaseUrlIsNormalisedToTheNativeApi() {
        for base in ["http://localhost:11434/v1", "http://localhost:11434/v1/", "http://localhost:11434/"] {
            XCTAssertEqual(
                OllamaChat.endpoint(base: URL(string: base)!).absoluteString,
                "http://localhost:11434/api/chat", "base: \(base)")
        }
    }

    // MARK: - Transport failures

    /// Ollama not launched. The remedy is `ollama serve`, and nothing else in this file's list
    /// has that remedy.
    func testAConnectionRefusedIsReportedAsOllamaNotRunning() {
        let failure = OllamaChat.failure(transport: URLError(.cannotConnectToHost), elapsed: 0.01)
        guard case .notRunning = failure else {
            return XCTFail("expected .notRunning, got \(failure)")
        }
    }

    /// The message says how long the call actually took, not what the deadline was set to. A
    /// first version reported the configured 120 s about a call that had died in 7.8 s, measured
    /// against a server that accepts a connection and then drops it — which `URLSession` also
    /// surfaces as `.timedOut`.
    func testATimeoutReportsTheTimeActuallySpentAndNotTheConfiguredDeadline() {
        let failure = OllamaChat.failure(transport: URLError(.timedOut), elapsed: 7.8)
        guard case .timedOut(let after) = failure else {
            return XCTFail("expected .timedOut, got \(failure)")
        }
        XCTAssertEqual(after, 7.8)
        XCTAssertNotEqual(after, OllamaChat.timeout)
    }

    // MARK: - HTTP-level failures

    /// The remedy here is a single `ollama pull`, so the message has to name the model. A generic
    /// "refinement failed" would send Louis reading logs.
    ///
    /// Both wordings are exercised because the first version of this test only had the second
    /// one, taken from the documentation, and the code that passed it failed against the real
    /// server: Ollama 0.33.2 answers `model 'x' not found` -- SINGLE quotes, no trailing clause
    /// -- and the double-quote parse behind it returned nil, downgrading the one failure with a
    /// one-command remedy to "this is a bug". The name now comes from the request instead of
    /// from the message, which is what makes both of these pass.
    func testAMissingModelIsReportedByNameRatherThanAsAGenericHttpError() {
        let bodies = [
            // Verbatim from ollama 0.33.2, 2026-09-01.
            Data(#"{"error":"model 'gemma4:12b-it-qat' not found"}"#.utf8),
            Data(#"{"error":"model \"gemma4:12b-it-qat\" not found, try pulling it first"}"#.utf8),
        ]
        for body in bodies {
            let outcome = OllamaChat.outcome(
                status: 404, body: body, transcript: "euh bonjour", model: "gemma4:12b-it-qat")
            guard case .failed(.modelNotPulled(let model)) = outcome else {
                return XCTFail("expected .modelNotPulled, got \(outcome)")
            }
            XCTAssertEqual(model, "gemma4:12b-it-qat")
        }
    }

    /// A 404 from a wrong path is Ollama saying "no such route", not "no such model" — telling
    /// Louis to pull a model he already has would be worse than saying nothing.
    func testA404FromTheWrongPathIsNotMistakenForAMissingModel() {
        let outcome = OllamaChat.outcome(
            status: 404, body: Data("404 page not found".utf8),
            transcript: "euh bonjour", model: "gemma4:12b-it-qat")
        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected .malformedResponse, got \(outcome)")
        }
    }

    func testAServerErrorIsMalformedAndKeepsTheBodyForTheLog() {
        let outcome = OllamaChat.outcome(
            status: 500, body: Data(#"{"error":"llama runner exited"}"#.utf8),
            transcript: "euh bonjour", model: "gemma4:12b-it-qat")
        guard case .failed(.malformedResponse(let detail)) = outcome else {
            return XCTFail("expected .malformedResponse, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("500"), detail)
        XCTAssertTrue(detail.contains("llama runner exited"), detail)
    }

    // MARK: - Body-level failures

    func testABodyThatIsNotJsonIsMalformed() {
        let outcome = OllamaChat.outcome(
            status: 200, body: Data("<html>proxy</html>".utf8), transcript: "euh bonjour", model: "gemma4:12b-it-qat")
        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected .malformedResponse, got \(outcome)")
        }
    }

    func testAJsonBodyWithoutTheMessageContentIsMalformed() {
        let outcome = OllamaChat.outcome(
            status: 200, body: Data(#"{"done":true,"done_reason":"stop"}"#.utf8),
            transcript: "euh bonjour", model: "gemma4:12b-it-qat")
        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected .malformedResponse, got \(outcome)")
        }
    }

    /// 0 of the 263 measured refinements returned empty text, so an empty answer is a defect and
    /// not a legitimate "nothing to clean up".
    func testEmptyContentIsAFailureRatherThanAnEmptyRefinement() {
        let outcome = OllamaChat.outcome(
            status: 200, body: successBody(content: "   \n  "), transcript: "euh bonjour tout le monde", model: "gemma4:12b-it-qat")
        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected .malformedResponse, got \(outcome)")
        }
    }

    /// `done_reason: "length"` is the truncation `num_predict` was raised to avoid. It is
    /// reproduced in the corpus (`r-verylong-04`, 370 words, cut at "Donc en fait, il faut
    /// qu'on"), and the text it produces is a valid-looking sentence fragment — the one thing
    /// that must never be pasted silently.
    func testAnAnswerCutOffByTheTokenCapIsReportedRatherThanPasted() {
        let partial = String(repeating: "mot ", count: 200) + "et donc il faut qu'on"
        let outcome = OllamaChat.outcome(
            status: 200, body: successBody(content: partial, doneReason: "length"),
            transcript: String(repeating: "mot ", count: 210), model: "gemma4:12b-it-qat")
        guard case .failed(.truncated(let kept)) = outcome else {
            return XCTFail("expected .truncated, got \(outcome)")
        }
        XCTAssertEqual(kept, partial.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - The refusal

    func testAnAnswerThatCollapsesToARefusalIsFlaggedInsteadOfPasted() {
        let transcript = String(repeating: "alors donc euh il faudrait qu'on revoie le pipeline. ", count: 20)
        let outcome = OllamaChat.outcome(
            status: 200,
            body: successBody(content: "Je ne peux pas vous aider avec cette demande."),
            transcript: transcript, model: "gemma4:12b-it-qat")

        guard case .failed(.refused(let reply)) = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
        XCTAssertEqual(reply, "Je ne peux pas vous aider avec cette demande.")
    }

    /// The floor of the collapse rule, taken from the corpus rather than chosen: over 263
    /// measured refinements the shortest legitimate answer is 0.320 of its input (a
    /// `message_rewrite`, whose whole job is to condense). Anything at or above that ratio has
    /// to come through as a refinement.
    func testTheShortestLegitimateRefinementEverMeasuredIsNotFlaggedAsARefusal() {
        let transcript = String(repeating: "x", count: 1000)
        let refined = String(repeating: "y", count: 320)
        let outcome = OllamaChat.outcome(
            status: 200, body: successBody(content: refined), transcript: transcript, model: "gemma4:12b-it-qat")

        XCTAssertEqual(outcome, .refined(refined))
    }

    func testAnOrdinaryCleanupComesBackAsRefinedText() {
        let outcome = OllamaChat.outcome(
            status: 200, body: successBody(content: "Bonjour, il faudrait revoir le pipeline."),
            transcript: "euh bonjour, il faudrait euh revoir le pipeline", model: "gemma4:12b-it-qat")
        XCTAssertEqual(outcome, .refined("Bonjour, il faudrait revoir le pipeline."))
    }

    func testTheRefinedTextIsTrimmedBecauseModelsPadTheirAnswers() {
        let outcome = OllamaChat.outcome(
            status: 200, body: successBody(content: "\n  Bonjour tout le monde.  \n"),
            transcript: "euh bonjour tout le monde", model: "gemma4:12b-it-qat")
        XCTAssertEqual(outcome, .refined("Bonjour tout le monde."))
    }

    // MARK: - The point of the whole enum

    /// The requirement this task exists for: these are not one failure. Each one has a different
    /// thing for Louis to DO — launch Ollama, pull a model, wait or switch model, report a bug,
    /// dictate shorter, change the prompt — so no two remedies may read the same, and none may
    /// be empty. Collapsing any two of them makes this test fail.
    func testEveryFailureCarriesItsOwnRemedy() {
        let failures: [OllamaFailure] = [
            .notRunning(detail: "connection refused"),
            .modelNotPulled(model: "gemma4:12b-it-qat"),
            .timedOut(after: 120),
            .malformedResponse(detail: "HTTP 500"),
            .truncated(kept: "et donc il faut qu'on"),
            .refused(reply: "Je ne peux pas."),
        ]
        let remedies = failures.map(\.remedy)

        for remedy in remedies {
            XCTAssertFalse(remedy.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertEqual(Set(remedies).count, failures.count, "two failures share a remedy: \(remedies)")
    }

    /// The remedy is what Louis reads; the description is what the log keeps. A remedy that does
    /// not name the model, the deadline or the answer it is talking about sends him to the logs.
    func testTheRemediesNameTheThingTheUserHasToActOn() {
        XCTAssertTrue(
            OllamaFailure.modelNotPulled(model: "gemma4:12b-it-qat").remedy
                .contains("gemma4:12b-it-qat"))
        XCTAssertTrue(OllamaFailure.timedOut(after: 120).remedy.contains("120"))
    }
}
