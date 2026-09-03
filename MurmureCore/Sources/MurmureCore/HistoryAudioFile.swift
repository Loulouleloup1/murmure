import Foundation

/// Whether a row's recording is still on the disk, which is a different question from whether the
/// row names one.
///
/// **The normal state of most of this list, not an error.** Audio is deleted after three days and
/// the text after thirty (the retention decision of 2026-09-01), so for twenty-seven days out of
/// thirty a dictation is a row with live text and no file. A row can also lose its WAV between two
/// draws of the same pane: the purge runs at launch, and the Finder is one keystroke away.
///
/// **Nothing about the row's text depends on this.** The transcript is the row -- design notes
/// §1.3 -- so what a missing file costs is Play and Reveal, and nothing else: not the row, not its
/// metadata, not Copy, not Process again, which re-refines text and was deliberately chosen over
/// re-transcribing (D12) precisely because re-transcribing is the operation that stops working
/// when the audio goes.
///
/// A function in the package rather than a `FileManager` call in the pane, because the app target
/// has no test bundle and "the file went away underneath the row" is a behaviour, not an API: it
/// is proved by deleting a real file and asking again.
public enum HistoryAudioFile {
    /// The playable WAV for this row, or nil when there is none to play.
    ///
    /// Three ways to get nil, and they are one answer on purpose -- Play and Reveal are disabled
    /// identically for all three, and a caller that distinguished them would have three states for
    /// one button. The row names no audio (purged, or never kept); the name it does carry is not a
    /// safe relative one (`HistoryRecord.audioURL(inRecordings:)` refuses it); or the file the name
    /// resolves to is not there any more.
    ///
    /// `fileManager` is injected so a test can point at a temporary folder, the same reason
    /// `RetentionPurge.run` takes one.
    public static func url(
        for record: HistoryRecord, inRecordings base: URL, fileManager: FileManager = .default
    ) -> URL? {
        guard let url = record.audioURL(inRecordings: base),
              fileManager.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}
