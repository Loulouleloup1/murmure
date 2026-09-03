import XCTest
@testable import MurmureCore

final class VocabularyStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var problems: [VocabularyLoadProblem] = []
    private var store: VocabularyStore!

    /// Every test writes into a fresh temporary directory. Nothing here may reach
    /// `~/Library/Application Support/Murmure/vocabulary.json`, which holds Louis's real vocabulary.
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VocabularyStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("vocabulary.json")
        problems = []
        store = VocabularyStore(fileURL: fileURL) { [weak self] in self?.problems.append($0) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: fileURL)
    }

    // MARK: - Absent file

    func testAnAbsentFileIsAnEmptyVocabularyReportedAsNothing() {
        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(problems, [])
    }

    // MARK: - Loading and normalizing

    func testLoadingReadsTermsAndReplacementsBack() throws {
        try write("""
        [
          { "term": "Claude Code" },
          { "term": "cloud code", "replacement": "Claude Code" }
        ]
        """)

        XCTAssertEqual(store.loadAll(), [
            .init(term: "Claude Code"),
            .init(term: "cloud code", replacement: "Claude Code"),
        ])
        XCTAssertEqual(problems, [])
    }

    /// An empty `replacement` corrects nothing. Normalized to nil so a consumer reading
    /// `replacement ?? term` never puts an empty string into the recogniser prompt.
    func testAnEmptyReplacementIsNormalizedToNilRatherThanReported() throws {
        try write("""
        [ { "term": "murmure", "replacement": "" } ]
        """)

        XCTAssertEqual(store.loadAll(), [.init(term: "murmure")])
        XCTAssertEqual(problems, [])
    }

    /// Trimmed BEFORE the emptiness check: without that ordering "   " would survive as a blank
    /// replacement reaching the recogniser prompt.
    func testAWhitespaceOnlyReplacementIsNormalizedToNilRatherThanReported() throws {
        try write("""
        [ { "term": "murmure", "replacement": "   " } ]
        """)

        XCTAssertEqual(store.loadAll(), [.init(term: "murmure")])
        XCTAssertEqual(problems, [])
    }

    /// The file is hand-edited in a text editor, which is exactly where stray whitespace comes
    /// from. Untrimmed, this term would neither match a transcript nor render correctly in a
    /// prompt built from the list.
    func testATermAndReplacementWithSurroundingWhitespaceAreTrimmed() throws {
        try write("""
        [ { "term": "  Trucost  ", "replacement": "  TruCost  " } ]
        """)

        XCTAssertEqual(store.loadAll(), [.init(term: "Trucost", replacement: "TruCost")])
        XCTAssertEqual(problems, [])
    }

    func testAnEmptyOrWhitespaceOnlyTermIsReportedAndSkippedWhileOthersLoad() throws {
        try write("""
        [
          { "term": "" },
          { "term": "   " },
          { "term": "Ollama" }
        ]
        """)

        XCTAssertEqual(store.loadAll(), [.init(term: "Ollama")])
        XCTAssertEqual(problems, [.emptyTerm(index: 0), .emptyTerm(index: 1)])
    }

    // MARK: - Per-entry decoding (Defect A / Defect B)

    /// **Defect A.** A single `JSONDecoder.decode([VocabularyEntry].self, ...)` call fails the
    /// entry range as a whole the moment one entry's `term` is the wrong JSON type -- costing
    /// "Claude Code" and "Ollama" for "cloud code"'s mistake, which is exactly what `loadAll()`'s
    /// own doc comment (and `report`'s) promise never happens. The good entries must load, and the
    /// bad one must be named by its INDEX, since this file is hand-edited and a message naming
    /// neither index nor line leaves the user hunting blind.
    func testABadEntryIsSkippedByIndexWhileTheEntriesAroundItStillLoad() throws {
        try write("""
        [
          { "term": "Claude Code" },
          { "term": 42 },
          { "term": "Ollama" }
        ]
        """)

        XCTAssertEqual(store.loadAll(), [.init(term: "Claude Code"), .init(term: "Ollama")])
        XCTAssertEqual(problems.count, 1, "\(problems)")
        if case .malformedEntry(let index, _) = problems.first {
            XCTAssertEqual(index, 1)
        } else {
            XCTFail("\(problems)")
        }
    }

    /// A file that never opens as a JSON array at all has no per-element structure to salvage --
    /// unlike Defect A's per-entry case above, this stays a whole-file failure.
    func testATopLevelValueThatIsNotAnArrayIsStillAWholeFileFailure() throws {
        try write("""
        { "term": "Claude Code" }
        """)

        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(problems.count, 1, "\(problems)")
        if case .malformedJSON = problems.first {} else { XCTFail("\(problems)") }
    }

    /// **Defect B.** `JSONDecoder` ignores keys it does not recognize, so `"replacment"` (missing
    /// the second "e") loads as a bare term with no correction -- a user staring at `vocabulary.json`
    /// sees a change that never happens and no reason why. Ruling L7: nothing fails quietly, so the
    /// unknown key must be reported and the unusable entry skipped, not silently accepted as
    /// "correct as typed."
    func testAMisspelledKeyIsReportedRatherThanSilentlyDroppingTheCorrection() throws {
        try write("""
        [ { "term": "cloud code", "replacment": "Claude Code" } ]
        """)

        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(problems.count, 1, "\(problems)")
        if case .unknownKey(let index, let key) = problems.first {
            XCTAssertEqual(index, 0)
            XCTAssertEqual(key, "replacment")
        } else {
            XCTFail("\(problems)")
        }
    }

    // MARK: - Duplicates

    /// The rule: case-insensitive match, last one in the file wins its content -- but the entry
    /// keeps the position of its FIRST appearance, so a later edit that only fixes a replacement
    /// does not reshuffle terms that had nothing to do with it.
    func testADuplicateTermIsCaseInsensitiveAndTheLastOneWinsInThePositionOfTheFirst() throws {
        try write("""
        [
          { "term": "Claude Code" },
          { "term": "Ollama" },
          { "term": "claude code", "replacement": "Claude Code" }
        ]
        """)

        XCTAssertEqual(store.loadAll(), [
            .init(term: "claude code", replacement: "Claude Code"),
            .init(term: "Ollama"),
        ])
        XCTAssertEqual(problems, [.duplicateTerm(term: "claude code")])
    }

    /// The duplicate key is built from the TRIMMED term, so whitespace alone cannot hide a
    /// duplicate from the rule above.
    func testADuplicateTermFoldsInSurroundingWhitespaceToo() throws {
        try write("""
        [
          { "term": "Trucost" },
          { "term": "  trucost  ", "replacement": "TruCost" }
        ]
        """)

        XCTAssertEqual(store.loadAll(), [.init(term: "trucost", replacement: "TruCost")])
        XCTAssertEqual(problems, [.duplicateTerm(term: "trucost")])
    }

    // MARK: - Malformed file

    /// The file is hand-edited in a text editor, so a missing bracket is going to happen. It must
    /// not crash the app -- an empty vocabulary for one broken save is the safe direction.
    func testAMalformedFileIsReportedAndYieldsAnEmptyVocabulary() throws {
        try write("""
        [ { "term": "Claude Code" },
        """)

        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(problems.count, 1, "\(problems)")
        if case .malformedJSON = problems.first {} else { XCTFail("\(problems)") }
    }

    /// A file whose bytes cannot be read at all is a different fix from a file whose JSON is
    /// wrong, and must not be reported as a syntax error the user will hunt for in vain.
    func testAFileThatCannotBeReadIsReportedAsUnreadableAndNotAsBadJSON() throws {
        try write("[]")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: fileURL.path) }

        let entries = store.loadAll()

        try XCTSkipIf(!entries.isEmpty, "running as root -- permissions do not apply")
        XCTAssertEqual(problems.count, 1, "\(problems)")
        if case .unreadableFile = problems.first {} else { XCTFail("\(problems)") }
    }

    // MARK: - Saving

    func testSavingWritesTheArrayBackAndReloadsIdentically() throws {
        let entries = [
            VocabularyEntry(term: "Claude Code"),
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
        ]

        try store.save(entries)

        XCTAssertEqual(store.loadAll(), entries)
        XCTAssertEqual(problems, [])
    }

    /// Sorted keys and pretty-printing, same reasoning as `ModeStore.encoder`: re-saving an
    /// unchanged vocabulary must not reshuffle the file into a different but equivalent diff.
    func testSavingTwiceProducesTheSameBytes() throws {
        let entries = [VocabularyEntry(term: "Ollama", replacement: nil)]

        try store.save(entries)
        let first = try Data(contentsOf: fileURL)
        try store.save(entries)
        let second = try Data(contentsOf: fileURL)

        XCTAssertEqual(first, second)
    }
}
