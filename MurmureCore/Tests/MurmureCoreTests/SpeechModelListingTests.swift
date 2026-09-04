import XCTest
@testable import MurmureCore

/// The fallback path for a repository `WhisperKit.fetchAvailableModels` cannot answer for honestly
/// (no `config.json`): read the repository's own file listing and decide from that instead of
/// wearing Argmax's fallback list as though it described this repository.
final class SpeechModelListingTests: XCTestCase {
    private let requiredBundles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    /// The shape a real WhisperKit CoreML repository listing has: one folder per variant, each
    /// bundle a folder of its own with real files inside.
    func testAFolderHoldingAllThreeBundlesIsOfferedAndAnIncompleteOneIsNot() {
        let filenames = [
            "openai_whisper-tiny/config.json",
            "openai_whisper-tiny/MelSpectrogram.mlmodelc/coremldata.bin",
            "openai_whisper-tiny/AudioEncoder.mlmodelc/coremldata.bin",
            "openai_whisper-tiny/TextDecoder.mlmodelc/coremldata.bin",
            // Missing MelSpectrogram and TextDecoder -- not a variant this app could load.
            "openai_whisper-small/config.json",
            "openai_whisper-small/AudioEncoder.mlmodelc/coremldata.bin",
            "README.md",
        ]

        XCTAssertEqual(
            SpeechModelListing.plausibleVariants(in: filenames, requiredBundles: requiredBundles),
            ["openai_whisper-tiny"])
    }

    func testMultipleCompleteVariantsComeBackSorted() {
        let filenames = [
            "b-variant/MelSpectrogram.mlmodelc/x", "b-variant/AudioEncoder.mlmodelc/x",
            "b-variant/TextDecoder.mlmodelc/x",
            "a-variant/MelSpectrogram.mlmodelc/x", "a-variant/AudioEncoder.mlmodelc/x",
            "a-variant/TextDecoder.mlmodelc/x",
        ]

        XCTAssertEqual(
            SpeechModelListing.plausibleVariants(in: filenames, requiredBundles: requiredBundles),
            ["a-variant", "b-variant"])
    }

    func testARepositoryWithNoQualifyingFolderOffersNothing() {
        let filenames = ["README.md", "LICENSE", "some-dataset/data.parquet"]

        XCTAssertEqual(
            SpeechModelListing.plausibleVariants(in: filenames, requiredBundles: requiredBundles), [])
    }

    func testAnEmptyListingOffersNothing() {
        XCTAssertEqual(SpeechModelListing.plausibleVariants(in: [], requiredBundles: requiredBundles), [])
    }

    /// A bundle folder that exists but holds nothing does not satisfy the check: the substring
    /// search needs a FILE under the bundle, not merely its name appearing somewhere in a path.
    func testABundleNamedButEmptyDoesNotCount() {
        let filenames = [
            "half-variant/MelSpectrogram.mlmodelc", // no trailing "/", no file under it
            "half-variant/AudioEncoder.mlmodelc/x",
            "half-variant/TextDecoder.mlmodelc/x",
        ]

        XCTAssertEqual(
            SpeechModelListing.plausibleVariants(in: filenames, requiredBundles: requiredBundles), [])
    }
}
