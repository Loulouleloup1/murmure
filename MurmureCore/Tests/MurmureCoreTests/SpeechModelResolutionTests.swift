import XCTest

@testable import MurmureCore

final class SpeechModelResolutionTests: XCTestCase {
    private let engineDefault = SpeechModelReference(
        repository: "argmaxinc/whisperkit-coreml",
        variant: "openai_whisper-large-v3-v20240930_turbo")

    /// The shipped default alias every mode file carried before ``SpeechModelReference`` existed
    /// means "nothing was actually asked for" -- resolving it as a Hub variant would risk pointing
    /// an unedited mode at a different model than the one the engine has verified and already has
    /// on disk.
    func testTheShippedDefaultAliasResolvesToTheEngineDefault() {
        XCTAssertEqual(
            SpeechModelResolution.reference(storedAs: "large-v3-turbo", engineDefault: engineDefault),
            engineDefault)
    }

    /// A blank field -- a hand-cleared mode file -- means the same thing as the shipped alias.
    func testABlankFieldResolvesToTheEngineDefault() {
        XCTAssertEqual(
            SpeechModelResolution.reference(storedAs: "  \n ", engineDefault: engineDefault),
            engineDefault)
        XCTAssertEqual(
            SpeechModelResolution.reference(storedAs: "", engineDefault: engineDefault), engineDefault)
    }

    /// A full `"owner/name/variant"` reference is parsed and returned exactly -- resolving whether
    /// that repository and variant actually exist on the Hub is the engine's job, not this one's.
    func testAFullReferenceIsParsedAndPassedThrough() {
        XCTAssertEqual(
            SpeechModelResolution.reference(
                storedAs: "someowner/somerepo/some-variant", engineDefault: engineDefault),
            SpeechModelReference(repository: "someowner/somerepo", variant: "some-variant"))
    }

    /// A variant with more than one internal slash still splits into exactly a two-component
    /// repository and the rest as the variant -- the same rule ``SpeechModelReference/init(parsing:)``
    /// itself follows.
    func testAFullReferenceWithAMultiSegmentVariantJoinsTheRemainder() {
        XCTAssertEqual(
            SpeechModelResolution.reference(
                storedAs: "someowner/somerepo/nested/variant", engineDefault: engineDefault),
            SpeechModelReference(repository: "someowner/somerepo", variant: "nested/variant"))
    }

    /// A bare variant somebody typed by hand -- no repository at all, the shape every mode file
    /// carried before this migration -- is assumed to live in the engine default's own repository,
    /// exact folder name or alias alike.
    func testABareVariantIsAssumedToLiveInTheEngineDefaultsRepository() {
        XCTAssertEqual(
            SpeechModelResolution.reference(
                storedAs: "openai_whisper-tiny", engineDefault: engineDefault),
            SpeechModelReference(repository: "argmaxinc/whisperkit-coreml", variant: "openai_whisper-tiny"))
    }

    /// Whitespace around a stored value is trimmed, the same way `Mode.validationError` trims
    /// before deciding a field is empty -- a trailing newline from a pasted value must not turn
    /// into a variant nothing on the Hub will match.
    func testAStoredValueIsTrimmed() {
        XCTAssertEqual(
            SpeechModelResolution.reference(
                storedAs: "  openai_whisper-tiny  \n", engineDefault: engineDefault),
            SpeechModelReference(repository: "argmaxinc/whisperkit-coreml", variant: "openai_whisper-tiny"))
    }

    /// **The defect a review caught.** A two-component value has no variant to complete it with,
    /// and `ModeStore`'s own migration refuses to guess one (`ModeLoadProblem.sttModelNotAReference`
    /// promises "the mode keeps it, dictation falls back to the shipped model"). This function has
    /// to make that promise true: resolving to a FABRICATED reference
    /// (`argmaxinc/whisperkit-coreml/openai/whisper-large-v3`, treating the whole two-component
    /// string as a bare variant) would send `WhisperKitEngine` after a repository that does not
    /// have it -- a Hub round trip online, an outright failure offline -- instead of falling back.
    /// Both this and a bare `"owner/name"` with no meaning at all resolve the same way: to
    /// `engineDefault`, exactly like the blank case.
    func testATwoComponentValueFallsBackToTheEngineDefaultRatherThanFabricatingAReference() {
        XCTAssertEqual(
            SpeechModelResolution.reference(
                storedAs: "openai/whisper-large-v3", engineDefault: engineDefault),
            engineDefault)
        XCTAssertEqual(
            SpeechModelResolution.reference(storedAs: "owner/name", engineDefault: engineDefault),
            engineDefault)
    }
}
