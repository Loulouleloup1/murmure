import Foundation
import GRDB

/// The text-free projection of a dictation row used by the Home statistics. It carries no
/// transcript on purpose: statistics never need the words, only their number.
public struct DictationStatisticsRow: Equatable, Sendable, Decodable, FetchableRecord {
    public var startedAt: Date
    public var durationSeconds: Double
    public var outcome: DictationOutcome
    public var rawWordCount: Int?
    public var finalWordCount: Int?
    public var targetBundleID: String?
    public var targetAppName: String?
    public var modeName: String

    public init(startedAt: Date, durationSeconds: Double, outcome: DictationOutcome,
                rawWordCount: Int? = nil, finalWordCount: Int? = nil,
                targetBundleID: String? = nil, targetAppName: String? = nil, modeName: String) {
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.outcome = outcome
        self.rawWordCount = rawWordCount; self.finalWordCount = finalWordCount
        self.targetBundleID = targetBundleID; self.targetAppName = targetAppName; self.modeName = modeName
    }
}

/// Same custom strategy as `HistoryRecord` (see there for why): `startedAt` is ISO 8601 with
/// millisecond precision, not GRDB's second-truncating `.iso8601`. The two decoders must agree,
/// or this projection would silently read a different instant than `HistoryRecord` does for the
/// same row.
extension DictationStatisticsRow {
    public static func databaseDateDecodingStrategy(
        for column: String
    ) -> DatabaseDateDecodingStrategy {
        .custom { String.fromDatabaseValue($0).flatMap(HistoryTimestamp.date(from:)) }
    }
}
