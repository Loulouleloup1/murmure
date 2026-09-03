import XCTest
@testable import MurmureCore

/// The language half of the Models table: what a probe of the local Ollama concludes, and the row
/// it produces.
///
/// No network is reached from here, the way `OllamaChatTests` reaches none: what is tested is the
/// reading of a status and a body, which is the whole of the decision.
final class OllamaProbeTests: XCTestCase {
    private func listing(_ entries: String) -> Data {
        Data("{\"models\":[\(entries)]}".utf8)
    }

    private func entry(_ name: String, size: Int64 = 8_581_748_736) -> String {
        """
        {"name":"\(name)","model":"\(name)","modified_at":"2026-08-30T10:00:00Z",\
        "size":\(size),"digest":"abc","details":{"family":"gemma3"}}
        """
    }

    // MARK: - The route

    /// The listing route, not a generation one: it reads Ollama's manifests and loads nothing.
    func testTheProbeAsksTheListingRouteOnly() {
        let url = OllamaProbe.endpoint(base: URL(string: "http://localhost:11434")!)

        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/tags")
    }

    // MARK: - The model is there

    func testAListedModelIsPulledWithItsSize() {
        let outcome = OllamaProbe.outcome(
            status: 200, body: listing(entry("gemma4:12b-it-qat")), model: "gemma4:12b-it-qat")

        XCTAssertEqual(outcome, .pulled(bytes: 8_581_748_736))
    }

    /// A listing without a size still answers the question the probe was asked. Losing the row
    /// over a missing number would trade the answer for the decoration.
    func testAListingWithNoSizeStillCountsAsPulled() {
        let body = Data("{\"models\":[{\"name\":\"gemma4:12b\"}]}".utf8)

        XCTAssertEqual(
            OllamaProbe.outcome(status: 200, body: body, model: "gemma4:12b"), .pulled(bytes: 0))
    }

    /// `ollama pull gemma4` is listed as `gemma4:latest`. Comparing the raw strings would report a
    /// model as missing while it sits in the listing one word away, and would print a `ollama
    /// pull` line for something already on the disk.
    func testAModelWithNoTagMatchesTheImplicitLatest() {
        let outcome = OllamaProbe.outcome(
            status: 200, body: listing(entry("gemma4:latest")), model: "gemma4")

        XCTAssertEqual(outcome, .pulled(bytes: 8_581_748_736))
    }

    /// The other direction of the same rule: a tag that was asked for is not satisfied by a
    /// different one. `gemma4:12b` and `gemma4:latest` write differently, which is exactly why
    /// `ModelDisplayName` keeps tags in the first place.
    func testAnExplicitTagIsNotSatisfiedByLatest() {
        let outcome = OllamaProbe.outcome(
            status: 200, body: listing(entry("gemma4:latest")), model: "gemma4:12b")

        XCTAssertEqual(outcome, .failed(.modelNotPulled(model: "gemma4:12b")))
    }

    /// A registry with a port carries a colon that is not a tag, so the tag is looked for after
    /// the last slash -- the same split `ModelDisplayName` makes.
    func testAPortInAHostIsNotMistakenForATag() {
        XCTAssertEqual(OllamaProbe.tagged("localhost:11434/team/model"),
                       "localhost:11434/team/model:latest")
        XCTAssertEqual(OllamaProbe.tagged("hf.co/user/zephyr:Q4_K_M"), "hf.co/user/zephyr:Q4_K_M")
    }

    // MARK: - The model is not there

    func testAServerThatAnswersWithoutTheModelSaysSoAsItsOwnFailure() {
        let outcome = OllamaProbe.outcome(
            status: 200, body: listing(entry("qwen3:8b")), model: "gemma4:12b")

        XCTAssertEqual(outcome, .failed(.modelNotPulled(model: "gemma4:12b")))
    }

    // MARK: - The server is not there

    func testNothingListeningIsClassifiedAsTheServerAndNotAsTheModel() {
        let outcome = OllamaProbe.outcome(
            transport: URLError(.cannotConnectToHost), elapsed: 0.1)

        guard case .failed(.notRunning) = outcome else {
            return XCTFail("expected notRunning, got \(outcome)")
        }
    }

    func testATimeoutStaysATimeout() {
        XCTAssertEqual(
            OllamaProbe.outcome(transport: URLError(.timedOut), elapsed: 4),
            .failed(.timedOut(after: 4)))
    }

    /// A body this client cannot read is a bug report, not a missing model -- telling Louis to
    /// pull a model he already has, because the endpoint was misconfigured, is worse than saying
    /// nothing (the rule `OllamaChat.statusFailure` was written for).
    func testAnUnreadableBodyIsNotReadAsAMissingModel() {
        let outcome = OllamaProbe.outcome(
            status: 200, body: Data("<html>nope</html>".utf8), model: "gemma4:12b")

        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected malformedResponse, got \(outcome)")
        }
    }

    func testAMistypedEndpointIsAMalformedResponseRatherThanAMissingModel() {
        let outcome = OllamaProbe.outcome(
            status: 404, body: Data("404 page not found".utf8), model: "gemma4:12b")

        guard case .failed(.malformedResponse) = outcome else {
            return XCTFail("expected malformedResponse, got \(outcome)")
        }
    }

    // MARK: - The rows

    /// **The distinction T8 exists for.** "Ollama isn't running" and "the model isn't pulled" are
    /// two different sentences, and this is the test that keeps them from being merged back into
    /// one -- the sibling of `testEveryFailureCarriesItsOwnRemedy` in `OllamaChatTests`.
    func testTheServerBeingDownAndTheModelBeingMissingAreTwoDifferentSentences() {
        let down = OllamaProbe.row(
            for: "gemma4:12b", outcome: .failed(.notRunning(detail: "61 refused")))
        let missing = OllamaProbe.row(
            for: "gemma4:12b", outcome: .failed(.modelNotPulled(model: "gemma4:12b")))

        XCTAssertNotEqual(down.detail, missing.detail)
        XCTAssertEqual(down.installation, .undetermined(reason: down.detail ?? ""))
        XCTAssertEqual(missing.installation, .absent)
        XCTAssertTrue(missing.detail?.contains("ollama pull gemma4:12b") == true, missing.detail ?? "")
        XCTAssertTrue(down.detail?.contains("ollama serve") == true, down.detail ?? "")
    }

    /// Not asked and not installed are different facts about a model, and the pane draws before
    /// the probe is allowed to run -- so the un-probed row must not borrow the missing one's
    /// sentence.
    func testAnUnprobedRowSaysItHasNotBeenCheckedRatherThanThatNothingIsInstalled() {
        let unprobed = OllamaProbe.row(for: "gemma4:12b", outcome: nil)
        let missing = OllamaProbe.row(
            for: "gemma4:12b", outcome: .failed(.modelNotPulled(model: "gemma4:12b")))

        XCTAssertEqual(unprobed.installation, .undetermined(reason: OllamaProbe.notCheckedYet))
        XCTAssertNotEqual(unprobed.detail, missing.detail)
        XCTAssertNil(unprobed.size, "nothing has been measured, so no number is printed")
    }

    /// Murmure never writes to Ollama's store, so no row of this family may offer a button that
    /// implies it does -- whatever the probe answered.
    func testNoLanguageRowEverOffersToDownloadOrDelete() {
        let outcomes: [OllamaProbe.Outcome?] = [
            nil,
            .pulled(bytes: 8_581_748_736),
            .failed(.modelNotPulled(model: "gemma4:12b")),
            .failed(.notRunning(detail: "61 refused")),
            .failed(.timedOut(after: 4)),
        ]

        for outcome in outcomes {
            let row = OllamaProbe.row(for: "gemma4:12b", outcome: outcome)
            XCTAssertEqual(row.action, .managedElsewhere, "\(String(describing: outcome))")
            XCTAssertEqual(row.kind, .language)
        }
    }

    /// The name column drops the registry and keeps the tag, which is `ModelDisplayName`'s rule
    /// and not a second one.
    func testAPulledRowShowsItsReadableNameAndItsSize() {
        let row = OllamaProbe.row(for: "hf.co/user/zephyr:Q4_K_M", outcome: .pulled(bytes: 4_600_000))

        XCTAssertEqual(row.name, "zephyr:Q4_K_M")
        XCTAssertEqual(row.size, "4.6 MB")
        XCTAssertNil(row.detail, "an installed model has nothing to explain")
    }
}
