import XCTest
@testable import MurmureCore

/// `ModelClassifier` proved two ways: synthetic listings for the shape of each rule, and the
/// three real Hugging Face responses saved under `Fixtures/` (2026-09-05, `blobs=true`, stripped
/// of nothing -- they are public metadata) for the shapes this app actually has to tell apart.
final class ModelClassifierTests: XCTestCase {
    private let requiredBundles = ModelInventory.requiredBundles

    // MARK: - Synthetic: one rule at a time

    func testARepositoryWithOnlySpeechBundlesIsSpeechOnly() {
        let siblings = speechVariant("openai_whisper-tiny", eachFileBytes: 100)

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .speechOnly(let candidates) = result else {
            return XCTFail("expected .speechOnly, got \(result)")
        }
        XCTAssertEqual(candidates, [SpeechCandidate(variant: "openai_whisper-tiny", bytes: 300)])
    }

    func testARepositoryWithOnlyGGUFFilesIsRefinerOnly() {
        let siblings = [
            HuggingFaceSibling(rfilename: "model-q4_k_m.gguf", size: 1_000),
            HuggingFaceSibling(rfilename: "model-f16.gguf", size: 2_000),
        ]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .refinerOnly(let candidates) = result else {
            return XCTFail("expected .refinerOnly, got \(result)")
        }
        XCTAssertEqual(
            Set(candidates.map(\.tag)), ["Q4_K_M", "F16"],
            "the tag is upper-cased regardless of the file's own case")
    }

    /// Hugging Face repositories are not consistent about the case of the `.gguf` extension
    /// itself; a repository that uppercases it must classify exactly the same way.
    func testAnUppercasedGGUFExtensionIsStillRecognised() {
        let siblings = [HuggingFaceSibling(rfilename: "model-Q4_K_M.GGUF", size: 1_000)]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .refinerOnly(let candidates) = result else {
            return XCTFail("expected .refinerOnly, got \(result)")
        }
        XCTAssertEqual(candidates.map(\.tag), ["Q4_K_M"])
    }

    func testARepositoryWithBothOffersBothAndLetsTheCallerChoose() {
        var siblings = speechVariant("openai_whisper-tiny", eachFileBytes: 100)
        siblings.append(HuggingFaceSibling(rfilename: "model-q4_k_m.gguf", size: 500))

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .both(let speech, let refiner) = result else {
            return XCTFail("expected .both, got \(result)")
        }
        XCTAssertEqual(speech.map(\.variant), ["openai_whisper-tiny"])
        XCTAssertEqual(refiner.map(\.tag), ["Q4_K_M"])
    }

    func testSafetensorsOnlyIsNotRunnableAndSaysSo() {
        let siblings = [
            HuggingFaceSibling(rfilename: "model-00001-of-00002.safetensors", size: 100),
            HuggingFaceSibling(rfilename: "model-00002-of-00002.safetensors", size: 100),
            HuggingFaceSibling(rfilename: "config.json", size: 10),
        ]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .notRunnable(let reason, let hasSafetensors) = result else {
            return XCTFail("expected .notRunnable, got \(result)")
        }
        XCTAssertTrue(hasSafetensors)
        XCTAssertTrue(reason.lowercased().contains("safetensors"), reason)
    }

    func testAnEmptyOrIrrelevantListingIsNotRunnableWithoutMentioningSafetensors() {
        let siblings = [HuggingFaceSibling(rfilename: "README.md", size: 10)]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .notRunnable(_, let hasSafetensors) = result else {
            return XCTFail("expected .notRunnable, got \(result)")
        }
        XCTAssertFalse(hasSafetensors)
    }

    /// A file with no size reported anywhere under the variant folder must not be silently
    /// summed as if it weighed nothing: the row's own size column reads "--" for `nil`, never a
    /// number smaller than the truth.
    func testAVariantWithAnyUnsizedFileHasNoTotalRatherThanAnUndercount() {
        let siblings = [
            HuggingFaceSibling(rfilename: "openai_whisper-tiny/MelSpectrogram.mlmodelc/x", size: 100),
            HuggingFaceSibling(rfilename: "openai_whisper-tiny/AudioEncoder.mlmodelc/x", size: nil),
            HuggingFaceSibling(rfilename: "openai_whisper-tiny/TextDecoder.mlmodelc/x", size: 100),
        ]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .speechOnly(let candidates) = result else {
            return XCTFail("expected .speechOnly, got \(result)")
        }
        XCTAssertNil(candidates.first?.bytes)
    }

    /// A sharded refiner: three files sharing one quantisation must classify as ONE candidate,
    /// with the three shards' bytes summed -- not three rows for a model `ollama pull` fetches (and
    /// Louis would install) in a single pull.
    func testAThreeShardModelSharingOneQuantIsOneCandidateWithSummedBytes() {
        let siblings = [
            HuggingFaceSibling(rfilename: "Q4_K_M/model-00001-of-00003.gguf", size: 1_000),
            HuggingFaceSibling(rfilename: "Q4_K_M/model-00002-of-00003.gguf", size: 2_000),
            HuggingFaceSibling(rfilename: "Q4_K_M/model-00003-of-00003.gguf", size: 3_000),
        ]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .refinerOnly(let candidates) = result else {
            return XCTFail("expected .refinerOnly, got \(result)")
        }
        XCTAssertEqual(candidates.count, 1, "three shards of one quant must be one row, not three")
        XCTAssertEqual(candidates.first?.tag, "Q4_K_M")
        XCTAssertEqual(candidates.first?.bytes, 6_000)
    }

    /// Two different quantisations, one of them sharded, must still be two candidates -- grouping
    /// by tag must not collapse different tags together.
    func testTwoDifferentQuantisationsRemainTwoCandidatesEvenWhenOneIsSharded() {
        let siblings = [
            HuggingFaceSibling(rfilename: "Q4_K_M/model-00001-of-00002.gguf", size: 1_000),
            HuggingFaceSibling(rfilename: "Q4_K_M/model-00002-of-00002.gguf", size: 1_000),
            HuggingFaceSibling(rfilename: "model-f16.gguf", size: 5_000),
        ]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .refinerOnly(let candidates) = result else {
            return XCTFail("expected .refinerOnly, got \(result)")
        }
        XCTAssertEqual(Set(candidates.map(\.tag)), ["Q4_K_M", "F16"])
        XCTAssertEqual(candidates.first { $0.tag == "Q4_K_M" }?.bytes, 2_000)
        XCTAssertEqual(candidates.first { $0.tag == "F16" }?.bytes, 5_000)
    }

    /// One shard with an unknown size must leave the WHOLE candidate's total unknown, the same
    /// "no undercount" rule `testAVariantWithAnyUnsizedFileHasNoTotalRatherThanAnUndercount`
    /// already proves for a speech variant's folder.
    func testAShardWithNoSizeLeavesTheCandidatesTotalUnknownRatherThanAnUndercount() {
        let siblings = [
            HuggingFaceSibling(rfilename: "Q4_K_M/model-00001-of-00002.gguf", size: 1_000),
            HuggingFaceSibling(rfilename: "Q4_K_M/model-00002-of-00002.gguf", size: nil),
        ]

        let result = ModelClassifier.classify(siblings: siblings, requiredBundles: requiredBundles)

        guard case .refinerOnly(let candidates) = result else {
            return XCTFail("expected .refinerOnly, got \(result)")
        }
        XCTAssertNil(candidates.first?.bytes)
    }

    private func speechVariant(_ name: String, eachFileBytes: Int64) -> [HuggingFaceSibling] {
        ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].map {
            HuggingFaceSibling(rfilename: "\(name)/\($0)/weights/weight.bin", size: eachFileBytes)
        }
    }

    // MARK: - Real fixtures

    private func fixture(_ name: String) throws -> HuggingFaceModelInfo {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture \(name).json")
            return HuggingFaceModelInfo(siblings: [])
        }
        return try JSONDecoder().decode(HuggingFaceModelInfo.self, from: Data(contentsOf: url))
    }

    /// `argmaxinc/whisperkit-coreml`, 2026-09-05, `blobs=true` -- the real repository this app
    /// downloads its shipped default from. The 27 pinned here are every top-level folder in that
    /// fixture holding all three required bundles, cross-checked by hand against the fixture file
    /// itself rather than merely repeating whatever this run of the classifier happens to produce.
    func testArgmaxWhisperkitCoremlClassifiesAsSpeechWithTheExpectedVariants() throws {
        let info = try fixture("argmaxinc-whisperkit-coreml")

        let result = ModelClassifier.classify(siblings: info.siblings, requiredBundles: requiredBundles)

        guard case .speechOnly(let candidates) = result else {
            return XCTFail("expected .speechOnly, got \(result)")
        }
        XCTAssertEqual(
            Set(candidates.map(\.variant)),
            [
                "distil-whisper_distil-large-v3", "distil-whisper_distil-large-v3_594MB",
                "distil-whisper_distil-large-v3_turbo", "distil-whisper_distil-large-v3_turbo_600MB",
                "openai_whisper-base", "openai_whisper-base.en",
                "openai_whisper-large-v2", "openai_whisper-large-v2_949MB",
                "openai_whisper-large-v2_turbo", "openai_whisper-large-v2_turbo_955MB",
                "openai_whisper-large-v3", "openai_whisper-large-v3-v20240930",
                "openai_whisper-large-v3-v20240930_547MB", "openai_whisper-large-v3-v20240930_626MB",
                "openai_whisper-large-v3-v20240930_turbo", "openai_whisper-large-v3-v20240930_turbo_632MB",
                "openai_whisper-large-v3_947MB", "openai_whisper-large-v3_turbo",
                "openai_whisper-large-v3_turbo_954MB", "openai_whisper-medium", "openai_whisper-medium.en",
                "openai_whisper-small", "openai_whisper-small.en", "openai_whisper-small.en_217MB",
                "openai_whisper-small_216MB", "openai_whisper-tiny", "openai_whisper-tiny.en",
            ])
    }

    /// `superwhisper/s1-mini-GGUF`, 2026-09-05 -- a real refiner repository, no speech bundles at
    /// all, with `Q4_K_M` among its quantisations even though the file itself is lower-case.
    func testSuperwhisperS1MiniGGUFClassifiesAsRefinerWithQ4KMAmongTheQuants() throws {
        let info = try fixture("superwhisper-s1-mini-gguf")

        let result = ModelClassifier.classify(siblings: info.siblings, requiredBundles: requiredBundles)

        guard case .refinerOnly(let candidates) = result else {
            return XCTFail("expected .refinerOnly, got \(result)")
        }
        XCTAssertTrue(candidates.map(\.tag).contains("Q4_K_M"), candidates.map(\.tag).description)
    }

    /// `XHToken/Spark-X2.5-4B`, 2026-09-05 -- five safetensors shards, no GGUF, no CoreML: the
    /// repository Louis actually tried to add and the one neither engine can run.
    func testXHTokenSparkClassifiesAsNotRunnableWithSafetensors() throws {
        let info = try fixture("xhtoken-spark-x2.5-4b")

        let result = ModelClassifier.classify(siblings: info.siblings, requiredBundles: requiredBundles)

        guard case .notRunnable(_, let hasSafetensors) = result else {
            return XCTFail("expected .notRunnable, got \(result)")
        }
        XCTAssertTrue(hasSafetensors)
    }

    // MARK: - Search suggestions

    func testSearchSuggestionsReadsTheIdField() {
        let json = """
            [{"id": "owner/repo-GGUF", "likes": 1}, {"id": "another/one", "likes": 0}]
            """.data(using: .utf8)!

        XCTAssertEqual(ModelClassifier.searchSuggestions(from: json), ["owner/repo-GGUF", "another/one"])
    }

    func testSearchSuggestionsIsEmptyRatherThanCrashingOnGarbage() {
        XCTAssertEqual(ModelClassifier.searchSuggestions(from: Data("not json".utf8)), [])
    }
}

/// `GGUFQuantization.tag(fromFilename:)` proved against the two separators real repositories use
/// (a hyphen, a dot) and the shapes it must refuse.
final class GGUFQuantizationTests: XCTestCase {
    func testAHyphenSeparatedLowercaseQuantIsReadAndUppercased() {
        XCTAssertEqual(GGUFQuantization.tag(fromFilename: "s1-mini-q4_k_m.gguf"), "Q4_K_M")
    }

    func testADotSeparatedQuantIsReadAcrossTheDot() {
        XCTAssertEqual(GGUFQuantization.tag(fromFilename: "Meta-Llama-3-8B-Instruct.Q4_K_M.gguf"), "Q4_K_M")
    }

    func testAnIQuantIsRecognised() {
        XCTAssertEqual(GGUFQuantization.tag(fromFilename: "model-IQ4_XS.gguf"), "IQ4_XS")
    }

    func testAnUnquantisedStorageFormatIsRecognised() {
        XCTAssertEqual(GGUFQuantization.tag(fromFilename: "s1-mini-f16.gguf"), "F16")
    }

    func testANonGGUFFileHasNoTag() {
        XCTAssertNil(GGUFQuantization.tag(fromFilename: "model.safetensors"))
    }

    func testAGGUFFileWithNoRecognisableQuantHasNoTag() {
        XCTAssertNil(GGUFQuantization.tag(fromFilename: "model.gguf"))
    }

    // MARK: - Sharded repositories: the quant lives on the folder, not every shard's own name

    /// The regression this fixes: reading the WHOLE `rfilename` (a Hugging Face listing's path,
    /// folder included) as one string used to let `Q4_K_M/model` -- the folder plus the generic
    /// shard name, still one segment because `/` was never a split point -- pass
    /// `looksLikeQuantisation` on its own (`Q` + a digit), producing the tag `Q4_K_M/MODEL`,
    /// which is not anything Ollama's `hf.co/` pull would ever resolve.
    func testAQuantFolderNameDoesNotLeakIntoTheTagAsPartOfTheFilename() {
        XCTAssertEqual(
            GGUFQuantization.tag(fromFilename: "Q4_K_M/model-00001-of-00002.gguf"), "Q4_K_M",
            "the folder is read as the fallback, not concatenated onto a mangled basename")
    }

    /// The other half of the same fix: when the basename genuinely has no quant token, the
    /// enclosing folder is used instead -- the real shape a sharded repository publishes
    /// (`Q4_K_M/model-00001-of-00002.gguf`, `Q4_K_M/model-00002-of-00002.gguf`).
    func testFallsBackToTheParentFolderWhenTheBasenameCarriesNoQuantToken() {
        XCTAssertEqual(
            GGUFQuantization.tag(fromFilename: "Q4_K_M/model-00002-of-00002.gguf"), "Q4_K_M")
    }

    /// The basename's own tag wins when it has one, even nested under a folder that also looks
    /// like a quantisation -- the fallback must only ever fire when the basename has nothing.
    func testTheBasenamesOwnTagTakesPriorityOverTheParentFolder() {
        XCTAssertEqual(
            GGUFQuantization.tag(fromFilename: "Q4_K_M/s1-mini-q8_0.gguf"), "Q8_0")
    }

    /// A shard with no quant anywhere -- basename or folder -- still has nothing to offer.
    func testAParentFolderThatDoesNotLookLikeAQuantIsNotUsedAsAFallback() {
        XCTAssertNil(GGUFQuantization.tag(fromFilename: "extra/model-00001-of-00002.gguf"))
    }
}
