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

    /// What one of the two group lists shows, the same way the pane computes it: this group's own
    /// slice of the loaded entries decides `hasEntries`, not the whole file.
    private func state(for group: VocabularyGroup = .wordsToRecognise) -> VocabularyEmptyState? {
        let loaded = load()
        return VocabularyEmptyState.current(
            problem: loaded.problem,
            hasEntries: !group.entries(in: loaded.entries).isEmpty,
            group: group)
    }

    // MARK: - VocabularyGroup's own split

    func testWordsToRecogniseIsEntriesWithNoReplacement() {
        let entries = [
            VocabularyEntry(term: "Trucost"),
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
        ]
        XCTAssertEqual(
            VocabularyGroup.wordsToRecognise.entries(in: entries), [VocabularyEntry(term: "Trucost")])
    }

    func testCorrectionsIsEntriesWithAReplacement() {
        let entries = [
            VocabularyEntry(term: "Trucost"),
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
        ]
        XCTAssertEqual(
            VocabularyGroup.corrections.entries(in: entries),
            [VocabularyEntry(term: "cloud code", replacement: "Claude Code")])
    }

    func testSplittingPreservesTheOrderOfTheInputRatherThanResorting() {
        // Already alphabetised, the way the pane hands it in -- the split must not shuffle it.
        let entries = [
            VocabularyEntry(term: "Alpha"),
            VocabularyEntry(term: "Zulu"),
        ]
        XCTAssertEqual(VocabularyGroup.wordsToRecognise.entries(in: entries), entries)
    }

    // MARK: - headingWithCount(_:) -- the pane's section header

    func testHeadingWithCountJoinsTheHeadingAndTheCountWithAMiddleDot() {
        XCTAssertEqual(VocabularyGroup.wordsToRecognise.headingWithCount(12), "Words to recognise · 12")
        XCTAssertEqual(VocabularyGroup.corrections.headingWithCount(0), "Corrections · 0")
    }

    // MARK: - composerTitle -- the segmented picker's own label, singular unlike `heading`

    func testComposerTitleIsSingularUnlikeTheListHeading() {
        XCTAssertEqual(VocabularyGroup.wordsToRecognise.composerTitle, "Word to recognise")
        XCTAssertEqual(VocabularyGroup.corrections.composerTitle, "Correction")
    }

    // MARK: - subtitle -- reused by the section header AND by "nothing yet" below

    /// Each group's subtitle talks about what THAT group's own list does, the same split
    /// `testWordsToRecogniseEmptyStateTalksOnlyAboutBiasingWhatIsHeard` checks on the composed
    /// sentence below -- checked here on the fragment itself since the section header draws it
    /// directly, with no "No words yet." in front of it.
    func testWordsToRecogniseSubtitleTalksOnlyAboutBiasingWhatIsHeard() {
        let subtitle = VocabularyGroup.wordsToRecognise.subtitle
        XCTAssertTrue(subtitle.contains("guides what Whisper hears"), subtitle)
        XCTAssertFalse(subtitle.contains("corrects"), subtitle)
    }

    func testCorrectionsSubtitleTalksOnlyAboutFixingTheTranscript() {
        let subtitle = VocabularyGroup.corrections.subtitle
        XCTAssertTrue(subtitle.contains("fixes it"), subtitle)
        XCTAssertFalse(subtitle.contains("guides what Whisper hears"), subtitle)
    }

    /// The refactor this guards: `VocabularyEmptyState`'s "nothing yet" sentence must not restate
    /// the group's own wording, it must fold `subtitle` in whole -- so the two never drift into
    /// two descriptions of the same group. Mutation-proof: rewording either `subtitle` case breaks
    /// this assertion, not just the section header.
    func testNothingYetFoldsInTheGroupsOwnSubtitleRatherThanRestatingIt() {
        XCTAssertTrue(
            VocabularyEmptyState.nothingYet(.wordsToRecognise).description
                .hasSuffix(VocabularyGroup.wordsToRecognise.subtitle))
        XCTAssertTrue(
            VocabularyEmptyState.nothingYet(.corrections).description
                .hasSuffix(VocabularyGroup.corrections.subtitle))
    }

    // MARK: - Parse failures are not scoped to one group

    /// The failure this type exists for. Given a `vocabulary.json` that will not parse, when the
    /// pane draws an empty list, then it says the file could not be read -- not that there are no
    /// words, which would invite Louis to type back in the ones he already has.
    func testAVocabularyThatWillNotParseSaysSoRatherThanSayingThereAreNoWords() throws {
        try Data(#"[{"term": "Murmure"},"#.utf8).write(to: fileURL)

        let message = state()?.description

        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("vocabulary.json"), message!)
        XCTAssertFalse(message!.contains("No words yet"), message!)
    }

    /// The same broken file says the same thing under the OTHER group too -- a parse failure
    /// costs the whole load, so it is not a "words" problem or a "corrections" problem, it is a
    /// file problem either group can ask about.
    func testTheSameParseFailureShowsUnderEitherGroup() throws {
        try Data(#"[{"term": "Murmure"},"#.utf8).write(to: fileURL)

        XCTAssertEqual(state(for: .wordsToRecognise), state(for: .corrections))
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

    // MARK: - The ordinary empty state, per group

    /// A file that has never been created is a fresh install, which `VocabularyStore` reports
    /// nothing about on purpose. Each group says the ordinary thing, in its own words.
    func testNoVocabularyFileAtAllIsTheOrdinaryEmptyStateForBothGroups() {
        XCTAssertEqual(state(for: .wordsToRecognise), .nothingYet(.wordsToRecognise))
        XCTAssertEqual(state(for: .corrections), .nothingYet(.corrections))
    }

    func testAnEmptyVocabularyFileIsTheSameOrdinaryEmptyState() throws {
        try Data("[]".utf8).write(to: fileURL)

        XCTAssertEqual(state(for: .wordsToRecognise), .nothingYet(.wordsToRecognise))
    }

    /// A vocabulary that is all bare terms leaves Corrections legitimately empty, with nothing
    /// wrong with the file -- the ordinary "nothing of this kind yet" sentence, not a problem.
    func testAGroupWithNoEntriesOfItsOwnKindIsOrdinaryNotAFailure() throws {
        try Data(#"[{"term": "Murmure"}]"#.utf8).write(to: fileURL)

        XCTAssertEqual(state(for: .corrections), .nothingYet(.corrections))
        XCTAssertNil(state(for: .wordsToRecognise), "Words to recognise has an entry to show")
    }

    /// Each group's empty sentence says what THIS group's own list does, not what a vocabulary
    /// entry as a whole can do -- the two are drawn apart precisely so this does not conflate.
    func testWordsToRecogniseEmptyStateTalksOnlyAboutBiasingWhatIsHeard() {
        let message = VocabularyEmptyState.nothingYet(.wordsToRecognise).description

        XCTAssertTrue(message.contains("guides what Whisper hears"), message)
        XCTAssertFalse(message.contains("corrects"), message)
    }

    func testCorrectionsEmptyStateTalksOnlyAboutFixingTheTranscript() {
        let message = VocabularyEmptyState.nothingYet(.corrections).description

        XCTAssertTrue(message.contains("fixes it"), message)
        XCTAssertFalse(message.contains("guides what Whisper hears"), message)
    }

    /// A problem that cost one entry may not replace the entries that loaded. Given a file whose
    /// second entry has an empty term, when the first one loaded, then there is no empty state at
    /// all and the pane lists what it has.
    func testAProblemThatCostOneEntryDoesNotReplaceTheOnesThatLoaded() throws {
        try Data(#"[{"term": "Murmure"}, {"term": "   "}]"#.utf8).write(to: fileURL)
        let loaded = load()

        let produced = VocabularyEmptyState.current(
            problem: loaded.problem,
            hasEntries: !VocabularyGroup.wordsToRecognise.entries(in: loaded.entries).isEmpty,
            group: .wordsToRecognise)

        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertNotNil(loaded.problem, "the skipped entry was reported")
        XCTAssertNil(produced)
    }
}
