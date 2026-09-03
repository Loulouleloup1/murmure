import XCTest
@testable import MurmureCore

/// Real files under `NSTemporaryDirectory()`, created and deleted for real: "the WAV went away
/// underneath the row" is a behaviour, and a test that only asked whether the row carries a
/// filename would pass with the file still on the disk.
final class HistoryAudioFileTests: XCTestCase {
    private var recordings: URL!

    override func setUpWithError() throws {
        recordings = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HistoryAudioFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: recordings)
    }

    /// A row with text on both sides of the lens, so what a missing file costs can be measured
    /// against what it does not.
    private func record(audio: String?) -> HistoryRecord {
        HistoryRecord(
            startedAt: HistoryTimestamp.date(from: "2026-09-01T14:42:00.000Z")!,
            durationSeconds: 4.2,
            outcome: .inserted,
            modeKey: "prompt",
            modeName: "Prompt",
            sttModel: "large-v3-turbo",
            rawTranscript: "on relance le pipeline demain matin",
            refinedText: "On relance le pipeline demain matin.",
            insertedCharacters: 36,
            audioFilename: audio)
    }

    private func writeWav(_ name: String) throws {
        try Data("RIFF".utf8).write(to: recordings.appendingPathComponent(name))
    }

    /// The T9 behaviour, in one test. Given a row whose recording is on the disk, when the file is
    /// deleted underneath it, then the audio is gone and the transcript is untouched -- because
    /// the transcript is the row.
    func testARowWhoseWavIsDeletedUnderneathItLosesItsAudioAndKeepsItsText() throws {
        let name = "rec-2026-09-01T14-42-00.000Z.wav"
        try writeWav(name)
        let record = record(audio: name)
        XCTAssertNotNil(HistoryAudioFile.url(for: record, inRecordings: recordings))

        try FileManager.default.removeItem(at: recordings.appendingPathComponent(name))

        XCTAssertNil(HistoryAudioFile.url(for: record, inRecordings: recordings))
        XCTAssertEqual(
            HistoryDetail.text(.refined, of: record), "On relance le pipeline demain matin.")
        XCTAssertEqual(HistoryDetail.text(.raw, of: record), "on relance le pipeline demain matin")
        // Re-refining works from the text, which is exactly why D12 chose it over re-transcribing:
        // the expensive variant is the one that stops working when the audio goes.
        XCTAssertTrue(HistoryDetail.canProcessAgain(record))
    }

    /// The state most of this list is in for twenty-seven of its thirty days: the audio was purged
    /// and the row no longer names one.
    func testARowThatNoLongerNamesAudioHasNoFile() {
        XCTAssertNil(HistoryAudioFile.url(for: record(audio: nil), inRecordings: recordings))
    }

    /// The row names a file that was never there -- a row written by hand, or a WAV deleted
    /// before the pane was ever opened. Same answer as a purge, because Play and Reveal have one
    /// disabled state between them.
    func testARowNamingAFileThatIsNotThereHasNoFile() {
        XCTAssertNil(
            HistoryAudioFile.url(
                for: record(audio: "rec-never-written.wav"), inRecordings: recordings))
    }

    /// `HistoryRecord.audioURL(inRecordings:)` refuses an upward-reaching name, and this must not
    /// undo that by finding the file it points at. Given a real WAV outside the folder, when a row
    /// names it through `..`, then there is nothing to play.
    func testAnUpwardReachingFilenameIsNotResolvedEvenWhenTheFileExists() throws {
        let outside = recordings.deletingLastPathComponent()
            .appendingPathComponent("HistoryAudioFileTests-outside-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertNil(
            HistoryAudioFile.url(
                for: record(audio: "../\(outside.lastPathComponent)"), inRecordings: recordings))
    }
}
