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

    func testThreeBareSegmentsAreRefused() {
        XCTAssertNil(HuggingFaceRepository.parse("argmaxinc/whisperkit-coreml/extra"))
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

    // MARK: - Characters neither shape allows

    func testAComponentWithASpaceIsRefused() {
        XCTAssertNil(HuggingFaceRepository.parse("argmaxinc/whisperkit coreml"))
    }

    func testDotsAndUnderscoresAndHyphensAreAllowedInEitherComponent() {
        XCTAssertEqual(HuggingFaceRepository.parse("my_org-1/model.name-v2"), "my_org-1/model.name-v2")
    }
}
