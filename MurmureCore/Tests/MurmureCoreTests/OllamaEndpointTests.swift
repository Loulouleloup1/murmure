import XCTest
@testable import MurmureCore

/// The gate `ModesPaneModel.reload()` and `ModelsPaneModel.reload()` both call before reading
/// `/api/tags` automatically, on appear -- see `OllamaEndpoint`'s own doc comment for why an
/// on-appear read must be provably loopback rather than merely assumed to be.
final class OllamaEndpointTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "http://localhost")!
        }
        return url
    }

    func testLocalhostIsLoopback() {
        XCTAssertTrue(OllamaEndpoint.isLoopback(url("http://localhost:11434")))
    }

    func testTheLoopbackIPv4AddressIsLoopback() {
        XCTAssertTrue(OllamaEndpoint.isLoopback(url("http://127.0.0.1:11434")))
    }

    func testTheLoopbackIPv6AddressIsLoopback() {
        XCTAssertTrue(OllamaEndpoint.isLoopback(url("http://[::1]:11434")))
    }

    /// `URL`'s own host accessor is not case-normalised on the way in, so the check has to do it.
    func testTheHostIsComparedCaseInsensitively() {
        XCTAssertTrue(OllamaEndpoint.isLoopback(url("http://LOCALHOST:11434")))
    }

    /// **The case this whole type exists for.** A mode can hold a LAN address and still pass
    /// `Mode.validationError` -- that check only requires an http(s) URL that is its own root, not
    /// a loopback host -- so this is the one place that distinction is actually made.
    func testALANAddressIsNotLoopback() {
        XCTAssertFalse(OllamaEndpoint.isLoopback(url("http://192.168.1.50:11434")))
    }

    func testARemoteHostnameIsNotLoopback() {
        XCTAssertFalse(OllamaEndpoint.isLoopback(url("https://ollama.example.com")))
    }

    func testAURLWithNoHostIsNotLoopback() {
        XCTAssertFalse(OllamaEndpoint.isLoopback(url("file:///tmp/whatever")))
    }

    // MARK: - loopbackRoot(preferring:) -- lot 5 review, item 10

    /// Moved here from `ModesPaneModel`'s own private `loopbackOllamaEndpoint`: the drafting
    /// sheet's endpoint resolution is exactly this same rule, and a rule with only one caller in
    /// the app target still belongs in `MurmureCore` when the app target has no test bundle of its
    /// own to prove it in.
    func testLoopbackRootPrefersALoopbackEndpointWhenGiven() {
        XCTAssertEqual(
            OllamaEndpoint.loopbackRoot(preferring: "http://127.0.0.1:11434"),
            url("http://127.0.0.1:11434"))
    }

    func testLoopbackRootFallsBackToTheLocalRootWhenTheEndpointIsNotLoopback() {
        XCTAssertEqual(
            OllamaEndpoint.loopbackRoot(preferring: "http://192.168.1.50:11434"),
            OllamaEndpoint.localRoot)
    }

    func testLoopbackRootFallsBackToTheLocalRootWhenNothingIsGiven() {
        XCTAssertEqual(OllamaEndpoint.loopbackRoot(preferring: nil), OllamaEndpoint.localRoot)
    }

    func testLoopbackRootFallsBackToTheLocalRootWhenTheEndpointDoesNotParse() {
        XCTAssertEqual(
            OllamaEndpoint.loopbackRoot(preferring: "not a url"), OllamaEndpoint.localRoot)
    }
}
