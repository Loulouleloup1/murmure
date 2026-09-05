import XCTest
@testable import MurmureCore

/// Both shapes Louis described -- *"connecter Hugging Face ou alors mettre juste le lien"* -- read
/// down to the one id the Hub client wants, and everything that is neither shape is refused before
/// anything is asked of the network.
final class HuggingFaceRepositoryTests: XCTestCase {
    // MARK: - The bare id

    func testABareOwnerSlashRepoIsUsedAsIs() {
        XCTAssertEqual(HuggingFaceRepository.parse("argmaxinc/whisperkit-coreml"), "argmaxinc/whisperkit-coreml")
    }

    func testABareIdIsTrimmedOfSurroundingWhitespace() {
        XCTAssertEqual(HuggingFaceRepository.parse("  argmaxinc/whisperkit-coreml  "), "argmaxinc/whisperkit-coreml")
    }

    func testABareIdWithATrailingSlashIsStillTheSameId() {
        XCTAssertEqual(HuggingFaceRepository.parse("argmaxinc/whisperkit-coreml/"), "argmaxinc/whisperkit-coreml")
    }

    func testASingleSegmentIsRefusedForHavingNoOwner() {
        XCTAssertNil(HuggingFaceRepository.parse("whisperkit-coreml"))
    }

    /// `owner/repo/variant` is a `SpeechModelReference`'s own display string -- the exact text
    /// `ModelRow` shows for an installed speech model -- so pasting it back into "Add a model"
    /// must still find the repository rather than falling through to "read as an Ollama name".
    func testABareOwnerRepoVariantFoldsToTheRepository() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("argmaxinc/whisperkit-coreml/openai_whisper-tiny"),
            "argmaxinc/whisperkit-coreml")
    }

    func testFourBareSegmentsAreRefused() {
        XCTAssertNil(HuggingFaceRepository.parse("argmaxinc/whisperkit-coreml/extra/segment"))
    }

    /// `hf.co/<owner>/<repo>[:<tag>]` is Ollama's own convention, not a Hugging Face repository --
    /// the one 3-segment shape that must NOT fold, or every hf.co Ollama name typed into "Add a
    /// model" would be sent to the Hugging Face API instead of pulled as typed.
    func testAnHFCoOllamaNameIsNotReadAsAHuggingFaceRepository() {
        XCTAssertNil(HuggingFaceRepository.parse("hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
        XCTAssertNil(HuggingFaceRepository.parse("hf.co/superwhisper/s1-mini-GGUF"))
    }

    func testEmptyAndWhitespaceOnlyInputIsRefused() {
        XCTAssertNil(HuggingFaceRepository.parse(""))
        XCTAssertNil(HuggingFaceRepository.parse("   "))
    }

    // MARK: - The pasted URL

    func testAPastedRepositoryURLYieldsTheBareId() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("https://huggingface.co/argmaxinc/whisperkit-coreml"),
            "argmaxinc/whisperkit-coreml")
    }

    func testAURLWithHubChromeAfterTheIdStillYieldsOnlyTheId() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main"),
            "argmaxinc/whisperkit-coreml")
    }

    func testAURLWithATrailingSlashYieldsTheSameId() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("https://huggingface.co/argmaxinc/whisperkit-coreml/"),
            "argmaxinc/whisperkit-coreml")
    }

    func testTheWwwHostIsAcceptedTheSameAsTheBareOne() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("https://www.huggingface.co/argmaxinc/whisperkit-coreml"),
            "argmaxinc/whisperkit-coreml")
    }

    func testAURLOnADifferentHostIsRefused() {
        XCTAssertNil(HuggingFaceRepository.parse("https://github.com/argmaxinc/whisperkit-coreml"))
    }

    func testAURLMissingARepoSegmentIsRefused() {
        XCTAssertNil(HuggingFaceRepository.parse("https://huggingface.co/argmaxinc"))
    }

    // MARK: - A host pasted with no scheme

    /// `URL(string:)` reports no host for a scheme-less string, so `huggingface.co/owner/repo` --
    /// a very plausible paste, dropping the `https://` -- never takes the URL branch above and
    /// must still fold correctly rather than being read as a 3-segment `owner/repo/variant` (which
    /// would wrongly yield `"huggingface.co/owner"`).
    func testASchemeLessHuggingFaceHostFoldsTheSameAsTheURL() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("huggingface.co/argmaxinc/whisperkit-coreml"),
            "argmaxinc/whisperkit-coreml")
    }

    func testASchemeLessWwwHuggingFaceHostFoldsTheSameAsTheURL() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("www.huggingface.co/argmaxinc/whisperkit-coreml"),
            "argmaxinc/whisperkit-coreml")
    }

    func testASchemeLessHuggingFaceHostWithHubChromeStillYieldsOnlyTheId() {
        XCTAssertEqual(
            HuggingFaceRepository.parse("huggingface.co/argmaxinc/whisperkit-coreml/tree/main"),
            "argmaxinc/whisperkit-coreml")
    }

    func testASchemeLessHuggingFaceHostMissingARepoSegmentIsRefused() {
        XCTAssertNil(HuggingFaceRepository.parse("huggingface.co/argmaxinc"))
    }

    /// Any OTHER dotted first segment is a host too, just not one this field resolves as a
    /// Hugging Face repository -- an Ollama registry name, typed exactly as `ollama pull` would
    /// take it, must not be misread as `owner/repo` with the registry host standing in for the
    /// owner.
    func testAnOllamaRegistryHostIsNotReadAsAHuggingFaceRepository() {
        XCTAssertNil(HuggingFaceRepository.parse("registry.ollama.ai/library/gemma"))
    }

    // MARK: - Characters neither shape allows

    func testAComponentWithASpaceIsRefused() {
        XCTAssertNil(HuggingFaceRepository.parse("argmaxinc/whisperkit coreml"))
    }

    func testDotsAndUnderscoresAndHyphensAreAllowedInEitherComponent() {
        XCTAssertEqual(HuggingFaceRepository.parse("my_org-1/model.name-v2"), "my_org-1/model.name-v2")
    }
}
