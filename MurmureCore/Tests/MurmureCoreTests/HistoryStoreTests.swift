import GRDB
import XCTest
@testable import MurmureCore

/// Every test opens its own database under `NSTemporaryDirectory()` and removes it again.
/// Nothing here may reach `~/Library/Application Support/Murmure/murmure.sqlite`, which is where
/// Louis's real archive will live -- and a migration is the one thing that would rewrite it.
///
/// The dictation text below is invented. It is deliberately in the register Louis actually
/// dictates -- French sentences carrying English technical terms -- because that is what the
/// tokenizer has to survive, and because a suite tested on `"hello world"` proves nothing about a
/// search for `clé`.
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("murmure.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: databaseURL)
    }

    /// A second, read-only connection to the same file, so the tests can look at the schema, the
    /// stored text and the full-text index without `HistoryStore` growing methods for them.
    private func inspect<T>(_ body: (Database) throws -> T) throws -> T {
        try DatabaseQueue(path: databaseURL.path).read(body)
    }

    /// Dates are built by parsing, never by arithmetic on `Date()`: the stored form carries
    /// milliseconds, so a fixture that is not already on a millisecond boundary would round-trip
    /// to a value that is equal to the eye and unequal to `XCTAssertEqual`.
    private func at(_ iso: String) -> Date {
        guard let date = HistoryTimestamp.date(from: iso) else {
            XCTFail("fixture timestamp \(iso) is not ISO 8601")
            return .distantPast
        }
        return date
    }

    private func voiceRecord(
        startedAt: String = "2026-09-01T14:42:03.123Z",
        raw: String? = "il faut brancher le connecteur sur le endpoint de staging",
        corrected: String? = nil,
        refined: String? = nil,
        audioFilename: String? = nil,
        outcome: DictationOutcome = .inserted
    ) -> HistoryRecord {
        HistoryRecord(
            startedAt: at(startedAt),
            durationSeconds: 29.7,
            outcome: outcome,
            modeKey: "voice",
            modeName: "Voice",
            sttModel: "large-v3-turbo",
            rawTranscript: raw,
            correctedText: corrected,
            refinedText: refined,
            insertedCharacters: raw?.count ?? 0,
            audioFilename: audioFilename
        )
    }

    // MARK: - Round-trip of every column

    func testEveryColumnOfAFullyPopulatedRecordSurvivesTheRoundTrip() throws {
        let store = try makeStore()
        let written = HistoryRecord(
            startedAt: at("2026-09-01T14:42:03.123Z"),
            durationSeconds: 38.25,
            outcome: .inserted,
            modeKey: "email",
            modeName: "Email",
            sttModel: "large-v3-turbo",
            llmModel: "gemma3:12b",
            rawTranscript: "réponds au client que le connecteur est déployé sur la prod",
            correctedText: "réponds au client que le Connecteur est déployé sur la prod",
            refinedText: "Bonjour, le connecteur est déployé en production.",
            insertedCharacters: 48,
            targetBundleID: "com.apple.mail",
            targetAppName: "Mail",
            audioFilename: "rec-2026-09-01T14-42-03.123Z.wav",
            transcriptionSeconds: 2.4,
            refinementSeconds: 19.1,
            failureMessage: "Ollama n'a pas répondu"
        )

        let inserted = try store.insert(written)
        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(inserted.id)))

        XCTAssertEqual(read.id, inserted.id)
        XCTAssertEqual(read.startedAt, written.startedAt)
        XCTAssertEqual(read.durationSeconds, 38.25)
        XCTAssertEqual(read.outcome, .inserted)
        XCTAssertEqual(read.modeKey, "email")
        XCTAssertEqual(read.modeName, "Email")
        XCTAssertEqual(read.sttModel, "large-v3-turbo")
        XCTAssertEqual(read.llmModel, "gemma3:12b")
        XCTAssertEqual(read.rawTranscript,
                       "réponds au client que le connecteur est déployé sur la prod")
        XCTAssertEqual(read.correctedText,
                       "réponds au client que le Connecteur est déployé sur la prod")
        XCTAssertEqual(read.refinedText, "Bonjour, le connecteur est déployé en production.")
        XCTAssertEqual(read.insertedCharacters, 48)
        XCTAssertEqual(read.targetBundleID, "com.apple.mail")
        XCTAssertEqual(read.targetAppName, "Mail")
        XCTAssertEqual(read.audioFilename, "rec-2026-09-01T14-42-03.123Z.wav")
        XCTAssertEqual(read.transcriptionSeconds, 2.4)
        XCTAssertEqual(read.refinementSeconds, 19.1)
        XCTAssertEqual(read.failureMessage, "Ollama n'a pas répondu")
        XCTAssertEqual(read, inserted)
    }

    /// The other half of the round-trip: an optional left out has to come back absent, not empty.
    /// `""` and `nil` are different answers to "was there a refinement", and the whole of D6 rests
    /// on the difference.
    func testEveryNullableColumnComesBackNilRatherThanEmpty() throws {
        let store = try makeStore()
        let written = HistoryRecord(
            startedAt: at("2026-09-01T09:00:00.000Z"),
            durationSeconds: 3.5,
            outcome: .nothingHeard,
            modeKey: "voice",
            modeName: "Voice",
            sttModel: "large-v3-turbo"
        )

        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(try store.insert(written).id)))

        XCTAssertNil(read.llmModel)
        XCTAssertNil(read.rawTranscript)
        XCTAssertNil(read.correctedText)
        XCTAssertNil(read.refinedText)
        XCTAssertNil(read.targetBundleID)
        XCTAssertNil(read.targetAppName)
        XCTAssertNil(read.audioFilename)
        XCTAssertNil(read.transcriptionSeconds)
        XCTAssertNil(read.refinementSeconds)
        XCTAssertNil(read.failureMessage)
        XCTAssertEqual(read.insertedCharacters, 0)
        XCTAssertEqual(read.durationSeconds, 3.5)
    }

    func testInsertAssignsAnIdAndSuccessiveRowsGetDistinctOnes() throws {
        let store = try makeStore()

        let first = try store.insert(voiceRecord())
        let second = try store.insert(voiceRecord())

        XCTAssertNotNil(first.id)
        XCTAssertNotNil(second.id)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testFetchingAnAbsentIdReturnsNothing() throws {
        let store = try makeStore()

        XCTAssertNil(try store.record(id: 404))
    }

    /// The raw values are the on-disk representation of `outcome`. Changing one rewrites the
    /// meaning of every row already written, so they are pinned here rather than left to
    /// `String(describing:)`.
    func testTheOutcomeRawValuesAreTheOnesWrittenToDisk() {
        XCTAssertEqual(DictationOutcome.inserted.rawValue, "inserted")
        XCTAssertEqual(DictationOutcome.copiedToClipboard.rawValue, "copiedToClipboard")
        XCTAssertEqual(DictationOutcome.nothingHeard.rawValue, "nothingHeard")
        XCTAssertEqual(DictationOutcome.failed.rawValue, "failed")
        XCTAssertEqual(DictationOutcome.cancelled.rawValue, "cancelled")
        XCTAssertEqual(DictationOutcome.allCases.count, 5)
    }

    func testEveryOutcomeRoundTripsThroughTheDatabase() throws {
        let store = try makeStore()

        for outcome in DictationOutcome.allCases {
            let inserted = try store.insert(voiceRecord(outcome: outcome))
            let read = try XCTUnwrap(try store.record(id: XCTUnwrap(inserted.id)))
            XCTAssertEqual(read.outcome, outcome)
        }
    }

    /// D8 one layer down: the four outcomes are stored, so a row that inserted nothing still says
    /// which of the three "nothing" it was.
    func testACancelledDictationKeepsItsAudioAndCarriesNoTranscript() throws {
        let store = try makeStore()
        let inserted = try store.insert(HistoryRecord(
            startedAt: at("2026-09-01T11:00:00.000Z"),
            durationSeconds: 4.2,
            outcome: .cancelled,
            modeKey: "voice",
            modeName: "Voice",
            sttModel: "large-v3-turbo",
            audioFilename: "rec-2026-09-01T11-00-00.000Z.wav"
        ))

        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(inserted.id)))

        XCTAssertEqual(read.outcome, .cancelled)
        XCTAssertNil(read.rawTranscript)
        XCTAssertEqual(read.audioFilename, "rec-2026-09-01T11-00-00.000Z.wav")
        XCTAssertEqual(read.insertedCharacters, 0)
    }

    func testAFailedDictationCarriesItsMessageBesideTheTextItRecovered() throws {
        let store = try makeStore()
        let inserted = try store.insert(HistoryRecord(
            startedAt: at("2026-09-01T11:05:00.000Z"),
            durationSeconds: 31.0,
            outcome: .failed,
            modeKey: "email",
            modeName: "Email",
            sttModel: "large-v3-turbo",
            llmModel: "gemma3:12b",
            rawTranscript: "préviens l'équipe que le déploiement est décalé",
            failureMessage: "Ollama ne répond pas"
        ))

        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(inserted.id)))

        XCTAssertEqual(read.outcome, .failed)
        XCTAssertEqual(read.failureMessage, "Ollama ne répond pas")
        XCTAssertEqual(read.rawTranscript, "préviens l'équipe que le déploiement est décalé")
        XCTAssertNil(read.refinedText, "a refinement that failed leaves the refined column empty")
    }

    // MARK: - D6: refinedText is never a copy of the raw text

    func testAnUnrefinedDictationStoresNoRefinedTextAtAll() throws {
        let store = try makeStore()
        let raw = "il faut brancher le connecteur sur le endpoint de staging"

        let inserted = try store.insert(voiceRecord(raw: raw, refined: nil))
        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(inserted.id)))

        XCTAssertNil(read.refinedText)
        XCTAssertNotEqual(read.refinedText, read.rawTranscript)
    }

    /// Read at the column, not through the record: a store that quietly filled `refinedText` with
    /// the transcript would still hand back a plausible-looking `HistoryRecord`, and the only
    /// place the copy is visible is the database itself.
    func testTheRefinedColumnIsSQLNullForAnUnrefinedDictation() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(refined: nil)).id)

        let isNull = try inspect { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT refinedText IS NULL FROM dictation WHERE id = ?",
                arguments: [id]
            )
        }

        XCTAssertEqual(isNull, true)
    }

    func testARefinedDictationKeepsBothTextsAndTheyStayDifferent() throws {
        let store = try makeStore()
        let raw = "réponds au client que le connecteur est déployé sur la prod"
        let refined = "Bonjour, le connecteur est déployé en production."

        let inserted = try store.insert(voiceRecord(raw: raw, refined: refined))
        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(inserted.id)))

        XCTAssertEqual(read.rawTranscript, raw)
        XCTAssertEqual(read.refinedText, refined)
    }

    // MARK: - The stored timestamp

    /// The column is TEXT, so its format is what makes `ORDER BY` and the purge predicate work.
    func testTheStoredTimestampIsISO8601UTCToTheMillisecond() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(startedAt: "2026-09-01T14:42:03.123Z")).id)

        let text = try inspect { db in
            try String.fetchOne(db, sql: "SELECT startedAt FROM dictation WHERE id = ?",
                                arguments: [id])
        }

        XCTAssertEqual(text, "2026-09-01T14:42:03.123Z")
    }

    /// The claim the schema rests on: comparing the stored strings gives the same answer as
    /// comparing the dates. It holds only because the format is fixed-width and always UTC -- a
    /// local-time or variable-width timestamp would sort into nonsense on a TEXT column.
    func testLexicographicOrderOfTheStoredTextMatchesChronologicalOrder() {
        let earlier = at("2026-08-31T23:59:59.999Z")
        let later = at("2026-09-01T00:00:00.001Z")

        XCTAssertLessThan(earlier, later)
        XCTAssertLessThan(HistoryTimestamp.string(from: earlier),
                          HistoryTimestamp.string(from: later))
        XCTAssertEqual(HistoryTimestamp.string(from: earlier).count,
                       HistoryTimestamp.string(from: later).count)
    }

    /// Stated rather than discovered: sub-millisecond precision does not survive the column, and
    /// nothing in Murmure needs it to.
    func testATimestampOffAMillisecondBoundaryRoundTripsToTheNearestMillisecond() throws {
        let store = try makeStore()
        let odd = Date(timeIntervalSince1970: 1_788_000_000.123_456_7)

        var record = voiceRecord()
        record.startedAt = odd
        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(try store.insert(record).id)))

        XCTAssertEqual(read.startedAt.timeIntervalSince1970, odd.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Search

    private func seedSearchCorpus(_ store: HistoryStore) throws {
        _ = try store.insert(voiceRecord(
            startedAt: "2026-09-01T08:00:00.000Z",
            raw: "j'ai réglé le problème de cache côté worker, la clé d'API était périmée"
        ))
        _ = try store.insert(voiceRecord(
            startedAt: "2026-09-01T09:00:00.000Z",
            raw: "on a regle le pipeline de staging hier soir"
        ))
        _ = try store.insert(voiceRecord(
            startedAt: "2026-09-01T10:00:00.000Z",
            raw: "note pour moi meme, relancer le batch",
            refined: "Note pour moi-même : relancer le batch de rapprochement."
        ))
    }

    /// Louis dictates French. Searching without the accent has to find the accented word.
    func testSearchWithoutAnAccentFindsTheAccentedWord() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        let hits = try store.search("cle", limit: 10)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.rawTranscript?.contains("clé"), true)
    }

    /// And the other direction, which is a different claim: the query is folded too, so a word
    /// typed with its accents finds text stored without them.
    func testSearchWithAnAccentFindsTheUnaccentedWord() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        let hits = try store.search("réglé", limit: 10)

        XCTAssertEqual(hits.count, 2, "both `réglé` and `regle` are the same token")
    }

    /// The one fixture that separates `remove_diacritics 2` from the legacy option: French
    /// Latin-1 accents fold under both, so a suite testing only `clé` would pass with the wrong
    /// tokenizer. A double-diacritic codepoint -- here a client contact's name -- does not.
    func testSearchFoldsTheDiacriticsTheLegacyTokenizerOptionLeavesAlone() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(
            raw: "le contact chez le client s'appelle Nguyễn, il gère l'intégration"
        ))

        XCTAssertEqual(try store.search("nguyen", limit: 10).count, 1)
        XCTAssertEqual(try store.search("Nguyễn", limit: 10).count, 1)
    }

    func testSearchIsCaseInsensitive() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(raw: "le WORKER relance le batch"))

        XCTAssertEqual(try store.search("worker", limit: 10).count, 1)
        XCTAssertEqual(try store.search("WORKER", limit: 10).count, 1)
    }

    func testSearchFindsATermThatAppearsOnlyInTheRefinedText() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(
            raw: "note pour moi meme, relancer le batch",
            refined: "Note pour moi-même : relancer le batch de rapprochement."
        ))

        let hits = try store.search("rapprochement", limit: 10)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.rawTranscript?.contains("rapprochement"), false)
    }

    func testSearchFindsATermThatAppearsOnlyInTheRawTranscript() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(
            raw: "note pour moi meme, relancer le batch de rapprochement",
            refined: "Note pour moi-même : relancer le traitement."
        ))

        let hits = try store.search("rapprochement", limit: 10)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.refinedText?.contains("rapprochement"), false)
    }

    /// `correctedText` is indexed exactly like the other two -- Louis searching his history is
    /// looking for what he actually wrote, which in a no-refiner mode is the vocabulary-corrected
    /// text, not the model's mis-hearing.
    func testSearchFindsATermThatAppearsOnlyInTheCorrectedText() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(
            raw: "open cloud code now",
            corrected: "open Claude Code now"
        ))

        let hits = try store.search("Claude", limit: 10)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.rawTranscript?.contains("Claude"), false)
    }

    func testSearchFindsAnEnglishTechnicalTermInAFrenchSentence() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        XCTAssertEqual(try store.search("staging", limit: 10).count, 1)
        XCTAssertEqual(try store.search("worker", limit: 10).count, 1)
    }

    func testSearchRequiresAllTokensRatherThanAny() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        XCTAssertEqual(try store.search("pipeline staging", limit: 10).count, 1)
        XCTAssertEqual(try store.search("pipeline périmée", limit: 10).count, 0)
    }

    func testSearchResultsComeBackNewestFirst() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        let hits = try store.search("le", limit: 10)

        XCTAssertEqual(hits.map(\.startedAt), hits.map(\.startedAt).sorted(by: >))
    }

    /// A query with no token at all answers with nothing, not with everything. A search box that
    /// returned the whole archive when handed `...` would read as a search that had failed.
    func testAQueryOfOnlyPunctuationReturnsNothing() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        XCTAssertEqual(try store.search("...", limit: 10), [])
        XCTAssertEqual(try store.search("  ", limit: 10), [])
        XCTAssertEqual(try store.search("", limit: 10), [])
    }

    /// `MATCH` has a syntax, and a search field will be handed quotes and parentheses. The store
    /// answers with rows or with none, never with a thrown syntax error.
    func testAQueryCarryingFTS5SyntaxIsSearchedForRatherThanExecuted() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        XCTAssertNoThrow(try store.search("\"cache\" OR (worker", limit: 10))
        XCTAssertEqual(try store.search("\"cache\"", limit: 10).count, 1,
                       "the quotes are punctuation around a word, not phrase syntax")
        XCTAssertEqual(try store.search("cache OR pipeline", limit: 10).count, 0,
                       "`OR` is a word to search for; executed as an operator this would find two")
    }

    func testSearchHonoursItsLimitAndOffset() throws {
        let store = try makeStore()
        try seedSearchCorpus(store)

        XCTAssertEqual(try store.search("le", limit: 2).count, 2)
        XCTAssertEqual(try store.search("le", limit: 2, offset: 2).count, 1)
    }

    // MARK: - Search as it is typed

    /// Louis, an hour after the pane shipped: *"quand je vais rechercher « moi », je tape « mo »
    /// -- aucun résultat, puis « moi » -- 5 résultats."*
    ///
    /// A search field that answers nothing until the word is finished answers nothing at all:
    /// typing is the only way anyone uses one. The word still under the cursor is matched as a
    /// prefix.
    func testTypingTheFirstLettersOfAWordAlreadyFindsIt() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(raw: "note pour moi, relancer le batch avant jeudi"))

        XCTAssertEqual(try store.search("mo", limit: 10).count, 1, "`mo` has to find `moi`")
        XCTAssertEqual(try store.search("moi", limit: 10).count, 1, "and finishing it keeps it")
    }

    /// The other half of the same report: *"j'ai un message avec le mot « t'avoue », je cherche
    /// « t'av » -- 0 résultat."*
    ///
    /// `unicode61` splits the apostrophe, so this is the tokens `t` and `av` against `t` and
    /// `avoue`. A fix that hung a prefix operator on the whole typed string and left the
    /// tokenizer to it would still answer nothing here -- the prefix has to land on the last
    /// token of the word, not on the word.
    func testTypingAcrossAnApostropheFindsTheWordBeingTyped() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(raw: "je t'avoue que le rapprochement m'échappe encore"))

        XCTAssertEqual(try store.search("t'av", limit: 10).count, 1)
        XCTAssertEqual(try store.search("t'avoue", limit: 10).count, 1)
    }

    /// And the rule that keeps the first half honest: only the word still being typed is a
    /// prefix. `moi ava` must not quietly widen `moi` into `moins` as well -- a query that grows
    /// vaguer as it grows longer is the failure a prefix search is prone to.
    func testOnlyTheWordStillBeingTypedIsMatchedAsAPrefix() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(
            startedAt: "2026-09-01T08:00:00.000Z",
            raw: "note pour moi, relancer le batch avant jeudi"))
        _ = try store.insert(voiceRecord(
            startedAt: "2026-09-01T09:00:00.000Z",
            raw: "il faudra moins de latence sur l'avatar de la page"))

        let hits = try store.search("moi ava", limit: 10)

        XCTAssertEqual(hits.count, 1, "`moins` is not `moi`, however far `ava` reaches")
        XCTAssertEqual(hits.first?.rawTranscript?.contains("moi,"), true)
    }

    // MARK: - Ordering and paging

    func testPageIsOrderedByStartedAtDescending() throws {
        let store = try makeStore()
        for iso in ["2026-09-01T08:00:00.000Z",
                    "2026-09-01T10:00:00.000Z",
                    "2026-09-01T09:00:00.000Z"] {
            _ = try store.insert(voiceRecord(startedAt: iso))
        }

        let page = try store.page(limit: 10)

        XCTAssertEqual(page.map { HistoryTimestamp.string(from: $0.startedAt) },
                       ["2026-09-01T10:00:00.000Z",
                        "2026-09-01T09:00:00.000Z",
                        "2026-09-01T08:00:00.000Z"])
    }

    /// The tie-break, pinned: same timestamp means the row inserted later comes first. Undefined
    /// order within a tie is what makes a paged list show one row twice and drop another.
    func testTwoRowsWithTheIdenticalTimestampComeBackNewestIdFirst() throws {
        let store = try makeStore()
        let first = try store.insert(voiceRecord(startedAt: "2026-09-01T12:00:00.000Z"))
        let second = try store.insert(voiceRecord(startedAt: "2026-09-01T12:00:00.000Z"))

        let page = try store.page(limit: 10)

        XCTAssertEqual(page.map(\.id), [second.id, first.id])
    }

    func testPagingAcrossATieNeitherRepeatsNorSkipsARow() throws {
        let store = try makeStore()
        var ids: [Int64?] = []
        for _ in 0..<4 {
            ids.append(try store.insert(voiceRecord(startedAt: "2026-09-01T12:00:00.000Z")).id)
        }

        let firstPage = try store.page(limit: 2, offset: 0)
        let secondPage = try store.page(limit: 2, offset: 2)

        XCTAssertEqual(firstPage.map(\.id) + secondPage.map(\.id), ids.reversed())
    }

    func testPageHonoursItsLimit() throws {
        let store = try makeStore()
        for _ in 0..<5 { _ = try store.insert(voiceRecord()) }

        XCTAssertEqual(try store.page(limit: 3).count, 3)
        XCTAssertEqual(try store.page(limit: 100).count, 5)
    }

    func testAnEmptyHistoryPagesToNothing() throws {
        let store = try makeStore()

        XCTAssertEqual(try store.page(limit: 10), [])
    }

    // MARK: - The migration

    func testTheMigrationAppliedToAnEmptyFileCreatesTheWholeSchema() throws {
        FileManager.default.createFile(atPath: databaseURL.path, contents: Data())

        _ = try makeStore()

        let names = try inspect { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master ORDER BY name")
        }
        XCTAssertTrue(names.contains("dictation"), names.description)
        XCTAssertTrue(names.contains("dictation_startedAt"), names.description)
        XCTAssertTrue(names.contains("dictation_fts"), names.description)
    }

    /// The second migration will certainly run against a file that already has rows in it, so the
    /// first one has to be re-appliable now. Re-opening the store runs the migrator again; if it
    /// were not recorded as applied, `CREATE TABLE dictation` would throw.
    func testReopeningAnExistingDatabaseIsANoOpAndKeepsTheRows() throws {
        let id: Int64
        do {
            let store = try makeStore()
            id = try XCTUnwrap(try store.insert(voiceRecord()).id)
        }
        let before = try inspect { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master ORDER BY name")
        }

        let reopened = try makeStore()

        let after = try inspect { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master ORDER BY name")
        }
        XCTAssertEqual(after, before)
        XCTAssertNotNil(try reopened.record(id: id))
        XCTAssertEqual(try reopened.search("connecteur", limit: 10).count, 1)
    }

    /// The tokenizer arguments are invisible in behaviour once they are right, so the declaration
    /// itself is asserted: the external content is what makes the index cheap, and
    /// `remove_diacritics 2` is what makes it French.
    func testTheFullTextTableDeclaresRemoveDiacriticsTwoOverTheDictationTable() throws {
        _ = try makeStore()

        let sql = try XCTUnwrap(try inspect { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'dictation_fts'")
        })

        XCTAssertTrue(sql.contains("remove_diacritics"), sql)
        XCTAssertTrue(sql.contains("2"), sql)
        XCTAssertTrue(sql.contains("content='dictation'"), sql)
        XCTAssertTrue(sql.contains("content_rowid='id'"), sql)
    }

    /// External content means the index does not update itself. These three triggers are the
    /// whole mechanism, and their absence is invisible until a deleted row keeps matching.
    func testTheExternalContentTriggersExist() throws {
        _ = try makeStore()

        let triggers = try inspect { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
            )
        }

        XCTAssertEqual(triggers.count, 3, triggers.description)
    }

    /// `v2-correctedText` is additive on top of `v1-dictation`, never a rewrite of it -- a
    /// registered migration is immutable the moment it has shipped. This is the same schema
    /// assertion the empty-file test above makes, extended to the column that migration adds.
    func testTheMigrationAddsTheCorrectedTextColumn() throws {
        _ = try makeStore()

        let columns = try inspect { db in try db.columns(in: "dictation").map(\.name) }

        XCTAssertTrue(columns.contains("correctedText"), columns.description)
    }

    /// FTS5 gives an external-content table no `ALTER TABLE ... ADD COLUMN`, so `v2-correctedText`
    /// drops and recreates `dictation_fts` rather than altering it -- this is the assertion that
    /// the recreation actually declared the new column, not merely that the table still exists.
    func testTheFullTextTableIncludesCorrectedText() throws {
        _ = try makeStore()

        let sql = try XCTUnwrap(try inspect { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'dictation_fts'")
        })

        XCTAssertTrue(sql.contains("correctedText"), sql)
    }

    /// **The migration Louis's real archive will run.** `v1-dictation` is applied by hand here,
    /// exactly as it shipped, with no `correctedText` column and no knowledge that it will ever
    /// exist -- imitating the file already on his disk rather than the `HistoryRecord` type as it
    /// reads today. Opening it through `HistoryStore` must then apply `v2-correctedText` on top,
    /// keep the row already there, drop `correctedText` in as NULL rather than lose the row, and
    /// leave the pre-existing text findable through the rebuilt index -- not only text written
    /// after the migration.
    func testAnExistingV1OnlyDatabaseMigratesToV2AndKeepsReadingAndSearching() throws {
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1-dictation") { db in
            try db.create(table: "dictation") { t in
                t.primaryKey("id", .integer)
                t.column("startedAt", .text).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("outcome", .text).notNull()
                t.column("modeKey", .text).notNull()
                t.column("modeName", .text).notNull()
                t.column("sttModel", .text).notNull()
                t.column("llmModel", .text)
                t.column("rawTranscript", .text)
                t.column("refinedText", .text)
                t.column("insertedCharacters", .integer).notNull()
                t.column("targetBundleID", .text)
                t.column("targetAppName", .text)
                t.column("audioFilename", .text)
                t.column("transcriptionSeconds", .double)
                t.column("refinementSeconds", .double)
                t.column("failureMessage", .text)
            }
            try db.execute(sql: "CREATE INDEX dictation_startedAt ON dictation(startedAt DESC)")
            try db.create(virtualTable: "dictation_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.synchronize(withTable: "dictation")
                t.column("rawTranscript")
                t.column("refinedText")
            }
        }
        let seedQueue = try DatabaseQueue(path: databaseURL.path)
        try v1Only.migrate(seedQueue)
        // Raw SQL, deliberately, rather than `HistoryRecord(...).insert(db)`: that type already
        // carries `correctedText`, and inserting through it would write a column this v1-only
        // table does not have -- which is precisely the bug this test exists to rule out for the
        // other direction (a real v1 file, opened by today's code).
        try seedQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictation
                        (startedAt, durationSeconds, outcome, modeKey, modeName, sttModel,
                         rawTranscript, insertedCharacters)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["2026-08-01T10:00:00.000Z", 12.0, "inserted", "voice", "Voice",
                            "large-v3-turbo", "le xylophone du connecteur", 27]
            )
        }
        let oldID = try XCTUnwrap(
            try seedQueue.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM dictation") })

        let store = try makeStore()

        let read = try XCTUnwrap(try store.record(id: oldID))
        XCTAssertEqual(read.rawTranscript, "le xylophone du connecteur")
        XCTAssertNil(read.correctedText, "a row written before this column existed has nothing")
        XCTAssertEqual(try store.search("xylophone", limit: 10).map(\.id), [oldID],
                       "the rebuilt index must still find text written before the migration")

        // And the column is genuinely usable afterwards, not merely present.
        var withCorrection = read
        withCorrection.correctedText = "le Claude Code du connecteur"
        XCTAssertTrue(try store.update(withCorrection))
        XCTAssertEqual(try store.record(id: oldID)?.correctedText, "le Claude Code du connecteur")
        XCTAssertEqual(try store.search("Claude", limit: 10).map(\.id), [oldID])
    }

    func testTheStartedAtIndexIsDescending() throws {
        _ = try makeStore()

        let sql = try XCTUnwrap(try inspect { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE name = 'dictation_startedAt'"
            )
        })

        XCTAssertTrue(sql.contains("DESC"), sql)
    }

    // MARK: - The audio path (D7)

    /// The point of storing the filename rather than the path: one row resolves against the real
    /// `recordings/` in the app and against a temporary folder in a test.
    func testARelativeAudioFilenameResolvesAgainstTwoDifferentBases() throws {
        let record = voiceRecord(audioFilename: "rec-2026-09-01T14-42-03.123Z.wav")
        let app = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Murmure/recordings")
        let temporary = URL(fileURLWithPath: "/tmp/HistoryStoreTests/recordings")

        XCTAssertEqual(record.audioURL(inRecordings: app)?.path,
                       "/Users/someone/Library/Application Support/Murmure/recordings/rec-2026-09-01T14-42-03.123Z.wav")
        XCTAssertEqual(record.audioURL(inRecordings: temporary)?.path,
                       "/tmp/HistoryStoreTests/recordings/rec-2026-09-01T14-42-03.123Z.wav")
    }

    /// `appendingPathComponent` does not honour a leading slash -- it would answer
    /// `<base>/Users/...`, a path that looks resolved and points nowhere. Answering nothing is the
    /// only honest reply.
    func testAnAbsoluteAudioFilenameNeverResolvesAgainstABase() {
        var record = voiceRecord()
        record.audioFilename = "/Users/someone/elsewhere.wav"

        XCTAssertNil(record.audioURL(inRecordings: URL(fileURLWithPath: "/tmp/recordings")))
    }

    func testAnUpwardReachingAudioFilenameNeverResolvesAgainstABase() {
        var record = voiceRecord()
        record.audioFilename = "../../elsewhere.wav"

        XCTAssertNil(record.audioURL(inRecordings: URL(fileURLWithPath: "/tmp/recordings")))
    }

    func testARecordWithNoAudioResolvesToNoURL() {
        XCTAssertNil(voiceRecord(audioFilename: nil)
            .audioURL(inRecordings: URL(fileURLWithPath: "/tmp/recordings")))
    }

    /// Refused at the door as well as at the read, because a row that carries an absolute path is
    /// a row that survives nothing: the folder moves the day `Storage` changes.
    func testAnAbsoluteAudioFilenameIsRefusedAtInsert() throws {
        let store = try makeStore()

        XCTAssertThrowsError(
            try store.insert(voiceRecord(audioFilename: "/Users/someone/elsewhere.wav"))
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError,
                           .audioFilenameNotRelative("/Users/someone/elsewhere.wav"))
        }
        XCTAssertEqual(try store.page(limit: 10), [], "the row must not be written either")
    }

    func testAnUpwardReachingAudioFilenameIsRefusedAtInsert() throws {
        let store = try makeStore()

        XCTAssertThrowsError(try store.insert(voiceRecord(audioFilename: "../elsewhere.wav")))
    }

    // MARK: - Update, which is what "Process again" writes back

    /// D12's one edit to the archive: a re-refinement replaces the refined text **and** the mode
    /// and model that produced it, because the metadata block describes the text on screen -- a
    /// row that kept "Voice / no language model" beside a refined paragraph would be lying about
    /// where that paragraph came from.
    func testUpdatingARowRewritesItsRefinementAndTheModeThatProducedIt() throws {
        let store = try makeStore()
        var row = try store.insert(voiceRecord())

        row.refinedText = "Il faut brancher le connecteur sur l'endpoint de staging."
        row.modeKey = "prompt"
        row.modeName = "Prompt"
        row.llmModel = "s1-mini"
        row.refinementSeconds = 0.4
        XCTAssertTrue(try store.update(row))

        let read = try XCTUnwrap(try store.record(id: XCTUnwrap(row.id)))
        XCTAssertEqual(read, row)
        XCTAssertEqual(read.rawTranscript,
                       "il faut brancher le connecteur sur le endpoint de staging",
                       "the raw transcript is not what a re-refinement rewrites")
    }

    /// The index follows, through the `synchronize` triggers the migration wrote. Without them a
    /// re-refined dictation stays findable only by the words of the refinement it no longer has.
    func testTheFullTextIndexFollowsAnUpdatedRow() throws {
        let store = try makeStore()
        var row = try store.insert(voiceRecord(refined: "Le déploiement est terminé."))

        row.refinedText = "La migration est terminée."
        XCTAssertTrue(try store.update(row))

        XCTAssertEqual(try store.search("migration", limit: 10).count, 1)
        XCTAssertEqual(try store.search("déploiement", limit: 10), [],
                       "the old refinement must stop matching")
    }

    func testUpdatingARowThatIsNotThereWritesNothingAndSaysSo() throws {
        let store = try makeStore()
        var absent = voiceRecord()
        absent.id = 404

        XCTAssertFalse(try store.update(absent))
        XCTAssertFalse(try store.update(voiceRecord()), "a record with no id was never inserted")
        XCTAssertEqual(try store.page(limit: 10), [])
    }

    // MARK: - Delete

    func testDeletingARowRemovesItAndReportsThatItDid() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord()).id)

        XCTAssertTrue(try store.delete(id: id))
        XCTAssertNil(try store.record(id: id))
    }

    func testDeletingAnAbsentRowReportsThatNothingWasRemoved() throws {
        let store = try makeStore()

        XCTAssertFalse(try store.delete(id: 404))
    }

    /// The store owns rows, not files. A caller that wants the WAV gone deletes it itself.
    func testDeletingARowLeavesTheWavOnDisk() throws {
        let store = try makeStore()
        let wav = try makeWav(named: "rec-delete.wav")
        let id = try XCTUnwrap(try store.insert(voiceRecord(audioFilename: "rec-delete.wav")).id)

        XCTAssertTrue(try store.delete(id: id))

        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    private func makeWav(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("RIFF-not-really-a-wav".utf8).write(to: url)
        return url
    }

    // MARK: - clear-audio: the rows survive

    func testClearAudioLeavesTheRowsAndTheirTextReadable() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(
            startedAt: "2026-08-01T10:00:00.000Z",
            raw: "il faut brancher le connecteur sur le endpoint de staging",
            audioFilename: "rec-old.wav"
        )).id)

        _ = try store.clearAudio(startedBefore: at("2026-09-01T00:00:00.000Z"))

        let read = try XCTUnwrap(try store.record(id: id))
        XCTAssertNil(read.audioFilename)
        XCTAssertEqual(read.rawTranscript, "il faut brancher le connecteur sur le endpoint de staging")
        XCTAssertEqual(read.durationSeconds, 29.7)
        XCTAssertEqual(read.outcome, .inserted)
    }

    func testClearAudioReturnsTheFilenamesItDetachedAndLeavesTheFilesOnDisk() throws {
        let store = try makeStore()
        let wav = try makeWav(named: "rec-old.wav")
        _ = try store.insert(voiceRecord(startedAt: "2026-08-01T10:00:00.000Z",
                                         audioFilename: "rec-old.wav"))

        let detached = try store.clearAudio(startedBefore: at("2026-09-01T00:00:00.000Z"))

        XCTAssertEqual(detached, ["rec-old.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path),
                      "deleting the file is the caller's, not the store's")
    }

    func testClearAudioSparesRowsThatAreNewerThanTheCutoff() throws {
        let store = try makeStore()
        let old = try XCTUnwrap(try store.insert(voiceRecord(startedAt: "2026-08-01T10:00:00.000Z",
                                                            audioFilename: "rec-old.wav")).id)
        let fresh = try XCTUnwrap(try store.insert(voiceRecord(startedAt: "2026-08-31T10:00:00.000Z",
                                                              audioFilename: "rec-fresh.wav")).id)

        let detached = try store.clearAudio(startedBefore: at("2026-08-29T00:00:00.000Z"))

        XCTAssertEqual(detached, ["rec-old.wav"])
        XCTAssertNil(try store.record(id: old)?.audioFilename)
        XCTAssertEqual(try store.record(id: fresh)?.audioFilename, "rec-fresh.wav")
    }

    func testClearAudioOnAHistoryWithNoAudioDetachesNothing() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(audioFilename: nil))

        XCTAssertEqual(try store.clearAudio(startedBefore: .distantFuture), [])
    }

    // MARK: - clear-text: the WAVs survive

    func testClearTextLeavesTheWavsAndTheAudioFilenameAlone() throws {
        let store = try makeStore()
        let wav = try makeWav(named: "rec-old.wav")
        let id = try XCTUnwrap(try store.insert(voiceRecord(
            startedAt: "2026-08-01T10:00:00.000Z",
            audioFilename: "rec-old.wav"
        )).id)

        _ = try store.clearText(startedBefore: at("2026-09-01T00:00:00.000Z"))

        XCTAssertEqual(try store.record(id: id)?.audioFilename, "rec-old.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    func testClearTextKeepsTheRowAndEverythingAboutItExceptTheText() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(HistoryRecord(
            startedAt: at("2026-08-01T10:00:00.000Z"),
            durationSeconds: 44.5,
            outcome: .inserted,
            modeKey: "email",
            modeName: "Email",
            sttModel: "large-v3-turbo",
            llmModel: "gemma3:12b",
            rawTranscript: "réponds au client que le connecteur est déployé",
            refinedText: "Bonjour, le connecteur est déployé en production.",
            insertedCharacters: 48,
            targetAppName: "Mail",
            failureMessage: "Ollama ne répond pas"
        )).id)

        XCTAssertEqual(try store.clearText(startedBefore: at("2026-09-01T00:00:00.000Z")), 1)

        let read = try XCTUnwrap(try store.record(id: id))
        XCTAssertNil(read.rawTranscript)
        XCTAssertNil(read.refinedText)
        XCTAssertEqual(read.durationSeconds, 44.5)
        XCTAssertEqual(read.modeName, "Email")
        XCTAssertEqual(read.llmModel, "gemma3:12b")
        XCTAssertEqual(read.insertedCharacters, 48)
        XCTAssertEqual(read.targetAppName, "Mail")
        XCTAssertEqual(read.failureMessage, "Ollama ne répond pas",
                       "Murmure's own words about a failure are not dictated content")
    }

    func testClearTextSparesRowsThatAreNewerThanTheCutoff() throws {
        let store = try makeStore()
        let old = try XCTUnwrap(try store.insert(voiceRecord(startedAt: "2026-08-01T10:00:00.000Z")).id)
        let fresh = try XCTUnwrap(try store.insert(voiceRecord(startedAt: "2026-08-31T10:00:00.000Z")).id)

        XCTAssertEqual(try store.clearText(startedBefore: at("2026-08-29T00:00:00.000Z")), 1)

        XCTAssertNil(try store.record(id: old)?.rawTranscript)
        XCTAssertNotNil(try store.record(id: fresh)?.rawTranscript)
    }

    /// The gap the retention purge would otherwise leave open: `correctedText` is dictated content
    /// exactly like the other two, and a purge that cleared only `rawTranscript`/`refinedText`
    /// would let a corrected transcript outlive the 30-day promise Louis approved.
    func testClearTextAlsoClearsCorrectedText() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(
            startedAt: "2026-08-01T10:00:00.000Z",
            raw: "open cloud code now",
            corrected: "open Claude Code now"
        )).id)

        XCTAssertEqual(try store.clearText(startedBefore: at("2026-09-01T00:00:00.000Z")), 1)

        let read = try XCTUnwrap(try store.record(id: id))
        XCTAssertNil(read.rawTranscript)
        XCTAssertNil(read.correctedText)
        XCTAssertNil(read.refinedText)
    }

    /// The index has to forget it too, by the same rule
    /// `testTheIndexForgetsTheTextThatClearTextRemoved` pins for the other two columns -- a
    /// missing trigger column would leave a purged correction findable by a word the row no
    /// longer contains.
    func testTheIndexForgetsTheCorrectedTextThatClearTextRemoved() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(
            startedAt: "2026-08-01T10:00:00.000Z",
            raw: "open cloud code now",
            corrected: "open Claude Code now"
        )).id)
        XCTAssertEqual(try store.search("Claude", limit: 10).map(\.id), [id])

        _ = try store.clearText(startedBefore: at("2026-09-01T00:00:00.000Z"))

        XCTAssertEqual(try store.search("Claude", limit: 10), [])
    }

    func testClearTextRunTwiceReportsNothingLeftToClear() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(startedAt: "2026-08-01T10:00:00.000Z"))

        XCTAssertEqual(try store.clearText(startedBefore: .distantFuture), 1)
        XCTAssertEqual(try store.clearText(startedBefore: .distantFuture), 0)
    }

    // MARK: - What the archive still points at

    func testReferencedAudioFilenamesListsTheRowsThatStillHaveAudio() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(startedAt: "2026-08-01T10:00:00.000Z",
                                         audioFilename: "rec-old.wav"))
        _ = try store.insert(voiceRecord(startedAt: "2026-08-31T10:00:00.000Z",
                                         audioFilename: "rec-fresh.wav"))
        _ = try store.insert(voiceRecord(audioFilename: nil))

        XCTAssertEqual(try store.referencedAudioFilenames(), ["rec-old.wav", "rec-fresh.wav"])
    }

    /// The pairing the retention sweep depends on: what `clearAudio` detaches is exactly what
    /// stops being referenced, and what it spares is exactly what stays pinned.
    func testReferencedAudioFilenamesLosesPreciselyWhatClearAudioDetached() throws {
        let store = try makeStore()
        _ = try store.insert(voiceRecord(startedAt: "2026-08-01T10:00:00.000Z",
                                         audioFilename: "rec-old.wav"))
        _ = try store.insert(voiceRecord(startedAt: "2026-08-31T10:00:00.000Z",
                                         audioFilename: "rec-fresh.wav"))

        let detached = try store.clearAudio(startedBefore: at("2026-08-29T00:00:00.000Z"))

        XCTAssertEqual(detached, ["rec-old.wav"])
        XCTAssertEqual(try store.referencedAudioFilenames(), ["rec-fresh.wav"])
    }

    func testReferencedAudioFilenamesOnAnEmptyArchiveIsEmpty() throws {
        XCTAssertEqual(try makeStore().referencedAudioFilenames(), [])
    }

    // MARK: - The index stays in step with the table

    /// The one that catches a missing delete trigger. The index is asked directly rather than
    /// through the join, because the join hides a stale entry: it would find no `dictation` row
    /// to attach it to and quietly return nothing.
    func testTheIndexForgetsARowThatWasDeleted() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(
            raw: "le xylophone du connecteur, terme inventé pour ce test"
        )).id)
        XCTAssertEqual(try indexedRowIDs(matching: "xylophone"), [id])

        XCTAssertTrue(try store.delete(id: id))

        XCTAssertEqual(try indexedRowIDs(matching: "xylophone"), [])
        XCTAssertEqual(try store.search("xylophone", limit: 10), [])
    }

    /// And a missing update trigger: `clearText` is an UPDATE, so the text it removes has to
    /// leave the index too, or a purged dictation stays findable by a word it no longer contains.
    func testTheIndexForgetsTheTextThatClearTextRemoved() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(
            startedAt: "2026-08-01T10:00:00.000Z",
            raw: "le xylophone du connecteur",
            refined: "Le xylophone du connecteur, reformulé."
        )).id)
        XCTAssertEqual(try indexedRowIDs(matching: "xylophone"), [id])

        _ = try store.clearText(startedBefore: at("2026-09-01T00:00:00.000Z"))

        XCTAssertEqual(try indexedRowIDs(matching: "xylophone"), [])
        XCTAssertEqual(try store.search("xylophone", limit: 10), [])
    }

    /// The same trigger read the other way: an update that does not touch the text must leave the
    /// index holding it. A trigger that only deleted would pass the test above and lose the row
    /// from search here.
    func testARowWhoseAudioWasClearedIsStillFoundByItsText() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.insert(voiceRecord(
            startedAt: "2026-08-01T10:00:00.000Z",
            raw: "le xylophone du connecteur",
            audioFilename: "rec-old.wav"
        )).id)

        _ = try store.clearAudio(startedBefore: at("2026-09-01T00:00:00.000Z"))

        XCTAssertEqual(try indexedRowIDs(matching: "xylophone"), [id])
        XCTAssertEqual(try store.search("xylophone", limit: 10).map(\.id), [id])
    }

    /// Straight from the index, so a stale entry is visible as itself.
    private func indexedRowIDs(matching term: String) throws -> [Int64] {
        try inspect { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM dictation_fts WHERE dictation_fts MATCH ? ORDER BY rowid",
                arguments: [term]
            )
        }
    }

    // MARK: - A database that will not open

    /// A broken archive must not cost a dictation (spec §9's rule for the refiner, one layer
    /// down), so it has to arrive as a value the window can turn into a sentence.
    func testACorruptDatabaseFileSurfacesAsANamedErrorRatherThanACrash() throws {
        try Data("ceci n'est pas une base de données".utf8).write(to: databaseURL)

        XCTAssertThrowsError(try makeStore()) { error in
            guard case .databaseUnusable(let path, let message)? = error as? HistoryStoreError else {
                return XCTFail("expected a named error, got \(error)")
            }
            XCTAssertEqual(path, self.databaseURL.path)
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// The store creates nothing, not even the folder it lives in (§5.4): that is
    /// `Storage.directory(subfolder:)`'s job, and a store that created its own parent would be a
    /// store that could write anywhere it was pointed.
    func testADatabaseInAFolderThatDoesNotExistSurfacesAsANamedError() {
        let missing = directory
            .appendingPathComponent("nowhere-\(UUID().uuidString)")
            .appendingPathComponent("murmure.sqlite")

        XCTAssertThrowsError(try HistoryStore(databaseURL: missing)) { error in
            guard case .databaseUnusable? = error as? HistoryStoreError else {
                return XCTFail("expected a named error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testTheNamedErrorsReadAsSentences() {
        XCTAssertEqual(
            HistoryStoreError.audioFilenameNotRelative("/tmp/x.wav").description,
            #"audio filename "/tmp/x.wav" must be relative to recordings/"#
        )
        XCTAssertTrue(
            HistoryStoreError.databaseUnusable(path: "/tmp/murmure.sqlite", message: "not a database")
                .description
                .contains("/tmp/murmure.sqlite")
        )
    }
}
