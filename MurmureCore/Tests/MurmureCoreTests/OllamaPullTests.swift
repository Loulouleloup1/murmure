import XCTest
@testable import MurmureCore

/// `POST /api/pull`'s request shape and the reading of its streamed NDJSON progress -- the half of
/// "add a language model" that has to exist before typing a new `llm.model` id into a mode means
/// anything more than `OllamaFailure.modelNotPulled` forever.
final class OllamaPullTests: XCTestCase {
    // MARK: - The request

    func testEndpointAppendsThePullRoute() {
        XCTAssertEqual(
            OllamaPull.endpoint(base: URL(string: "http://localhost:11434")!).absoluteString,
            "http://localhost:11434/api/pull")
    }

    func testRequestBodyNamesTheModel() throws {
        let body = OllamaPull.requestBody(model: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M")
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]

        XCTAssertEqual(decoded?["model"], "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M")
    }

    // MARK: - Reading one streamed line

    private func line(_ json: String) -> Data { Data(json.utf8) }

    func testABlankLineIsNil() {
        XCTAssertNil(OllamaPull.outcome(line: Data(), model: "gemma3"))
        XCTAssertNil(OllamaPull.outcome(line: line("   \n"), model: "gemma3"))
    }

    func testAManifestLineWithNoNumbersIsProgressWithNoFraction() {
        let outcome = OllamaPull.outcome(line: line(#"{"status":"pulling manifest"}"#), model: "gemma3")

        XCTAssertEqual(outcome, .progress(status: "pulling manifest", fraction: nil))
    }

    func testATransferLineWithTotalsIsProgressWithAFraction() {
        let outcome = OllamaPull.outcome(
            line: line(#"{"status":"pulling abc123","total":1000,"completed":250}"#), model: "gemma3")

        XCTAssertEqual(outcome, .progress(status: "pulling abc123", fraction: 0.25))
    }

    /// However Ollama rounds it, the fraction never reads over 1 -- a `completed` that overshoots
    /// `total` on the last chunk must not paint a bar past its own end.
    func testAFractionIsNeverReportedOverOne() {
        let outcome = OllamaPull.outcome(
            line: line(#"{"status":"pulling abc123","total":1000,"completed":1004}"#), model: "gemma3")

        XCTAssertEqual(outcome, .progress(status: "pulling abc123", fraction: 1))
    }

    func testASuccessLineIsSucceeded() {
        XCTAssertEqual(OllamaPull.outcome(line: line(#"{"status":"success"}"#), model: "gemma3"), .succeeded)
    }

    /// The shape Ollama uses for a bad model id INSIDE a 200 stream, rather than as an HTTP status.
    func testAnErrorLineIsRejectedWithOllamasOwnMessage() {
        let outcome = OllamaPull.outcome(
            line: line(#"{"error":"pull model manifest: file does not exist"}"#), model: "nope/nope")

        XCTAssertEqual(
            outcome, .failed(.rejected(model: "nope/nope", detail: "pull model manifest: file does not exist")))
    }

    func testUnreadableJSONIsMalformed() {
        let outcome = OllamaPull.outcome(line: line("not json at all"), model: "gemma3")

        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected malformedResponse, got \(String(describing: outcome))")
        }
    }

    func testALineWithNeitherStatusNorErrorIsMalformed() {
        let outcome = OllamaPull.outcome(line: line(#"{"digest":"sha256:abc"}"#), model: "gemma3")

        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected malformedResponse, got \(String(describing: outcome))")
        }
    }

    // MARK: - A rejection before the stream even opens

    func test404WithAnErrorBodyIsRejected() {
        let body = Data(#"{"error":"model 'nope' not found"}"#.utf8)

        XCTAssertEqual(
            OllamaPull.statusFailure(status: 404, body: body, model: "nope"),
            .rejected(model: "nope", detail: "model 'nope' not found"))
    }

    func testANonJSONErrorBodyIsMalformedRatherThanRejected() {
        let body = Data("404 page not found".utf8)

        XCTAssertEqual(
            OllamaPull.statusFailure(status: 404, body: body, model: "nope"),
            .malformedResponse(detail: "HTTP 404: 404 page not found"))
    }

    func testStatus200NeverFails() {
        XCTAssertNil(OllamaPull.statusFailure(status: 200, body: Data(), model: "gemma3"))
    }

    // MARK: - Transport

    func testATransportErrorThatIsNotAURLErrorReadsAsNotRunning() {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

        XCTAssertEqual(OllamaPull.failure(transport: Boom()), .notRunning(detail: "boom"))
    }

    func testAConnectionRefusedReadsAsNotRunning() {
        let error = URLError(.cannotConnectToHost)

        guard case .notRunning = OllamaPull.failure(transport: error) else {
            return XCTFail("expected notRunning")
        }
    }

    // MARK: - Remedies are all different sentences

    func testEveryFailureCarriesItsOwnRemedy() {
        let failures: [OllamaPullFailure] = [
            .notRunning(detail: "x"),
            .rejected(model: "gemma3", detail: "not found"),
            .malformedResponse(detail: "x"),
        ]

        XCTAssertEqual(Set(failures.map(\.remedy)).count, failures.count)
    }
}
