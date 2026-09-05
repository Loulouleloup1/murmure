import XCTest
@testable import MurmureCore

/// `SpeechModelReference.init(parsing:)` itself -- the "first two components are the repository"
/// rule, pinned down directly rather than only through `SpeechModelResolution`'s own tests, which
/// never pass it a string with fewer than three components in the first place.
final class SpeechModelReferenceTests: XCTestCase {
    func testTwoComponentsIsNotAReference() {
        XCTAssertNil(SpeechModelReference(parsing: "owner/name"))
    }

    func testABlankStringIsNotAReference() {
        XCTAssertNil(SpeechModelReference(parsing: ""))
    }

    /// The rule this whole type exists to get right: the first two components are always the
    /// repository, never more, however many segments follow.
    func testExactlyTheFirstTwoComponentsAreTheRepository() {
        let reference = SpeechModelReference(parsing: "a/b/c/d")

        XCTAssertEqual(reference?.repository, "a/b")
        XCTAssertEqual(reference?.variant, "c/d")
    }

    func testTheShippedDefaultsOwnStringRoundTrips() {
        let parsed = SpeechModelReference(parsing: SpeechModelReference.shippedDefault.string)

        XCTAssertEqual(parsed, SpeechModelReference.shippedDefault)
    }

    /// A leading slash is a degenerate form of the same string, not a fourth shape -- pinning down
    /// what `split(separator:omittingEmptySubsequences: true)` actually does with it (drops the
    /// empty leading component) rather than leaving that an accident nothing checks.
    func testALeadingSlashIsIgnoredRatherThanShiftingTheComponents() {
        let reference = SpeechModelReference(parsing: "/a/b/c")

        XCTAssertEqual(reference?.repository, "a/b")
        XCTAssertEqual(reference?.variant, "c")
    }
}
