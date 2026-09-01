import Foundation
import GRDB

/// What became of one dictation. Stored, never derived (lot 4 D8).
///
/// `insertedCharacters > 0` cannot tell these four apart, and lot 3 already paid for collapsing
/// them once: a dictation the user cancelled and a dictation that failed both insert nothing, and
/// they are not the same event to anyone reading the history back.
///
/// The raw values are the on-disk representation. Renaming a case without changing its raw value
/// is free; changing a raw value rewrites the meaning of every row already written, so they are
/// pinned by a test.
public enum DictationOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    /// Text was produced and inserted into the target application.
    case inserted = "inserted"
    /// The recording carried no speech, so there was nothing to insert.
    case nothingHeard = "nothingHeard"
    /// Something in the pipeline failed; `failureMessage` says what.
    case failed = "failed"
    /// The user stopped the dictation before it produced anything.
    case cancelled = "cancelled"
}

extension DictationOutcome: DatabaseValueConvertible {}

/// The text form of `dictation.startedAt`: ISO 8601, UTC, milliseconds (§5.2).
///
/// Not GRDB's own `.iso8601` strategy, which formats with `.withInternetDateTime` alone and so
/// **truncates to the second**. Murmure writes several rows a minute at most, but a timestamp that
/// silently drops its sub-second part manufactures the exact tie the history ordering then has to
/// break, and it throws away precision `Date` already had.
///
/// The width is fixed -- `2026-09-01T14:42:03.123Z`, always 24 characters, always `Z` -- which is
/// what makes `ORDER BY startedAt DESC` chronological and `WHERE startedAt < ?` a usable purge
/// predicate on a TEXT column. `HistoryStoreTests` pins that lexicographic order and the date
/// order agree, because the schema rests on it.
enum HistoryTimestamp {
    // Assume this non-Sendable instance can be used from several threads: `ISO8601DateFormatter`
    // is documented thread-safe for formatting and parsing, which is all it is asked for here.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

/// One row of `dictation` (§5.2), as a value.
///
/// Every optional here is a column that is genuinely absent rather than empty, and each one means
/// something different: no refiner ran (`llmModel`, `refinedText`), nothing was transcribed
/// (`rawTranscript`), the audio has been purged or was never kept (`audioFilename`), the
/// dictation did not fail (`failureMessage`). Defaulting any of them to `""` would erase the
/// distinction the column exists to carry -- which is D6 stated once, for all of them.
public struct HistoryRecord: Codable, Equatable, Sendable {
    /// `nil` until the row is inserted; the database assigns it.
    public var id: Int64?
    /// When the recording started. UTC, to the millisecond.
    public var startedAt: Date
    /// The length of the recording, not of the pipeline that followed it.
    public var durationSeconds: Double
    public var outcome: DictationOutcome
    public var modeKey: String
    /// Denormalised beside `modeKey` on purpose (§5.2): modes are hand-edited JSON files that can
    /// be renamed, rekeyed or deleted, and a row that can only say `modeKey = "prompt"` for a file
    /// that no longer exists is a row that cannot be read.
    public var modeName: String
    public var sttModel: String
    /// `nil` when the mode had no refiner.
    public var llmModel: String?
    /// The transcript **after** the vocabulary replacements, because that is what the refiner was
    /// handed and therefore what the mode actually saw (§5.2). `nil` when nothing was transcribed.
    public var rawTranscript: String?
    /// `nil` when no refinement ran -- never a copy of `rawTranscript` (D6). A copy would make a
    /// mode that never refines indistinguishable, after the fact, from a refiner that returned its
    /// input unchanged, which is the documented failure mode of a too-small model.
    public var refinedText: String?
    public var insertedCharacters: Int
    public var targetBundleID: String?
    public var targetAppName: String?
    /// Relative to `recordings/`, never absolute (D7). `nil` once the audio has been purged --
    /// which happens on a different clock from the text, so a row can carry live text and no WAV.
    public var audioFilename: String?
    /// Wall-clock spent transcribing. `nil` when no transcription ran.
    public var transcriptionSeconds: Double?
    /// Wall-clock spent refining. `nil` when no refinement ran.
    public var refinementSeconds: Double?
    /// The message the notch showed, kept so a failed dictation is a readable row rather than a
    /// row that merely says it failed.
    public var failureMessage: String?

    public init(
        id: Int64? = nil,
        startedAt: Date,
        durationSeconds: Double,
        outcome: DictationOutcome,
        modeKey: String,
        modeName: String,
        sttModel: String,
        llmModel: String? = nil,
        rawTranscript: String? = nil,
        refinedText: String? = nil,
        insertedCharacters: Int = 0,
        targetBundleID: String? = nil,
        targetAppName: String? = nil,
        audioFilename: String? = nil,
        transcriptionSeconds: Double? = nil,
        refinementSeconds: Double? = nil,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.outcome = outcome
        self.modeKey = modeKey
        self.modeName = modeName
        self.sttModel = sttModel
        self.llmModel = llmModel
        self.rawTranscript = rawTranscript
        self.refinedText = refinedText
        self.insertedCharacters = insertedCharacters
        self.targetBundleID = targetBundleID
        self.targetAppName = targetAppName
        self.audioFilename = audioFilename
        self.transcriptionSeconds = transcriptionSeconds
        self.refinementSeconds = refinementSeconds
        self.failureMessage = failureMessage
    }

    /// Where this row's WAV is, given the folder recordings live in.
    ///
    /// The relative form is the whole point of D7: `recordings/` moves the day `Storage` changes,
    /// and this function is what lets one row resolve against the real folder in the app and
    /// against a temporary one in a test.
    ///
    /// Returns `nil` for an absolute or upward-reaching `audioFilename` rather than joining it.
    /// `appendingPathComponent("/Users/x.wav")` does not honour the leading slash -- it produces
    /// `<base>/Users/x.wav`, a path that looks resolved and points nowhere -- and a `..` would
    /// resolve outside the folder the caller named. `HistoryStore.insert` refuses to store either,
    /// so this guard is for a row written by a hand or a version that did not.
    public func audioURL(inRecordings base: URL) -> URL? {
        guard let audioFilename, Self.isSafeRelativeAudioFilename(audioFilename) else { return nil }
        return base.appendingPathComponent(audioFilename)
    }

    static func isSafeRelativeAudioFilename(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix("/")
            && !name.split(separator: "/").contains("..")
    }
}

extension HistoryRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dictation"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// How `startedAt` becomes text and comes back.
///
/// Both go through `HistoryTimestamp` rather than GRDB's `.iso8601`, which formats with
/// `.withInternetDateTime` alone and so truncates to the second. They must stay a matched pair:
/// an encoding the decoding cannot read back turns every fetched row into a conversion error.
///
/// These are FUNCTIONS OF THE COLUMN, which is the shape GRDB asks for. Written as the properties
/// the older API had, they compile, they are never called, and every date is silently stored in
/// GRDB's default `2026-09-01 14:42:03.123` instead of the ISO 8601 the schema promises. That is
/// not hypothetical -- it is what this file did until a test read the column back as text.
extension HistoryRecord {
    public static func databaseDateEncodingStrategy(
        for column: String
    ) -> DatabaseDateEncodingStrategy {
        .custom { HistoryTimestamp.string(from: $0) }
    }

    public static func databaseDateDecodingStrategy(
        for column: String
    ) -> DatabaseDateDecodingStrategy {
        .custom { String.fromDatabaseValue($0).flatMap(HistoryTimestamp.date(from:)) }
    }
}
