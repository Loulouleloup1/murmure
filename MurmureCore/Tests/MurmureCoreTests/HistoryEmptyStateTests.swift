import XCTest
@testable import MurmureCore

/// Everything here works on real files under `NSTemporaryDirectory()` and removes them again.
/// Nothing may reach `~/Library/Application Support/Murmure/`, which holds Louis's real archive
/// and his real recordings -- and the broken-database test below writes an unusable file, which
/// is the one thing that must never land on a real one.
///
/// The tests that need a database open one and let it fail for real, rather than constructing a
/// `HistoryStoreError` by hand: "an archive that will not open surfaces a named error" is a claim
/// about what GRDB does to a file that is not a database, and a hand-built error would prove only
/// that the enum has a case.
final class HistoryEmptyStateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HistoryEmptyStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// A file called `murmure.sqlite` that is not a database, opened for real so the failure below
    /// is SQLite's own rather than one this test invented.
    private func failureFromOpeningAnInvalidDatabase() throws -> HistoryStoreError {
        let url = directory.appendingPathComponent("murmure.sqlite")
        try Data("this is not a database, it is a sentence".utf8).write(to: url)
        do {
            _ = try HistoryStore(databaseURL: url)
            XCTFail("a file that is not a database opened as one")
            throw XCTSkip("unreachable")
        } catch let error as HistoryStoreError {
            return error
        }
    }

    /// A recordings folder holding `count` WAVs with plausible names.
    @discardableResult
    private func makeRecordings(count: Int) throws -> URL {
        let recordings = directory.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        for index in 0..<count {
            try Data("RIFF".utf8).write(
                to: recordings.appendingPathComponent(
                    "rec-2026-08-31T18-07-\(String(format: "%02d", index)).000Z.wav"))
        }
        return recordings
    }

    private func state(
        archiveFailure: HistoryStoreError? = nil,
        typed: String = "",
        hasRows: Bool = false,
        orphaned: @autoclosure () -> Int = 0
    ) -> HistoryEmptyState? {
        HistoryEmptyState.current(
            archiveFailure: archiveFailure,
            query: HistoryQuery(typed: typed),
            hasRows: hasRows,
            orphanedRecordings: orphaned)
    }

    // MARK: - The archive that will not open

    /// Given a `murmure.sqlite` that is not a database, when the pane asks what to say, then the
    /// sentence names the file.
    func testAnArchiveThatWillNotOpenIsNamedByItsFile() throws {
        let failure = try failureFromOpeningAnInvalidDatabase()

        let message = state(archiveFailure: failure)?.description

        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("murmure.sqlite"), message!)
        // The full path is what the log line carries; the pane gets the name. A home directory
        // spends a line and a half of the sentence saying nothing about the failure.
        XCTAssertFalse(message!.contains(directory.path), message!)
    }

    /// The failure keeps SQLite's own words, so the sentence says WHY rather than only THAT.
    func testTheArchiveFailureCarriesTheReasonItFailedWith() throws {
        let failure = try failureFromOpeningAnInvalidDatabase()
        guard case .databaseUnusable(_, let reason) = failure else {
            return XCTFail("expected a databaseUnusable, got \(failure)")
        }

        let message = state(archiveFailure: failure)?.description

        XCTAssertFalse(reason.isEmpty, "SQLite said nothing about why it refused the file")
        XCTAssertTrue(message!.contains(reason), message!)
    }

    /// The sentence says the dictation half still works -- which is the whole reason
    /// `DictationController` keeps the store optional. An empty History pane beside a hotkey that
    /// still pastes otherwise reads as "Murmure is broken".
    func testTheArchiveFailureSaysDictationStillWorks() throws {
        let message = try state(archiveFailure: failureFromOpeningAnInvalidDatabase())!.description

        XCTAssertTrue(message.lowercased().contains("dictation still works"), message)
    }

    /// The precedence that matters: a store that never answered may not be reported as an empty
    /// archive or as a search that found nothing. Both would blame the wrong thing.
    func testAnArchiveThatWillNotOpenOutranksEveryOtherEmptyState() throws {
        let failure = try failureFromOpeningAnInvalidDatabase()

        let unfiltered = state(archiveFailure: failure, typed: "", orphaned: 42)
        let searched = state(archiveFailure: failure, typed: "kubernetes")
        let unsearchable = state(archiveFailure: failure, typed: "...")

        for produced in [unfiltered, searched, unsearchable] {
            guard case .archiveUnusable = produced else {
                return XCTFail("expected archiveUnusable, got \(String(describing: produced))")
            }
        }
    }

    // MARK: - The empty archive, and the recordings that outlived it

    /// §5.5: the orphans get no rows, so the empty state is where they are said to exist. Given a
    /// folder holding three, when the archive is empty, then the sentence carries the three.
    func testAnEmptyArchiveNamesTheRecordingsThatHaveNoRow() throws {
        let recordings = try makeRecordings(count: 3)

        let message = state(
            orphaned: HistoryEmptyState.orphanedRecordingCount(in: recordings))?.description

        XCTAssertEqual(
            message,
            "No dictations yet. 3 recordings are still in the recordings folder with no "
                + "transcript anywhere, so they cannot be listed here.")
    }

    func testOneOrphanedRecordingIsSaidInTheSingular() throws {
        let recordings = try makeRecordings(count: 1)

        let message = state(
            orphaned: HistoryEmptyState.orphanedRecordingCount(in: recordings))?.description

        XCTAssertEqual(
            message,
            "No dictations yet. One recording is still in the recordings folder with no "
                + "transcript anywhere, so it cannot be listed here.")
    }

    /// A fresh install says the short thing and nothing about a folder that holds nothing.
    func testAnEmptyArchiveWithNoRecordingsSaysOnlyThat() throws {
        let recordings = try makeRecordings(count: 0)

        let message = state(
            orphaned: HistoryEmptyState.orphanedRecordingCount(in: recordings))?.description

        XCTAssertEqual(message, "No dictations yet.")
    }

    /// **The count is read when the message is built, never frozen.** The plan wrote "98 orphaned
    /// recordings" on 2026-09-01; the folder held 200 two days later. Given a folder that grows
    /// between two draws, when the pane asks twice, then the two sentences carry different numbers.
    func testTheOrphanCountIsReadWhenTheMessageIsBuiltAndNotFrozen() throws {
        let recordings = try makeRecordings(count: 2)
        let first = state(
            orphaned: HistoryEmptyState.orphanedRecordingCount(in: recordings))?.description

        try Data("RIFF".utf8).write(
            to: recordings.appendingPathComponent("rec-2026-09-03T11-18-00.000Z.wav"))
        let second = state(
            orphaned: HistoryEmptyState.orphanedRecordingCount(in: recordings))?.description

        XCTAssertTrue(first!.contains("2 recordings"), first!)
        XCTAssertTrue(second!.contains("3 recordings"), second!)
    }

    /// The count refuses what `RetentionPurge`'s sweep refuses, and for the same reason: anything
    /// in that folder that Murmure did not write is not Murmure's to count or to delete.
    func testTheOrphanCountIgnoresWhatMurmureDidNotWrite() throws {
        let recordings = try makeRecordings(count: 1)
        try Data("notes".utf8).write(to: recordings.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: recordings.appendingPathComponent(".hidden.wav"))
        try FileManager.default.createDirectory(
            at: recordings.appendingPathComponent("archive.wav", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: recordings.appendingPathComponent("link.wav"),
            withDestinationURL: recordings.appendingPathComponent(
                "rec-2026-08-31T18-07-00.000Z.wav"))

        XCTAssertEqual(HistoryEmptyState.orphanedRecordingCount(in: recordings), 1)
    }

    /// A folder that is not there yet is a fresh install. Counting it creates nothing -- the same
    /// rule `Storage.url(subfolder:)` exists to enforce.
    func testCountingARecordingsFolderThatDoesNotExistIsZeroAndCreatesNothing() {
        let absent = directory.appendingPathComponent("recordings", isDirectory: true)

        XCTAssertEqual(HistoryEmptyState.orphanedRecordingCount(in: absent), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    // MARK: - The two ways a search comes back empty

    /// `HistoryQuery` draws this line and the pane has to keep it: a query the store was never
    /// asked may not be reported as a query that found nothing.
    func testAnUnsearchableQueryIsNotTheSameEmptyStateAsNoMatch() {
        let unsearchable = state(typed: "...!?")
        let noMatch = state(typed: "kubernetes")

        XCTAssertEqual(unsearchable, .unsearchableQuery)
        XCTAssertEqual(noMatch, .noMatch)
        XCTAssertNotEqual(unsearchable!.description, noMatch!.description)
    }

    /// A search that matched nothing says nothing about the archive being empty -- it is not, and
    /// a message that conflated the two would send Louis looking for a history he still has.
    func testASearchThatMatchedNothingDoesNotClaimTheArchiveIsEmpty() {
        let message = state(typed: "kubernetes", orphaned: 200)!.description

        XCTAssertFalse(message.contains("No dictations yet"), message)
        XCTAssertFalse(message.contains("recordings folder"), message)
    }

    /// The one case with nothing to say. A pane with rows in it draws no empty state at all.
    func testAListWithRowsInItHasNoEmptyState() {
        XCTAssertNil(state(hasRows: true))
        XCTAssertNil(state(typed: "kubernetes", hasRows: true))
    }
}
