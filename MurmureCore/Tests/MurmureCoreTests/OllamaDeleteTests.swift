import XCTest
@testable import MurmureCore

/// `DELETE /api/delete`'s request shape and the reading of its response -- the piece that has to
/// exist before the Models pane's Delete button on a language row can be anything more than a
/// button that has never been pressed.
final class OllamaDeleteTests: XCTestCase {
    func testEndpointAppendsTheDeleteRoute() {
        XCTAssertEqual(
            OllamaDelete.endpoint(base: URL(string: "http://localhost:11434")!).absoluteString,
            "http://localhost:11434/api/delete")
    }

    func testRequestBodyNamesTheModel() throws {
        let body = OllamaDelete.requestBody(model: "gemma4:12b-it-qat")
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]

        XCTAssertEqual(decoded?["model"], "gemma4:12b-it-qat")
    }

    func testASuccessfulDeleteIsSucceeded() {
        XCTAssertEqual(OllamaDelete.outcome(status: 200, body: Data(), model: "gemma4"), .succeeded)
    }

    /// Ollama's own shape for "this model is not there": a JSON error body under a non-200 status.
    func testAModelOllamaDoesNotHaveIsRejectedWithOllamasOwnMessage() {
        let outcome = OllamaDelete.outcome(
            status: 404, body: Data(#"{"error":"model 'gemma4' not found"}"#.utf8), model: "gemma4")

        XCTAssertEqual(outcome, .failed(.rejected(model: "gemma4", detail: "model 'gemma4' not found")))
    }

    func testANonJSONBodyIsMalformedRatherThanRejected() {
        let outcome = OllamaDelete.outcome(status: 500, body: Data("internal error".utf8), model: "gemma4")

        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected .malformedResponse, got \(outcome)")
        }
    }

    func testATransportFailureIsNotRunning() {
        let failure = OllamaDelete.failure(transport: URLError(.cannotConnectToHost))

        guard case .notRunning = failure else {
            return XCTFail("expected .notRunning, got \(failure)")
        }
    }

    // MARK: - Remedies stay in the moment's own vocabulary

    func testTheRejectedRemedyNamesDeleteAndNotPull() {
        let remedy = OllamaDeleteFailure.rejected(model: "gemma4", detail: "not found").remedy

        XCTAssertTrue(remedy.contains("delete"), remedy)
        XCTAssertFalse(remedy.contains("pull"), remedy)
    }
}
