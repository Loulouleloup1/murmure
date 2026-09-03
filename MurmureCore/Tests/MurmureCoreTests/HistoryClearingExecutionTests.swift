import XCTest
@testable import MurmureCore

/// The two Advanced-pane buttons, carried out — `RetentionPurge.clearNow`.
///
/// `HistoryClearingTests` already covers the words (which action asks, what each destroys). This
/// file covers the only thing the words cannot: that the button does what its summary says and
/// **nothing else**. Each summary promises the other half is untouched, and that promise is a
/// pair of cutoffs one wrong sign away from deleting a month of Louis's text from a button
/// labelled "Delete All Recordings".
///
/// A workspace of its own rather than `RetentionPurgeTests`': the subject is different (a click,
/// not a timer) and a shared fixture file is a shared edit. The `precondition` below is the same
/// lock that file has, and for the same reason — nothing here may reach
/// `~/Library/Application Support/Murmure/`.
final class HistoryClearingExecutionTests: XCTestCase {
    private var workspace: URL!
    private var recordings: URL!
    private var databaseURL: URL!

    /// The instant of the click. Fixed, so "everything that exists as of now" is arithmetic on a
    /// value the test states rather than on the wall clock.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)  // 2026-09-02T12:00:00Z

    override func setUpWithError() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        workspace = temporary
            .appendingPathComponent("HistoryClearingExecutionTests-\(UUID().uuidString)",
                                    isDirectory: true)
        precondition(
            workspace.resolvingSymlinksInPath().path.hasPrefix(temporary.path),
            "a clearing test may only ever work inside NSTemporaryDirectory()")
        recordings = workspace.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        databaseURL = workspace.appendingPathComponent("murmure.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Helpers

    private func makeFile(_ name: String, modified: Date) throws {
        let url = recordings.appendingPathComponent(name)
        try Data("RIFF-not-really-a-wav".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func days(_ count: Double) -> Date {
        now.addingTimeInterval(-count * 24 * 60 * 60)
    }

    @discardableResult
    private func insert(
        _ store: HistoryStore, startedAt: Date, audioFilename: String?, raw: String?
    ) throws -> Int64 {
        try XCTUnwrap(try store.insert(HistoryRecord(
            startedAt: startedAt,
            durationSeconds: 29.7,
            outcome: .inserted,
            modeKey: "voice",
            modeName: "Voice",
            sttModel: "large-v3-turbo",
            rawTranscript: raw,
            insertedCharacters: raw?.count ?? 0,
            audioFilename: audioFilename
        )).id)
    }

    private func filesOnDisk() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: recordings.path).sorted()
    }

    private func clear(_ action: HistoryClearing, _ store: HistoryStore) throws
        -> RetentionPurgeReport {
        try RetentionPurge.clearNow(action, store: store, recordings: recordings, now: now)
    }

    // MARK: - Delete All Recordings

    /// "Deletes every recording in the folder now, including ones no dictation points at."
    ///
    /// Both halves in one case, because the summary makes one promise: the WAV from ten minutes
    /// ago that a row still pins goes, and so does the orphan from before the archive existed.
    /// The 3-day sweep would have taken neither — the first is too new, the second is pinned by
    /// nothing but is the case `RetentionPurge` was written for and would only go once old.
    func testDeletingRecordingsTakesTheOnesTooNewForTheAutomaticSweep() throws {
        // Given -- one recording from ten minutes ago, pinned by a row, and one ancient orphan
        let store = try HistoryStore(databaseURL: databaseURL)
        try makeFile("rec-fresh.wav", modified: now.addingTimeInterval(-600))
        try makeFile("rec-orphan.wav", modified: days(400))
        try insert(store, startedAt: now.addingTimeInterval(-600),
                   audioFilename: "rec-fresh.wav", raw: "le connecteur de staging")

        // When
        let report = try clear(.recordings, store)

        // Then
        XCTAssertEqual(try filesOnDisk(), [])
        XCTAssertEqual(report.audioFilesDeleted, 2)
        XCTAssertEqual(report.audioDeletionFailures, [])
    }

    /// "Transcripts are untouched." The load-bearing half of that button's summary, and the one a
    /// wrong cutoff would break silently: the row would still be there, just empty.
    func testDeletingRecordingsLeavesEveryWordOfTextWhereItWas() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        try makeFile("rec-fresh.wav", modified: now.addingTimeInterval(-600))
        let id = try insert(store, startedAt: now.addingTimeInterval(-600),
                            audioFilename: "rec-fresh.wav", raw: "le connecteur de staging")

        // When
        let report = try clear(.recordings, store)

        // Then
        XCTAssertEqual(report.textRowsCleared, 0)
        let row = try XCTUnwrap(store.record(id: id))
        XCTAssertEqual(row.rawTranscript, "le connecteur de staging")
        // The row survives, and it has stopped claiming a file that is gone -- which is what makes
        // History disable Play rather than offer a recording that will not open.
        XCTAssertNil(row.audioFilename)
    }

    // MARK: - Delete All Transcripts

    /// "Deletes the raw and refined text of every dictation, including today's." Including today's
    /// is the whole difference from the 30-day sweep, so the fixture is a dictation from a minute
    /// ago.
    func testDeletingTranscriptsTakesTodaysTextToo() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        let recent = try insert(store, startedAt: now.addingTimeInterval(-60),
                                audioFilename: nil, raw: "ce que j'ai dicté il y a une minute")
        let old = try insert(store, startedAt: days(45), audioFilename: nil, raw: "le mois dernier")

        // When
        let report = try clear(.transcripts, store)

        // Then
        XCTAssertEqual(report.textRowsCleared, 2)
        XCTAssertNil(try XCTUnwrap(store.record(id: recent)).rawTranscript)
        XCTAssertNil(try XCTUnwrap(store.record(id: old)).rawTranscript)
    }

    /// "The rows stay — date, duration and mode." What separates this button from deleting the
    /// archive: History still shows that a dictation happened, it just has nothing to read.
    func testDeletingTranscriptsKeepsTheRowsAndTheirMetadata() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        let id = try insert(store, startedAt: now.addingTimeInterval(-60),
                            audioFilename: nil, raw: "ce que j'ai dicté")

        // When
        _ = try clear(.transcripts, store)

        // Then
        let row = try XCTUnwrap(store.record(id: id))
        XCTAssertEqual(row.modeName, "Voice")
        XCTAssertEqual(row.durationSeconds, 29.7)
        XCTAssertEqual(row.startedAt.timeIntervalSince1970,
                       now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1)
    }

    /// "Recordings are untouched" — the transcripts dialog says so in as many words, and this is
    /// the assertion behind the sentence. A `.distantPast` audio cutoff that were `now` instead
    /// would delete 730 MB from a button that promised not to.
    func testDeletingTranscriptsLeavesEveryRecordingOnDisk() throws {
        // Given -- one file young enough for any sweep, one old enough for the 3-day one
        let store = try HistoryStore(databaseURL: databaseURL)
        try makeFile("rec-fresh.wav", modified: now.addingTimeInterval(-600))
        try makeFile("rec-old.wav", modified: days(400))
        try insert(store, startedAt: now.addingTimeInterval(-600),
                   audioFilename: "rec-fresh.wav", raw: "le connecteur")

        // When
        let report = try clear(.transcripts, store)

        // Then
        XCTAssertEqual(try filesOnDisk(), ["rec-fresh.wav", "rec-old.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 0)
        // And the row still points at its recording: `clearAudio` detached nothing.
        XCTAssertEqual(
            try store.referencedAudioFilenames(), ["rec-fresh.wav"])
    }

    // MARK: - The number the dialog says out loud

    /// `HistoryClearing`'s dialog names a count, and the count has to be what will actually be
    /// destroyed. Rows the 30-day sweep already emptied are still rows — counting them would put
    /// a number in a warning that overstates the damage by everything the app deleted on its own.
    func testTheCountIsTheDictationsWithTextLeftAndNotTheRows() throws {
        // Given -- three rows, one of which the automatic sweep already emptied
        let store = try HistoryStore(databaseURL: databaseURL)
        try insert(store, startedAt: days(1), audioFilename: nil, raw: "aujourd'hui")
        try insert(store, startedAt: days(2), audioFilename: nil, raw: "avant-hier")
        try insert(store, startedAt: days(60), audioFilename: nil, raw: nil)

        // Then
        XCTAssertEqual(try store.countWithText(), 2)
    }

    /// After the button, there is nothing left to count — which is what disables it, so a second
    /// press cannot open a dialog about zero dictations.
    func testClearingTranscriptsLeavesNothingToCount() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        try insert(store, startedAt: days(1), audioFilename: nil, raw: "aujourd'hui")

        // When
        _ = try clear(.transcripts, store)

        // Then
        XCTAssertEqual(try store.countWithText(), 0)
    }

    /// The count and the delete share one predicate, so they cannot drift: whatever
    /// `countWithText` promised is exactly what `clearText` reports having taken.
    func testTheCountBeforeMatchesTheRowsTheClearReports() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        try insert(store, startedAt: days(1), audioFilename: nil, raw: "un")
        try insert(store, startedAt: days(2), audioFilename: nil, raw: "deux")
        try insert(store, startedAt: days(3), audioFilename: nil, raw: nil)
        let expected = try store.countWithText()

        // When
        let report = try clear(.transcripts, store)

        // Then
        XCTAssertEqual(report.textRowsCleared, expected)
    }

    // MARK: - The two together

    /// Both buttons, in either order, leave the same nothing — and neither throws on an archive
    /// that has already been emptied. Louis pressing one twice is not an error state.
    func testRunningBothLeavesRowsWithNeitherTextNorAudioAndIsIdempotent() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        try makeFile("rec-fresh.wav", modified: now.addingTimeInterval(-600))
        let id = try insert(store, startedAt: now.addingTimeInterval(-600),
                            audioFilename: "rec-fresh.wav", raw: "le connecteur")

        // When
        _ = try clear(.transcripts, store)
        _ = try clear(.recordings, store)
        let second = try clear(.recordings, store)
        let secondText = try clear(.transcripts, store)

        // Then
        XCTAssertEqual(try filesOnDisk(), [])
        let row = try XCTUnwrap(store.record(id: id))
        XCTAssertNil(row.rawTranscript)
        XCTAssertNil(row.audioFilename)
        // A second press finds nothing to do rather than reporting work it did not do.
        XCTAssertEqual(second.audioFilesDeleted, 0)
        XCTAssertEqual(secondText.textRowsCleared, 0)
    }

    /// A folder that is not there is a fresh install, not a failure — the same answer
    /// `RetentionPurge.run` gives, and the button must not be the thing that creates it.
    func testDeletingRecordingsWithNoFolderIsQuietAndCreatesNothing() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        try FileManager.default.removeItem(at: recordings)

        // When
        let report = try clear(.recordings, store)

        // Then
        XCTAssertEqual(report.audioFilesDeleted, 0)
        XCTAssertNil(report.recordingsUnreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path))
    }

    /// The directory sweep's own refusals still apply to a button: a folder holding something
    /// Murmure did not write is not a folder to empty. `.wav` is the only extension `WavWriter`
    /// produces, and "delete all recordings" means the recordings.
    func testDeletingRecordingsRefusesFilesMurmureDidNotWrite() throws {
        // Given
        let store = try HistoryStore(databaseURL: databaseURL)
        try makeFile("rec-fresh.wav", modified: now.addingTimeInterval(-600))
        try makeFile("notes.txt", modified: now.addingTimeInterval(-600))

        // When
        _ = try clear(.recordings, store)

        // Then
        XCTAssertEqual(try filesOnDisk(), ["notes.txt"])
    }
}
