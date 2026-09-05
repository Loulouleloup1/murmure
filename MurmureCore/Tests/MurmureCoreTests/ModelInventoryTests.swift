import XCTest
@testable import MurmureCore

/// The Models table's speech half, proved against real directory trees.
///
/// Every tree below is built in a fresh temporary directory whose shape is copied from the
/// installed one -- `models/models/argmaxinc/whisperkit-coreml/<variant>/` with the Hub's
/// `.cache/huggingface/download/<variant>/` beside it. Nothing here reads or writes
/// `~/Library/Application Support/Murmure/models`, which holds Louis's real 1.5 GB.
///
/// The tests assert the rows a table would draw, not that a function returns an array: what is at
/// stake in this file is a half-downloaded model that reads as installed, and that defect is
/// invisible to any assertion that does not describe a specific tree.
final class ModelInventoryTests: XCTestCase {
    private var store: URL!
    private let manager = FileManager.default

    private let descriptor = SpeechModelDescriptor(
        repository: "argmaxinc/whisperkit-coreml",
        variant: "openai_whisper-large-v3-v20240930_turbo",
        expectedBytes: ModelDownload.transcriptionModelBytes)

    override func setUpWithError() throws {
        store = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelInventoryTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: store)
    }

    // MARK: - Building trees

    private var variantURL: URL { ModelInventory.variant(for: descriptor, in: store) }
    private var cacheURL: URL { ModelInventory.cache(for: descriptor, in: store) }

    private func write(_ bytes: Int, to url: URL) throws {
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2E, count: bytes).write(to: url)
    }

    /// A complete store: the three bundles `WhisperKitEngine` requires, each with a weights file,
    /// and one `.metadata` sidecar per file in the cache. No `.incomplete` anywhere -- the Hub
    /// moves that file onto its destination when the transfer ends.
    ///
    /// The three names are **written out rather than read from `ModelInventory.requiredBundles`**,
    /// and that is the opposite decision to the one taken in the engine. A fixture built from the
    /// constant under test describes whatever that constant currently says: drop a name from it
    /// and the fixture stops writing that bundle too, so the model on disk would go on matching
    /// the rule however lax the rule became, and `testAModelMissingARequiredBundleIsNotInstalled`
    /// would stay green while the thing it guards disappeared. The tree here is the real one,
    /// copied from the installed store, and it has to stay an independent description of it.
    private func writeCompleteModel() throws {
        try write(120, to: variantURL.appendingPathComponent("config.json"))
        for bundle in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            let folder = variantURL.appendingPathComponent(bundle)
            try write(60, to: folder.appendingPathComponent("coremldata.bin"))
            try write(1_000, to: folder.appendingPathComponent("weights/weight.bin"))
            try write(20, to: cacheURL.appendingPathComponent("\(bundle)/weights/weight.bin.metadata"))
        }
    }

    private func row() -> ModelRow {
        ModelInventory.speechRow(for: descriptor, in: store, fileManager: manager)
    }

    // MARK: - Where the model store is

    /// The extra `models/` level is the Hub's, not a typo: `localRepoLocation` is
    /// `downloadBase / models / <repo id>`, which is why the installed tree reads
    /// `Murmure/models/models/argmaxinc/...`.
    func testTheRepositoryPathCarriesTheHubsExtraModelsLevel() {
        let repository = ModelInventory.repository(for: descriptor, in: store)

        XCTAssertEqual(
            repository.path,
            store.path + "/models/argmaxinc/whisperkit-coreml")
        XCTAssertEqual(
            variantURL.path,
            store.path + "/models/argmaxinc/whisperkit-coreml/"
                + "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(
            cacheURL.path,
            store.path + "/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/"
                + "openai_whisper-large-v3-v20240930_turbo")
    }

    // MARK: - A model that is there

    func testACompleteModelIsInstalledAndOffersDelete() throws {
        try writeCompleteModel()

        let row = row()

        XCTAssertEqual(row.installation, .installed(bytes: 3_360))
        XCTAssertEqual(row.action, .delete)
        XCTAssertEqual(row.kind, .speech)
        // The full reference, not the bare variant: Louis asked for the Hugging Face structure to
        // show, and a speech row's name is no longer put through `ModelDisplayName.readable`'s
        // last-slash strip the way a language row's still is.
        XCTAssertEqual(row.name, "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo")
        XCTAssertNil(row.detail, "an installed model has nothing to explain")
        XCTAssertEqual(row.size, "3 kB")
    }

    // MARK: - A model that is half there

    /// The defect this file exists for, in the exact shape the disk produces it: the download was
    /// killed while fetching the encoder's weights. The folder `AudioEncoder.mlmodelc` is there,
    /// holding its small files; 1.2 GB of the 1.6 is not. Every existence check calls this
    /// installed. The `.incomplete` file the Hub creates before the first byte is what refuses to.
    func testAModelInterruptedMidTransferIsNotInstalled() throws {
        try writeCompleteModel()
        try manager.removeItem(
            at: variantURL.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin"))
        try write(
            400,
            to: cacheURL.appendingPathComponent(
                "AudioEncoder.mlmodelc/weights/weight.bin.a1b2c3.incomplete"))

        let row = row()

        XCTAssertEqual(
            row.installation,
            .partiallyDownloaded(bytes: 2_760, expected: ModelDownload.transcriptionModelBytes))
        XCTAssertEqual(row.action, .download, "the button that finishes it, not the one that frees it")
        XCTAssertEqual(row.detail, "Incomplete -- 3 kB of 1.6 GB on disk.")
    }

    /// The other interruption: the process died between two files, so nothing is `.incomplete`
    /// and a whole bundle is simply missing. Caught by the second condition -- the three bundles
    /// `WhisperKitEngine.cachedModelFolder` requires before it dares skip the Hub.
    func testAModelMissingARequiredBundleIsNotInstalled() throws {
        try writeCompleteModel()
        try manager.removeItem(at: variantURL.appendingPathComponent("TextDecoder.mlmodelc"))

        XCTAssertEqual(
            row().installation,
            .partiallyDownloaded(bytes: 2_300, expected: ModelDownload.transcriptionModelBytes))
    }

    /// A reference nothing has measured a size for in advance (the `speechRow(for: reference:)`
    /// overload's default) drops the "of X" clause entirely rather than print it against `0` --
    /// `"Incomplete -- 3 kB of 0 B on disk."` would read as a download that is somehow both in
    /// progress and already finished.
    func testAPartialModelWithNoExpectedSizeOmitsTheOfClause() throws {
        try writeCompleteModel()
        try manager.removeItem(at: variantURL.appendingPathComponent("TextDecoder.mlmodelc"))

        let row = ModelInventory.speechRow(for: descriptor.reference, in: store, fileManager: manager)

        XCTAssertEqual(row.installation, .partiallyDownloaded(bytes: 2_300, expected: nil))
        XCTAssertNil(row.size, "no number was ever measured for this reference")
        XCTAssertEqual(row.detail, "Incomplete -- 2 kB on disk.")
    }

    /// A bundle whose weights are gone but whose folder is there reads as installed, and that is
    /// the intended limit of the rule rather than a hole in it: the engine's own pre-filter
    /// accepts the same folder, and what discovers the corruption is the load, which
    /// `WhisperKitEngine` already answers by going back to the Hub. A table that was stricter
    /// than the engine would offer a download for a model the app loads fine.
    ///
    /// The agreement between the two is no longer asserted here, because it can no longer be
    /// asserted honestly: `WhisperKitEngine.cachedModelFolder` now reads
    /// `ModelInventory.requiredBundles` itself, so there is one list and the compiler holds it.
    /// The test that used to sit here compared that constant to a third copy typed into this
    /// file -- it could only fail if someone edited the constant, never if the engine drifted,
    /// which is the one thing it claimed to catch.
    func testABundleMissingItsWeightsStillReadsAsInstalled() throws {
        try writeCompleteModel()
        try manager.removeItem(
            at: variantURL.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin"))

        XCTAssertEqual(row().installation, .installed(bytes: 2_360))
    }

    // MARK: - A model that is not there

    func testAnAbsentStoreOffersTheDownloadAndItsSize() {
        let row = row()

        XCTAssertEqual(row.installation, .absent)
        XCTAssertEqual(row.action, .download)
        XCTAssertEqual(row.detail, "Not downloaded.")
        XCTAssertEqual(row.size, "1.6 GB", "the size column carries what the download will cost")
    }

    /// An empty leftover folder is nothing on disk: there is no transfer to resume and no byte to
    /// free, so it reads exactly like a store that was never created.
    func testAnEmptyVariantFolderReadsAsAbsentRatherThanPartial() throws {
        try manager.createDirectory(at: variantURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        XCTAssertEqual(row().installation, .absent)
        XCTAssertEqual(row().action, .download)
    }

    /// A transfer that has only just started: the destination file has not been moved into place
    /// yet, so the variant folder does not exist at all -- and this is still not `absent`,
    /// because the `.incomplete` file says a download is in flight.
    func testATransferThatHasWrittenNothingYetIsPartialAndNotAbsent() throws {
        try write(64, to: cacheURL.appendingPathComponent("config.json.deadbeef.incomplete"))

        XCTAssertEqual(
            row().installation,
            .partiallyDownloaded(bytes: 64, expected: ModelDownload.transcriptionModelBytes))
    }

    // MARK: - What is actually installed, found by walking the store

    /// The real tree, verified: `writeCompleteModel()` builds exactly the layout
    /// `~/Library/Application Support/Murmure/models/models/argmaxinc/whisperkit-coreml/<variant>/`
    /// carries on the installed machine, and the walk has to find it two levels down.
    func testInstalledSpeechModelsFindsAModelTwoLevelsUnderTheRepositorySplit() throws {
        try writeCompleteModel()

        XCTAssertEqual(ModelInventory.installedSpeechModels(in: store, fileManager: manager), [descriptor.reference])
    }

    /// The repository's own `.cache` directory sits at the same level as a variant folder and
    /// must not be mistaken for one -- it never holds `requiredBundles`, so it is discarded by the
    /// ordinary check rather than by name.
    func testInstalledSpeechModelsSkipsTheCacheDirectory() throws {
        try writeCompleteModel()

        let found = ModelInventory.installedSpeechModels(in: store, fileManager: manager)

        XCTAssertFalse(found.contains { $0.variant == ".cache" })
        XCTAssertEqual(found, [descriptor.reference])
    }

    /// A half-downloaded variant is not "actually installed" -- the same rule `speechRow` applies,
    /// asked from the other direction: a walk that returned it would offer a picker item for a
    /// model that cannot transcribe a word.
    func testInstalledSpeechModelsExcludesAPartiallyDownloadedVariant() throws {
        try writeCompleteModel()
        try manager.removeItem(at: variantURL.appendingPathComponent("TextDecoder.mlmodelc"))

        XCTAssertEqual(ModelInventory.installedSpeechModels(in: store, fileManager: manager), [])
    }

    /// Two repositories, two variants -- proving the two-level walk does not stop at the first
    /// repository it finds, and that it sorts rather than depending on directory order.
    func testInstalledSpeechModelsFindsModelsAcrossRepositoriesSortedByOwnerThenName() throws {
        try writeCompleteModel()
        let second = SpeechModelDescriptor(
            repository: "someowner/somerepo", variant: "some-variant", expectedBytes: 100)
        for bundle in ModelInventory.requiredBundles {
            try write(10, to: ModelInventory.variant(for: second, in: store).appendingPathComponent(bundle))
        }

        XCTAssertEqual(
            ModelInventory.installedSpeechModels(in: store, fileManager: manager),
            [descriptor.reference, second.reference])
    }

    /// A store that has never downloaded anything -- or a fixture that only builds part of a tree
    /// -- is not a broken store; it has nothing installed yet.
    func testInstalledSpeechModelsIsEmptyForAStoreThatDoesNotExist() {
        XCTAssertEqual(ModelInventory.installedSpeechModels(in: store, fileManager: manager), [])
    }

    // MARK: - Deleting

    /// Two directories, and never the repository root: a store holding a second variant would
    /// lose it, and the row that was pressed named one model.
    func testRemovalTakesTheVariantAndItsCacheAndNotTheRepository() {
        let removal = ModelInventory.removal(for: descriptor, in: store)

        XCTAssertEqual(removal.directories, [variantURL, cacheURL])
        XCTAssertFalse(
            removal.directories.contains(ModelInventory.repository(for: descriptor, in: store)))
        XCTAssertTrue(removal.question.contains("1.6 GB"), removal.question)
        XCTAssertTrue(
            removal.question.contains("openai_whisper-large-v3-v20240930_turbo"), removal.question)
    }

    /// A different question, not a footnote to the same one: deleting a model a mode still names
    /// costs that same mode a redownload before its next dictation can run (not a silent
    /// substitution -- `WhisperKitEngine.load` only does that for a reference the Hub has never
    /// heard of), and the confirmation is the one place that can say it before it happens.
    func testDeletingAModelNamedByAModeWarnsItWillRedownload() {
        let removal = ModelInventory.removal(for: descriptor, in: store, namedByModes: ["Voice"])

        XCTAssertTrue(removal.question.contains("Voice"), removal.question)
        XCTAssertTrue(removal.question.contains("redownload"), removal.question)
        XCTAssertTrue(removal.question.contains("names it"), removal.question)
    }

    func testDeletingAModelNamedByTwoModesUsesThePluralVerb() {
        let removal = ModelInventory.removal(
            for: descriptor, in: store, namedByModes: ["Voice", "Prompt"])

        XCTAssertTrue(removal.question.contains("Voice, Prompt"), removal.question)
        XCTAssertTrue(removal.question.contains("name it"), removal.question)
    }

    /// The unused-model question is unchanged when nothing names it -- the default parameter must
    /// not silently alter the sentence every existing caller already reads.
    func testDeletingAModelNamedByNoModeAsksTheOriginalQuestion() {
        let removal = ModelInventory.removal(for: descriptor, in: store, namedByModes: [])

        XCTAssertFalse(removal.question.contains("redownload"), removal.question)
    }

    // MARK: - Which modes name a reference

    /// `descriptor.reference` is `SpeechModelReference.shippedDefault`, so it doubles as the
    /// engine default every one of these tests resolves against.
    private var defaultReference: SpeechModelReference { descriptor.reference }

    func testModesNamingReturnsOnlyTheModesThatResolveToThisReference() {
        let modes = [
            mode(key: "voice", enabled: false, model: "never-run:7b", endpoint: "http://localhost:11434"),
            mode(key: "other", enabled: true, model: "gemma4:12b", endpoint: "http://localhost:11434"),
        ]
        var voice = modes[0]
        voice.stt.model = "openai_whisper-large-v3-v20240930_turbo"
        var other = modes[1]
        other.stt.model = "some-other-variant"

        XCTAssertEqual(
            ModelInventory.modesNaming(
                reference: defaultReference, in: [voice, other], engineDefault: defaultReference),
            ["voice"])
    }

    /// The common case: a mode's stored field is blank or the shipped alias, which resolves to the
    /// engine default rather than matching literally.
    func testModesNamingResolvesTheShippedAliasToTheEngineDefault() {
        var mode = mode(key: "voice", enabled: false, model: "x", endpoint: "http://localhost:11434")
        mode.stt.model = "large-v3-turbo"

        XCTAssertEqual(
            ModelInventory.modesNaming(reference: defaultReference, in: [mode], engineDefault: defaultReference),
            ["voice"])
    }

    func testModesNamingIsEmptyWhenNoModeResolvesToTheReference() {
        var mode = mode(key: "voice", enabled: false, model: "x", endpoint: "http://localhost:11434")
        mode.stt.model = "a-completely-different-variant"

        XCTAssertEqual(
            ModelInventory.modesNaming(reference: defaultReference, in: [mode], engineDefault: defaultReference),
            [])
    }

    // MARK: - The first-use notice

    func testAnInstalledModelThatIsNotKnownWarmCarriesTheFirstUseNotice() throws {
        try writeCompleteModel()

        let row = ModelInventory.speechRow(for: descriptor, in: store, fileManager: manager, knownWarm: false)

        XCTAssertNotNil(row.firstUseNotice)
        XCTAssertTrue(row.firstUseNotice?.contains("minutes") == true, row.firstUseNotice ?? "")
    }

    func testAnInstalledModelKnownWarmCarriesNoFirstUseNotice() throws {
        try writeCompleteModel()

        let row = ModelInventory.speechRow(for: descriptor, in: store, fileManager: manager, knownWarm: true)

        XCTAssertNil(row.firstUseNotice)
    }

    /// The notice describes a wait after installing, not a wait instead of downloading -- it has
    /// nothing to say about a model that is not there yet.
    func testAnAbsentModelCarriesNoFirstUseNoticeEvenWhenNotKnownWarm() {
        let row = ModelInventory.speechRow(for: descriptor, in: store, fileManager: manager, knownWarm: false)

        XCTAssertNil(row.firstUseNotice)
    }

    // MARK: - The pull action

    func testAnAbsentLanguageRowOffersToPull() {
        let row = ModelRow(identifier: "gemma4:12b", kind: .language, installation: .absent)

        XCTAssertEqual(row.action, .pull)
    }

    func testAnInstalledLanguageRowIsManagedElsewhereNotPull() {
        let row = ModelRow(identifier: "gemma4:12b", kind: .language, installation: .installed(bytes: 100))

        XCTAssertEqual(row.action, .managedElsewhere)
    }

    // MARK: - The two halves of the table

    func testSpeechRowsComeFirstAndLanguageRowsAreSortedByName() {
        let speech = ModelRow(identifier: "whisper", kind: .speech, installation: .absent)
        let language = [
            ModelRow(identifier: "hf.co/user/zephyr:q4", kind: .language, installation: .absent),
            ModelRow(identifier: "gemma4:12b-it-qat", kind: .language, installation: .absent),
        ]

        let table = ModelInventory.table(speech: [speech], language: language)

        XCTAssertEqual(table.map(\.name), ["whisper", "gemma4:12b-it-qat", "zephyr:q4"])
    }

    // MARK: - Which language models the table shows

    private func mode(key: String, enabled: Bool, model: String, endpoint: String) -> Mode {
        Mode(
            key: key, name: key, hotkey: nil,
            stt: .init(model: "large-v3", language: "fr"),
            llm: .init(enabled: enabled, endpoint: endpoint, model: model),
            instructions: "", context: .init(selectedText: false, clipboard: false, appContext: false),
            autoActivate: [], simulateKeypresses: false)
    }

    /// A mode with refinement off still names a model in its file -- every built-in does. Listing
    /// those would fill the table with models Louis never runs.
    func testOnlyTheModelsOfModesThatActuallyRefineAreListed() {
        let modes = [
            mode(key: "prompt", enabled: true, model: "gemma4:12b", endpoint: "http://localhost:11434"),
            mode(key: "raw", enabled: false, model: "never-run:7b", endpoint: "http://localhost:11434"),
        ]

        XCTAssertEqual(
            ModelInventory.languageModels(in: modes),
            [.init(identifier: "gemma4:12b", endpoint: "http://localhost:11434")])
    }

    /// Deduplicated on the pair: the same model on two servers is two probes, and they can
    /// legitimately answer differently.
    func testTheSameModelOnTwoEndpointsIsTwoRowsAndOnOneEndpointIsOne() {
        let modes = [
            mode(key: "a", enabled: true, model: "gemma4:12b", endpoint: "http://localhost:11434"),
            mode(key: "b", enabled: true, model: "gemma4:12b", endpoint: "http://localhost:11434"),
            mode(key: "c", enabled: true, model: "gemma4:12b", endpoint: "http://mini.local:11434"),
        ]

        XCTAssertEqual(
            ModelInventory.languageModels(in: modes),
            [
                .init(identifier: "gemma4:12b", endpoint: "http://localhost:11434"),
                .init(identifier: "gemma4:12b", endpoint: "http://mini.local:11434"),
            ])
    }

    /// A model installed through "Add a model" rather than through a known descriptor -- nothing
    /// measured its size in advance, and the question says so honestly rather than printing a
    /// size nobody measured.
    func testRemovalWithNoExpectedBytesAsksToDownloadWithoutASize() {
        let reference = SpeechModelReference(repository: "someowner/somerepo", variant: "some-variant")

        let removal = ModelInventory.removal(for: reference, in: store, expectedBytes: nil)

        XCTAssertEqual(
            removal.directories,
            [ModelInventory.variant(for: reference, in: store), ModelInventory.cache(for: reference, in: store)])
        XCTAssertTrue(removal.question.contains("need to download it again"), removal.question)
        XCTAssertFalse(removal.question.contains(" B "), removal.question)
    }

    // MARK: - Deleting a language model

    /// The language sibling of `testRemovalTakesTheVariantAndItsCacheAndNotTheRepository`: no
    /// directories to remove -- Ollama's own store, never this app's -- but the same confirmation
    /// shape.
    func testLanguageRemovalHasNoDirectoriesAndAsksToPullAgain() {
        let removal = ModelInventory.removal(forLanguageModel: "gemma4:12b-it-qat")

        XCTAssertEqual(removal.directories, [])
        XCTAssertTrue(removal.question.contains("gemma4:12b-it-qat"), removal.question)
        XCTAssertTrue(removal.question.contains("pull it again"), removal.question)
    }

    /// There is no default refiner (unlike speech's shipped default): a mode whose model is gone
    /// inserts the raw transcript with a `RefinementNotice`, per `DictationController.refine` /
    /// `TranscriptRefiner`. The question must say that, not invent a model to fall back to.
    func testLanguageRemovalNamedByAModeWarnsItWillInsertRawText() {
        let removal = ModelInventory.removal(forLanguageModel: "gemma4:12b-it-qat", namedByModes: ["Prompt"])

        XCTAssertTrue(removal.question.contains("Prompt"), removal.question)
        XCTAssertTrue(removal.question.contains("raw transcript"), removal.question)
        XCTAssertTrue(removal.question.contains("names it"), removal.question)
    }

    func testLanguageRemovalNamedByTwoModesUsesThePluralVerb() {
        let removal = ModelInventory.removal(
            forLanguageModel: "gemma4:12b-it-qat", namedByModes: ["Voice", "Prompt"])

        XCTAssertTrue(removal.question.contains("Voice, Prompt"), removal.question)
        XCTAssertTrue(removal.question.contains("name it"), removal.question)
    }

    // MARK: - Which modes name a language model

    func testModesNamingLanguageModelMatchesOnTheTaggedIdentifier() {
        let modes = [
            mode(key: "voice", enabled: true, model: "gemma4", endpoint: "http://localhost:11434"),
            mode(key: "raw", enabled: false, model: "gemma4:12b-it-qat", endpoint: "http://localhost:11434"),
        ]

        XCTAssertEqual(
            ModelInventory.modesNaming(languageModel: "gemma4:latest", in: modes), ["voice"],
            "a mode storing the bare name still resolves to the tag Ollama's own listing spells")
    }

    func testModesNamingLanguageModelIsEmptyWhenNoEnabledModeNamesIt() {
        let modes = [
            mode(key: "raw", enabled: false, model: "gemma4:12b-it-qat", endpoint: "http://localhost:11434"),
        ]

        XCTAssertEqual(ModelInventory.modesNaming(languageModel: "gemma4:12b-it-qat", in: modes), [])
    }

    // MARK: - Sizes

    /// Base ten, like the Finder and like the README's model table: the file this app downloads
    /// is 1 638 467 188 bytes and Louis has read "1.6 GB" about it everywhere else.
    func testSizesAreWrittenTheWayTheRestOfTheAppQuotesThem() {
        XCTAssertEqual(ModelSize.readable(ModelDownload.transcriptionModelBytes), "1.6 GB")
        XCTAssertEqual(ModelSize.readable(0), "0 B")
        XCTAssertEqual(ModelSize.readable(999), "999 B")
        XCTAssertEqual(ModelSize.readable(4_600_000), "4.6 MB")
        XCTAssertEqual(ModelSize.readable(8_581_748_736), "8.6 GB")
    }
}
