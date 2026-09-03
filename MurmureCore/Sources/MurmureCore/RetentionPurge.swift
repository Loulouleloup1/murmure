import Foundation

/// What one pass of the retention purge did.
///
/// Deliberately not `Void` and not a `Bool`: deleting a file can fail, and a caller that cannot
/// tell "purged 12 files" from "tried 12 and failed 12" would report a retention promise it did
/// not keep. The count and the failures are separate fields for exactly that reason.
public struct RetentionPurgeReport: Equatable, Sendable {
    /// One file the sweep meant to delete and could not.
    public struct DeletionFailure: Equatable, Sendable {
        public let filename: String
        public let message: String

        public init(filename: String, message: String) {
            self.filename = filename
            self.message = message
        }
    }

    /// Rows whose transcript and refined text were dropped. The rows themselves survive.
    public var textRowsCleared: Int
    /// WAVs actually removed from disk.
    public var audioFilesDeleted: Int
    /// WAVs the sweep tried to remove and could not, in filename order so one machine's log line
    /// is the same line twice running.
    public var audioDeletionFailures: [DeletionFailure]
    /// Nil when the sweep ran. A message when `recordings/` is there and could not be listed, in
    /// which case no file was examined at all -- deliberately distinct from a folder that is not
    /// there yet, which is the normal state of a fresh install and says nothing.
    public var recordingsUnreadable: String?

    public init(
        textRowsCleared: Int = 0,
        audioFilesDeleted: Int = 0,
        audioDeletionFailures: [DeletionFailure] = [],
        recordingsUnreadable: String? = nil
    ) {
        self.textRowsCleared = textRowsCleared
        self.audioFilesDeleted = audioFilesDeleted
        self.audioDeletionFailures = audioDeletionFailures
        self.recordingsUnreadable = recordingsUnreadable
    }
}

/// The retention decision of 2026-09-01, given the mechanism it had been missing: **audio goes
/// after 3 days, text after 30, and the vocabulary derived from either is kept indefinitely.**
///
/// **The sweep is why this is not four lines calling `clearText` and `clearAudio`.** Those two
/// work from rows, and rows only ever name audio the archive knows about. Measured on Louis's own
/// folder on 2026-09-02: 148 WAVs, 730.7 MB, of which **122 files and 613.7 MB have no row at
/// all** -- audio recorded before the history feature shipped, all of it older than the oldest row
/// in the database. A row-driven purge would never have reached a byte of it, and would never
/// reach it in future either, because any recording made before the store existed or made while a
/// row failed to write is permanently unreachable by name. A retention promise that leaks like
/// that is not a retention promise, so the audio half sweeps the directory as well as the rows.
///
/// A directory sweep is the dangerous half, so it is written to refuse rather than to reach:
/// only files directly in the folder, only the `.wav` the app writes, never a symlink, never
/// anything that is not a regular file, and aged against an **injected** `now` rather than a
/// `Date()` read in here.
///
/// **The database outranks the modification time in one direction and not the other.** A row still
/// inside its window pins its file however old the file looks, because an mtime is a property of
/// a copy, a restore or a clock, and the pane is still offering that recording to play. The other
/// way round, a row past its window loses its file however new the file looks: three days is
/// measured from the dictation, not from whatever last touched the bytes.
///
/// **There is no "last run" marker anywhere, and there must not be one.** Every cutoff is an
/// absolute instant derived from `now`, so a Mac that was shut for a week purges correctly on the
/// next launch instead of skipping a window or counting one twice. The data's own timestamps are
/// the state, which is what makes a second pass at the same instant a no-op by construction.
public enum RetentionPurge {
    /// Three days, as elapsed seconds rather than calendar days. A calendar would make the window
    /// change length twice a year for no reason anybody asked for, and the thing being bounded is
    /// how long audio sits on the disk.
    public static let audioLifetime: TimeInterval = 3 * 24 * 60 * 60
    public static let textLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// One pass. Returns what it did; throws only when the archive itself could not be read or
    /// written.
    ///
    /// Throwing on a database failure takes the sweep down with it **on purpose**: the pin set
    /// comes from the database, so a store that will not answer is a purge that does not know
    /// what it is allowed to delete. Not sweeping is the safe direction, and 614 MB waits for the
    /// next pass.
    public static func run(
        store: HistoryStore,
        recordings: URL,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> RetentionPurgeReport {
        try sweep(
            store: store, recordings: recordings,
            audioCutoff: now.addingTimeInterval(-audioLifetime),
            textCutoff: now.addingTimeInterval(-textLifetime),
            fileManager: fileManager)
    }

    /// One of the Advanced pane's two buttons, carried out.
    ///
    /// **The same sweep, with one of the two clocks wound forward to `now` and the other wound
    /// back out of reach.** That is not a convenience, it is `HistoryClearing`'s own claim made
    /// structural: those buttons "run the same two sweeps with no cutoff, so a button can never
    /// produce an outcome the app does not already produce on its own". A second implementation
    /// here -- a `deleteEverything` that listed the folder itself -- is exactly how the button and
    /// the automatic sweep would come to disagree about symlinks, about non-`.wav` files, or about
    /// a row that still pins its audio.
    ///
    /// `.distantPast` for the half that is not being cleared, and it is genuinely inert rather
    /// than merely small: `clearText(startedBefore: .distantPast)` matches no row, `clearAudio`
    /// detaches none, and `modified < .distantPast` is false for every file that exists. So
    /// "delete the recordings" cannot cost a word of text, and vice versa -- which is what both
    /// summaries promise out loud.
    ///
    /// `now` is passed in for the reason every other date in this file is: it is the one input a
    /// test cannot otherwise vary. It is also the honest cutoff -- "everything that exists as of
    /// the click" -- rather than `.distantFuture`, which would additionally claim the recording
    /// that a dictation started after the click has not written yet.
    public static func clearNow(
        _ action: HistoryClearing,
        store: HistoryStore,
        recordings: URL,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> RetentionPurgeReport {
        // Written without a `default`, like every other exhaustive switch here: a third clearing
        // action must not inherit a pair of cutoffs, because inheriting the wrong one deletes
        // something nobody asked about.
        let (audioCutoff, textCutoff): (Date, Date) = switch action {
        case .recordings: (now, .distantPast)
        case .transcripts: (.distantPast, now)
        }
        return try sweep(
            store: store, recordings: recordings,
            audioCutoff: audioCutoff, textCutoff: textCutoff, fileManager: fileManager)
    }

    /// The pass itself, with both cutoffs given rather than derived.
    ///
    /// Split out so the retention timer and the two buttons are one body of code with two callers,
    /// which is the whole of `clearNow`'s argument above.
    private static func sweep(
        store: HistoryStore,
        recordings: URL,
        audioCutoff: Date,
        textCutoff: Date,
        fileManager: FileManager
    ) throws -> RetentionPurgeReport {
        var report = RetentionPurgeReport()

        report.textRowsCleared = try store.clearText(startedBefore: textCutoff)
        let detached = Set(try store.clearAudio(startedBefore: audioCutoff))
        // Read AFTER the detach, and that ordering is the safe one rather than the tidy one: this
        // set can only ever GAIN entries between here and the sweep below -- a dictation that
        // finishes in between inserts a row, it never removes one -- so every name in it is still
        // a name the archive is holding on to by the time a file is deleted.
        let pinned = try store.referencedAudioFilenames()

        // A folder that is not there yet is a fresh install, not a failure, and this function
        // creates nothing: `recordings/` is `AudioRecorder`'s to make, on the dictation that
        // needs it.
        guard fileManager.fileExists(atPath: recordings.path) else { return report }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: recordings,
                includingPropertiesForKeys: keys,
                // Not recursive, which is `contentsOfDirectory`'s own behaviour and half the
                // safety here. Hidden files are skipped because Murmure writes none: a dot-file
                // in this folder came from somewhere else and is not ours to delete.
                options: [.skipsHiddenFiles])
        } catch {
            report.recordingsUnreadable = error.localizedDescription
            return report
        }

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            // The extension `WavWriter` writes, exactly, lowercase. Anything else in this folder
            // was not put there by Murmure.
            guard url.pathExtension == "wav" else { continue }
            // A file whose attributes cannot be read is a file whose age is unknown, and an
            // unknown age is never old enough. In practice this is a file that vanished between
            // the listing and this line, which is a deletion somebody else already did.
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink == false,
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            // The pin, and it is checked before the age rather than after so there is no order of
            // conditions in which an mtime can win.
            guard !pinned.contains(name) else { continue }
            // Two ways to be expired, and the row's word comes first: a name the archive just
            // detached is audio past its three days whatever the file's timestamp says. The mtime
            // is what reaches the orphans no row has ever named.
            guard detached.contains(name) || modified < audioCutoff else { continue }

            do {
                try fileManager.removeItem(at: url)
                report.audioFilesDeleted += 1
            } catch {
                // Log-and-continue, the convention this repo uses everywhere a loop can fail
                // partway: one volume that went away, one file somebody locked, must not abandon
                // the other hundred. It is carried out rather than swallowed -- the caller is the
                // one that can say it out loud.
                report.audioDeletionFailures.append(
                    .init(filename: name, message: error.localizedDescription))
            }
        }

        return report
    }
}
