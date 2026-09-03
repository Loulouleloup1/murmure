import XCTest
@testable import MurmureCore

/// Every test writes its own `vocabulary.json` under `NSTemporaryDirectory()` and removes it
/// again. Nothing here may reach `~/Library/Application Support/Murmure/vocabulary.json`, which
/// is Louis's real, hand-edited file.
///
/// The failing cases go through `VocabularyStore.loadAll()` against a real malformed file rather
/// than constructing a `VocabularyLoadProblem`: what this type promises is that a file which will
/// not parse produces a sentence about the file, and only the store can say which problem a given
/// piece of broken JSON actually reports.
final class VocabularyEmptyStateTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VocabularyEmptyStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("vocabulary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Loads the file as the pane does, and hands back both halves of what the pane then has: the
    /// entries it got, and the last problem the store reported while getting them.
    private func load() -> (entries: [VocabularyEntry], problem: VocabularyLoadProblem?) {
        var reported: VocabularyLoadProblem?
        let entries = VocabularyStore(fileURL: fileURL) { reported = $0 }.loadAll()
        return (entries, reported)
    }

    private func state() -> VocabularyEmptyState? {
        let loaded = load()
        return VocabularyEmptyState.current(
            problem: loaded.problem, hasEntries: !loaded.entries.isEmpty)
    }

    /// The failure this type exists for. Given a `vocabulary.json` that will not parse, when the
    /// pane draws an empty list, then it says the file could not be read -- not that there are no
    /// words, which would invite Louis to type back in the ones he already has.
    func testAVocabularyThatWillNotParseSaysSoRatherThanSayingThereAreNoWords() throws {
        try Data(#"[{"term": "Murmure"},"#.utf8).write(to: fileURL)

        let message = state()?.description

        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("vocabulary.json"), message!)
        XCTAssertFalse(message!.contains("No vocabulary yet"), message!)
    }

    /// The message is `VocabularyLoadProblem`'s own, not a second wording of it: one failure, one
    /// sentence, wherever it is shown.
    func testTheParseFailureKeepsTheStoresOwnWords() throws {
        try Data(#"{"term": "Murmure"}"#.utf8).write(to: fileURL)
        let problem = load().problem

        let message = state()?.description

        XCTAssertNotNil(problem)
        XCTAssertEqual(message, problem?.description)
    }

    /// A file that has never been created is a fresh install, which `VocabularyStore` reports
    /// nothing about on purpose. The pane says the ordinary thing.
    func testNoVocabularyFileAtAllIsTheOrdinaryEmptyState() {
        XCTAssertEqual(state(), .nothingYet)
    }

    func testAnEmptyVocabularyFileIsTheSameOrdinaryEmptyState() throws {
        try Data("[]".utf8).write(to: fileURL)

        XCTAssertEqual(state(), .nothingYet)
    }

    /// The empty sentence says what the two halves of an entry do, because an empty pane with one
    /// input row above it does not.
    func testTheOrdinaryEmptyStateSaysWhatAWordAddedHereWouldDo() {
        let message = VocabularyEmptyState.nothingYet.description

        XCTAssertTrue(message.contains("guides what Whisper hears"), message)
        XCTAssertTrue(message.contains("corrects the text afterwards"), message)
    }

    /// A problem that cost one entry may not replace the entries that loaded. Given a file whose
    /// second entry has an empty term, when the first one loaded, then there is no empty state at
    /// all and the pane lists what it has.
    func testAProblemThatCostOneEntryDoesNotReplaceTheOnesThatLoaded() throws {
        try Data(#"[{"term": "Murmure"}, {"term": "   "}]"#.utf8).write(to: fileURL)
        let loaded = load()

        let produced = VocabularyEmptyState.current(
            problem: loaded.problem, hasEntries: !loaded.entries.isEmpty)

        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertNotNil(loaded.problem, "the skipped entry was reported")
        XCTAssertNil(produced)
    }
}
