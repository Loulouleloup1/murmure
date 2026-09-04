import XCTest

@testable import MurmureCore

final class SpeechModelResolutionTests: XCTestCase {
    private let engineDefault = "openai_whisper-large-v3-v20240930_turbo"

    /// The shipped default alias every mode file already carries (`Mode.defaultSTTModel`) means
    /// "nothing was actually asked for" -- resolving it as a Hub variant would risk pointing an
    /// unedited mode at a different model than the one the engine has verified and already has on
    /// disk.
    func testTheShippedDefaultAliasResolvesToTheEngineDefault() {
        XCTAssertEqual(
            SpeechModelResolution.variant(storedAs: "large-v3-turbo", engineDefault: engineDefault),
            engineDefault)
    }

    /// A blank field -- a hand-cleared mode file -- means the same thing as the shipped alias.
    func testABlankFieldResolvesToTheEngineDefault() {
        XCTAssertEqual(
            SpeechModelResolution.variant(storedAs: "  \n ", engineDefault: engineDefault),
            engineDefault)
        XCTAssertEqual(
            SpeechModelResolution.variant(storedAs: "", engineDefault: engineDefault), engineDefault)
    }

    /// A variant somebody actually typed is passed through unchanged, exact folder name or alias
    /// alike -- resolving THAT one is the engine's job, not this rule's.
    func testAnExplicitlyNamedVariantPassesThroughUnchanged() {
        XCTAssertEqual(
            SpeechModelResolution.variant(
                storedAs: "openai_whisper-tiny", engineDefault: engineDefault),
            "openai_whisper-tiny")
    }

    /// Whitespace around an explicit variant is trimmed, the same way `Mode.validationError`
    /// trims before deciding a field is empty -- a trailing newline from a pasted value must not
    /// turn into a variant nothing on the Hub will match.
    func testAnExplicitVariantIsTrimmed() {
        XCTAssertEqual(
            SpeechModelResolution.variant(
                storedAs: "  openai_whisper-tiny  \n", engineDefault: engineDefault),
            "openai_whisper-tiny")
    }
}
