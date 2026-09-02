import XCTest
@testable import MurmureCore

/// The retention purge, tested by what is left on disk and in the rows rather than by what was
/// called. Every case here builds a folder of WAVs with known modification times and a database of
/// rows with known timestamps, runs one pass, and looks at the two.
///
/// **Nothing here may reach `~/Library/Application Support/Murmure/`, and that is structural
/// rather than remembered.** `RetentionPurge.run` takes `recordings:` with no default and
/// `HistoryStore(databaseURL:)` takes its file with no default, so a path can only be reached by
/// being named -- and `makeWorkspace()` below is the only thing in this file that names one. Its
/// `precondition` is the second lock: a workspace that is not under `NSTemporaryDirectory()` stops
/// the process instead of deleting Louis's recordings.
final class RetentionPurgeTests: XCTestCase {
    private var workspace: URL!
    private var recordings: URL!
    private var databaseURL: URL!

    /// A fixed instant, so every age in this file is arithmetic on a value the test states rather
    /// than on the wall clock. `RetentionPurge.run` takes `now:` for the same reason: a purge that
    /// read `Date()` inside itself could not be asked about the day before yesterday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)  // 2026-09-02T12:00:00Z

    override func setUpWithError() throws {
        workspace = try makeWorkspace()
        recordings = workspace.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        databaseURL = workspace.appendingPathComponent("murmure.sqlite")
    }

    override func tearDownWithError() throws {
        // A test that made a file undeletable on purpose has to hand the folder back deletable,
        // or every later run leaks a temporary directory.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil) {
            for entry in entries {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: entry.path)
            }
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Helpers

    /// The only place in this file that names a directory, and it cannot name a real one.
    private func makeWorkspace() throws -> URL {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let directory = temporary
            .appendingPathComponent("RetentionPurgeTests-\(UUID().uuidString)", isDirectory: true)
        precondition(
            directory.resolvingSymlinksInPath().path.hasPrefix(temporary.path),
            "a retention test may only ever work inside NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func days(_ count: Double) -> Date {
        now.addingTimeInterval(-count * 24 * 60 * 60)
    }

    /// A file in `recordings/`, with the modification time the case is about.
    @discardableResult
    private func makeFile(_ name: String, modified: Date) throws -> URL {
        let url = recordings.appendingPathComponent(name)
        try Data("RIFF-not-really-a-wav".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: databaseURL)
    }

    @discardableResult
    private func insert(
        _ store: HistoryStore,
        startedAt: Date,
        audioFilename: String? = nil,
        raw: String? = "il faut brancher le connecteur sur le endpoint de staging"
    ) throws -> Int64 {
        try XCTUnwrap(try store.insert(HistoryRecord(
            startedAt: startedAt,
            durationSeconds: 29.7,
            outcome: .inserted,
            modeKey: "voice",
            modeName: "Voice",
            sttModel: "large-v3-turbo",
            rawTranscript: raw,
            insertedCharacters: 57,
            audioFilename: audioFilename
        )).id)
    }

    private func filesOnDisk() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: recordings.path)
            .sorted()
    }

    private func run(_ store: HistoryStore) throws -> RetentionPurgeReport {
        try RetentionPurge.run(store: store, recordings: recordings, now: now)
    }

    // MARK: - The policy itself

    func testThePolicyIsThreeDaysOfAudioAndThirtyDaysOfText() {
        XCTAssertEqual(RetentionPurge.audioLifetime, 3 * 24 * 60 * 60)
        XCTAssertEqual(RetentionPurge.textLifetime, 30 * 24 * 60 * 60)
    }

    // MARK: - The orphan sweep, which is the whole reason the rows are not enough

    /// The 614 MB case. A WAV recorded before the history feature shipped has no row, so no
    /// row-derived filename will ever name it, and a purge that only followed `clearAudio` would
    /// leave it there for ever.
    func testAnOrphanOlderThanThreeDaysIsDeletedThoughNoRowNamesIt() throws {
        let store = try makeStore()
        try makeFile("rec-orphan.wav", modified: days(4))

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), [])
        XCTAssertEqual(report.audioFilesDeleted, 1)
        XCTAssertEqual(report.audioDeletionFailures, [])
    }

    func testAnOrphanYoungerThanThreeDaysSurvives() throws {
        let store = try makeStore()
        try makeFile("rec-orphan.wav", modified: days(2))

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), ["rec-orphan.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 0)
    }

    /// The boundary, both sides of it, in one case so neither can be satisfied alone. `clearAudio`
    /// compares `startedAt < cutoff`, and the sweep has to compare modification times the same
    /// strict way or the two halves of one policy would disagree about the same instant.
    func testAFileExactlyThreeDaysOldSurvivesAndOneASecondOlderGoes() throws {
        let store = try makeStore()
        try makeFile("rec-exactly.wav", modified: days(3))
        try makeFile("rec-a-second-older.wav", modified: days(3).addingTimeInterval(-1))

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), ["rec-exactly.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 1)
    }

    // MARK: - Pinning: the database outranks the modification time

    /// The case that makes a clock skew or a file copy harmless. The row is inside its window, so
    /// the pane still offers this recording -- and an mtime from last month must not be able to
    /// delete it underneath that offer.
    func testARowInsideItsWindowPinsItsFileHoweverOldTheFileLooks() throws {
        let store = try makeStore()
        try makeFile("rec-pinned.wav", modified: days(400))
        try insert(store, startedAt: days(1), audioFilename: "rec-pinned.wav")

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), ["rec-pinned.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 0)
        XCTAssertEqual(try store.referencedAudioFilenames(), ["rec-pinned.wav"])
    }

    /// And the same rule read the other way: once the row says the dictation is old enough, a
    /// modification time from this morning does not save the file. A WAV that was copied, or
    /// touched by a backup, is still audio from a dictation past its three days.
    func testARowPastItsWindowLosesItsFileEvenWhenTheFileLooksBrandNew() throws {
        let store = try makeStore()
        try makeFile("rec-touched.wav", modified: now)
        let id = try insert(store, startedAt: days(4), audioFilename: "rec-touched.wav")

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), [])
        XCTAssertEqual(report.audioFilesDeleted, 1)
        XCTAssertNil(try store.record(id: id)?.audioFilename)
        XCTAssertEqual(
            try store.record(id: id)?.rawTranscript,
            "il faut brancher le connecteur sur le endpoint de staging",
            "audio expires on its own clock -- the text has twenty-seven days left")
    }

    /// One pass, two rows, one folder: the whole policy at once, which is the case that catches a
    /// purge that got each half right in isolation and applied the wrong cutoff to one of them.
    func testOnePassKeepsTheYoungRowsAudioAndTakesTheOldRowsAudioAndTheAncientRowsText() throws {
        let store = try makeStore()
        try makeFile("rec-young.wav", modified: days(1))
        try makeFile("rec-old.wav", modified: days(5))
        try makeFile("rec-ancient.wav", modified: days(40))
        let young = try insert(store, startedAt: days(1), audioFilename: "rec-young.wav")
        let old = try insert(store, startedAt: days(5), audioFilename: "rec-old.wav")
        let ancient = try insert(store, startedAt: days(40), audioFilename: "rec-ancient.wav")

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), ["rec-young.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 2)
        XCTAssertEqual(report.textRowsCleared, 1)

        XCTAssertEqual(try store.record(id: young)?.audioFilename, "rec-young.wav")
        XCTAssertNotNil(try store.record(id: young)?.rawTranscript)

        XCTAssertNil(try store.record(id: old)?.audioFilename)
        XCTAssertNotNil(try store.record(id: old)?.rawTranscript)

        XCTAssertNil(try store.record(id: ancient)?.audioFilename)
        XCTAssertNil(try store.record(id: ancient)?.rawTranscript,
                     "thirty days is the text's window and this dictation is forty days old")
        XCTAssertNotNil(try store.record(id: ancient), "the row itself survives for ever")
    }

    /// The text boundary on its own, because the case above only ever exercises one side of it.
    func testTextExactlyThirtyDaysOldSurvivesAndTextOlderThanThatDoesNot() throws {
        let store = try makeStore()
        let boundary = try insert(store, startedAt: days(30), raw: "le connecteur est déployé")
        let past = try insert(
            store, startedAt: days(30).addingTimeInterval(-1), raw: "le connecteur est déployé")

        let report = try run(store)

        XCTAssertEqual(report.textRowsCleared, 1)
        XCTAssertEqual(try store.record(id: boundary)?.rawTranscript, "le connecteur est déployé")
        XCTAssertNil(try store.record(id: past)?.rawTranscript)
    }

    // MARK: - What the sweep must refuse to touch

    func testAFileThatIsNotAWavIsLeftAloneHoweverOldItIs() throws {
        let store = try makeStore()
        try makeFile("notes.txt", modified: days(400))
        try makeFile("rec-old.wav", modified: days(400))

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), ["notes.txt"])
        XCTAssertEqual(report.audioFilesDeleted, 1)
    }

    /// No recursion. A folder inside `recordings/` is not something Murmure writes, and a sweep
    /// that descended into one would be deleting files from somewhere it was never pointed at.
    func testASubfolderIsNotDescendedIntoAndIsNotItselfDeleted() throws {
        let store = try makeStore()
        let sub = recordings.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let buried = sub.appendingPathComponent("rec-buried.wav")
        try Data("RIFF".utf8).write(to: buried)
        try FileManager.default.setAttributes(
            [.modificationDate: days(400)], ofItemAtPath: buried.path)
        try FileManager.default.setAttributes(
            [.modificationDate: days(400)], ofItemAtPath: sub.path)

        let report = try run(store)

        XCTAssertTrue(FileManager.default.fileExists(atPath: buried.path))
        XCTAssertEqual(try filesOnDisk(), ["archive"])
        XCTAssertEqual(report.audioFilesDeleted, 0)
    }

    /// A folder whose own name ends in `.wav` is still a folder, and deleting it would take
    /// whatever is inside it with no age check at all.
    func testAFolderNamedLikeAWavIsNotDeleted() throws {
        let store = try makeStore()
        let trap = recordings.appendingPathComponent("rec-trap.wav", isDirectory: true)
        try FileManager.default.createDirectory(at: trap, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: days(400)], ofItemAtPath: trap.path)

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), ["rec-trap.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 0)
    }

    /// Symlinks are never followed. The link is not a regular file, so it is skipped -- and the
    /// file it points at, which is outside the folder the purge was pointed at, is untouched.
    func testASymlinkIsNeitherFollowedNorDeleted() throws {
        let store = try makeStore()
        let outside = workspace.appendingPathComponent("elsewhere.wav")
        try Data("RIFF".utf8).write(to: outside)
        try FileManager.default.setAttributes(
            [.modificationDate: days(400)], ofItemAtPath: outside.path)
        let link = recordings.appendingPathComponent("rec-link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let report = try run(store)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "the purge was pointed at recordings/, not at whatever a link reaches")
        XCTAssertEqual(try filesOnDisk(), ["rec-link.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 0)
    }

    /// Murmure writes no dot-files, so one in `recordings/` came from somewhere else and is not
    /// the purge's to delete however old it is.
    func testAHiddenFileIsLeftAloneHoweverOldItIs() throws {
        let store = try makeStore()
        try makeFile(".rec-hidden.wav", modified: days(400))
        try makeFile("rec-plain.wav", modified: days(400))

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), [".rec-hidden.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 1)
    }

    // MARK: - Nothing to do, and nowhere to do it

    func testAnEmptyFolderAndAnEmptyArchiveAreAQuietNoOp() throws {
        let store = try makeStore()

        let report = try run(store)

        XCTAssertEqual(report, RetentionPurgeReport())
        XCTAssertEqual(try filesOnDisk(), [])
    }

    /// A fresh install has no `recordings/` until the first dictation writes one. That is not a
    /// failure and must not be reported as one -- and the row half of the purge still has to run.
    func testAMissingRecordingsFolderIsNotAFailureAndTheRowsAreStillPurged() throws {
        let store = try makeStore()
        let id = try insert(store, startedAt: days(40))
        try FileManager.default.removeItem(at: recordings)

        let report = try run(store)

        XCTAssertNil(report.recordingsUnreadable)
        XCTAssertEqual(report.audioFilesDeleted, 0)
        XCTAssertEqual(report.textRowsCleared, 1)
        XCTAssertNil(try store.record(id: id)?.rawTranscript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path),
                       "the purge creates nothing -- that is AudioRecorder's job")
    }

    /// Absolute timestamps only, so the second pass has nothing left to find. There is no
    /// "last run" marker anywhere: the data's own timestamps are the state, which is what makes a
    /// Mac that was closed for a week purge correctly on the next launch instead of skipping.
    func testASecondPassAtTheSameInstantFindsNothingLeftToDo() throws {
        let store = try makeStore()
        try makeFile("rec-old.wav", modified: days(5))
        try insert(store, startedAt: days(40), audioFilename: "rec-old.wav")

        let first = try run(store)
        let second = try run(store)

        XCTAssertEqual(first.audioFilesDeleted, 1)
        XCTAssertEqual(first.textRowsCleared, 1)
        XCTAssertEqual(second, RetentionPurgeReport(),
                       "the same instant twice must be one purge, not two")
    }

    // MARK: - Failure: one file that cannot go must not abandon the rest

    func testAFileThatCannotBeDeletedIsReportedAndTheRestOfTheSweepStillRuns() throws {
        let store = try makeStore()
        let stubborn = try makeFile("rec-stubborn.wav", modified: days(5))
        try makeFile("rec-willing.wav", modified: days(5))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stubborn.path)

        let report = try run(store)

        XCTAssertEqual(try filesOnDisk(), ["rec-stubborn.wav"])
        XCTAssertEqual(report.audioFilesDeleted, 1, "the willing one still went")
        XCTAssertEqual(report.audioDeletionFailures.map(\.filename), ["rec-stubborn.wav"])
        XCTAssertFalse(try XCTUnwrap(report.audioDeletionFailures.first).message.isEmpty,
                       "a failure a caller cannot describe is a failure it cannot log")
    }

    /// "Tried twelve, failed twelve" has to be readable as itself. A report that only counted
    /// attempts would say the same thing as a clean sweep.
    func testASweepThatDeletedNothingAtAllIsNotReportedAsASweepThatSucceeded() throws {
        let store = try makeStore()
        // Created in an order that is neither alphabetical nor its reverse, so a report that
        // simply echoed the order the file system handed the folder back in would have to be
        // lucky four times over to look sorted.
        for name in ["rec-c.wav", "rec-a.wav", "rec-d.wav", "rec-b.wav"] {
            let url = try makeFile(name, modified: days(5))
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        }

        let report = try run(store)

        XCTAssertEqual(report.audioFilesDeleted, 0)
        XCTAssertEqual(report.audioDeletionFailures.map(\.filename),
                       ["rec-a.wav", "rec-b.wav", "rec-c.wav", "rec-d.wav"],
                       "reported in filename order, so a log line is the same twice running")
        XCTAssertEqual(try filesOnDisk(),
                       ["rec-a.wav", "rec-b.wav", "rec-c.wav", "rec-d.wav"])
    }
}
