import Foundation

/// Why the History list is showing nothing, and what it says about it.
///
/// Four conditions look identical on screen -- an empty list -- and they are four different pieces
/// of news. "No dictations yet." said over an archive that would not open is a lie about the one
/// thing Louis would want to know, and said over a folder holding two hundred recordings it is
/// a lie about his own disk. The list has no way to tell them apart on its own, so the telling
/// apart is here, where a test can walk all four.
///
/// In `MurmureCore` and not in `HistoryPaneView` for the reason the whole package exists, and one
/// that is sharper for this type than for most: the app target has no test bundle, so a sentence
/// written in the view is a decision nothing can check -- and these are the sentences shown at the
/// exact moment Louis is trying to work out whether Murmure is broken.
public enum HistoryEmptyState: Equatable, Sendable, CustomStringConvertible {
    /// `murmure.sqlite` could not be opened or migrated. `file` is the file's own name and
    /// `reason` is the words the failure came with.
    case archiveUnusable(file: String, reason: String)
    /// Something was typed and none of it can be searched for (`HistoryQuery.unsearchable`).
    case unsearchableQuery
    /// A real query, and no row matched it. The archive is fine and has rows in it.
    case noMatch
    /// The archive opened and holds no rows at all. `orphanedRecordings` is how many WAVs are
    /// sitting in `recordings/` that no row can name -- see `orphanedRecordingCount(in:)`.
    case nothingYet(orphanedRecordings: Int)

    /// Which of the four this is, or nil when the list has rows in it and says nothing at all.
    ///
    /// **The order of these branches is the decision.** An archive that will not open outranks
    /// everything, because every other answer below it would be derived from a database that never
    /// answered -- "No dictation matches that" over a store that refused the query is the pane
    /// blaming Louis's search for its own failure. Below that, an unsearchable query outranks a
    /// no-match for the reason `HistoryQuery` exists: the store was never asked, so "nothing
    /// matched" would be a result nothing produced.
    ///
    /// `orphanedRecordings` is a closure and not an `Int` because counting it walks a directory,
    /// and only one of the four branches has any use for the number. **It is also why the count is
    /// never cached anywhere:** the figure in the message has to be the folder as it is at the
    /// moment the pane draws. The plan wrote "98 orphaned recordings" on 2026-09-01 and the folder
    /// held 200 two days later -- a number frozen into a sentence is a sentence that goes wrong on
    /// its own.
    public static func current(
        archiveFailure: HistoryStoreError?,
        query: HistoryQuery,
        hasRows: Bool,
        orphanedRecordings: () -> Int
    ) -> HistoryEmptyState? {
        if let archiveFailure {
            return .archiveUnusable(
                file: archiveFailure.fileName, reason: archiveFailure.reason)
        }
        guard !hasRows else { return nil }
        switch query {
        case .unsearchable: return .unsearchableQuery
        case .tokens: return .noMatch
        case .unfiltered: return .nothingYet(orphanedRecordings: orphanedRecordings())
        }
    }

    public var description: String {
        switch self {
        // **Two sentences, and the second one is the point.** The first says the archive is gone;
        // without the second, an empty History pane beside a working hotkey reads as "Murmure is
        // broken", and the app it is describing still records, still transcribes and still pastes
        // -- `DictationController` opens this store expressly so that a failure here costs nothing
        // but the row (spec §9's rule for the refiner, one layer down). What it does cost is said
        // rather than implied: from now on nothing is being kept.
        case .archiveUnusable(let file, let reason):
            "\(file) could not be opened -- \(reason). Dictation still works; nothing said from "
                + "now on is being kept."
        // The wording `HistoryQuery` was built to make possible: the store was never asked.
        case .unsearchableQuery:
            "Nothing in that to search for."
        // Says nothing about the archive being empty, deliberately: it is not, and a message that
        // conflated the two would send Louis looking for a history he still has.
        case .noMatch:
            "No dictation matches that."
        case .nothingYet(let orphaned):
            switch orphaned {
            case 0:
                "No dictations yet."
            // **The orphans get named rather than implied.** Lot 4 §5.5 decided they get no rows,
            // because their transcript exists nowhere and a backfill would produce rows with a
            // date and no identity -- but "No dictations yet." over a folder of recordings tells
            // Louis nothing ever happened, which is the one reading of his own disk that is false.
            // What is said is what can be checked: the files are there, the text is not.
            case 1:
                "No dictations yet. One recording is still in the recordings folder with no "
                    + "transcript anywhere, so it cannot be listed here."
            default:
                "No dictations yet. \(orphaned) recordings are still in the recordings folder "
                    + "with no transcript anywhere, so they cannot be listed here."
            }
        }
    }

    /// How many recordings are in `recordings/` that no history row can name.
    ///
    /// **Only correct for an archive with no rows in it**, which is the only case that asks: with
    /// no rows, every file in the folder is orphaned by definition, and no set difference against
    /// the database is needed or possible. A general "which files are unreferenced" belongs to
    /// `RetentionPurge`, which already computes it and is the thing that deletes them.
    ///
    /// Refuses the same way `RetentionPurge`'s sweep does, and for the same reasons: files
    /// directly in the folder only, the lowercase `.wav` extension `WavWriter` writes, no
    /// symlinks, nothing that is not a regular file. A folder that is not there yet is a fresh
    /// install and counts zero -- this function creates nothing.
    public static func orphanedRecordingCount(
        in recordings: URL, fileManager: FileManager = .default
    ) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return 0 }
        return entries.filter { url in
            guard url.pathExtension == "wav",
                  let values = try? url.resourceValues(forKeys: Set(keys))
            else { return false }
            return values.isSymbolicLink == false && values.isRegularFile == true
        }.count
    }
}

extension HistoryStoreError {
    /// The file the failure is about, by name rather than by path.
    ///
    /// `databaseUnusable` carries the full path, which is what a log line wants and not what a
    /// pane wants: `/Users/louiscourcier/Library/Application Support/Murmure/murmure.sqlite`
    /// spends a line and a half of a sentence saying where the user's home directory is. The name
    /// is the half that identifies it, and it is the half that stays the same on another machine.
    var fileName: String {
        switch self {
        case .databaseUnusable(let path, _): URL(fileURLWithPath: path).lastPathComponent
        // Cannot reach a pane -- `insert` refuses the row and the dictation carries on -- but the
        // name is still the honest answer to "which file is this about".
        case .audioFilenameNotRelative: "murmure.sqlite"
        }
    }

    /// The failure's own words, without the path already carried by `fileName`.
    var reason: String {
        switch self {
        case .databaseUnusable(_, let message): message
        case .audioFilenameNotRelative(let name):
            "audio filename \(name.debugDescription) is not relative to recordings/"
        }
    }
}
