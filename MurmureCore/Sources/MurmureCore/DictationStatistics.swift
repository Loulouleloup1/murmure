import Foundation

/// The figures behind the Home pane: counts, applications and time saved for a given period, plus
/// placeholders for the heatmap/hour-profile/streak/records the next task fills in.
public struct DictationStatistics: Equatable, Sendable {
    public struct Application: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        public let dictations: Int

        public init(bundleID: String, name: String, dictations: Int) {
            self.bundleID = bundleID
            self.name = name
            self.dictations = dictations
        }
    }

    public struct HeatmapDay: Equatable, Sendable {
        public let day: Date          // local midnight
        public let dictations: Int
        public let words: Int
        public let level: Int         // 0 (none) … 4 (busiest quartile)
        public let column: Int        // 0…51, week index oldest first
        public let row: Int           // 0 Monday … 6 Sunday

        public init(day: Date, dictations: Int, words: Int, level: Int, column: Int, row: Int) {
            self.day = day
            self.dictations = dictations
            self.words = words
            self.level = level
            self.column = column
            self.row = row
        }
    }

    public struct Streak: Equatable, Sendable {
        public let current: Int
        public let longest: Int

        public init(current: Int, longest: Int) {
            self.current = current
            self.longest = longest
        }
    }

    public struct Record<Value: Equatable & Sendable>: Equatable, Sendable {
        public let value: Value
        public let day: Date          // local midnight of the dictation (or of the day, for daily records)

        public init(value: Value, day: Date) {
            self.value = value
            self.day = day
        }
    }

    public struct Records: Equatable, Sendable {
        public let longestDictationSeconds: Record<Double>?
        public let mostWordsInADay: Record<Int>?
        public let fastestWordsPerMinute: Record<Double>?

        public init(longestDictationSeconds: Record<Double>?, mostWordsInADay: Record<Int>?,
                    fastestWordsPerMinute: Record<Double>?) {
            self.longestDictationSeconds = longestDictationSeconds
            self.mostWordsInADay = mostWordsInADay
            self.fastestWordsPerMinute = fastestWordsPerMinute
        }
    }

    public let period: StatisticsPeriod
    public let hasAnyDictation: Bool          // all time, drives the empty state
    public let dictations: Int
    public let words: Int
    public let spokenSeconds: Double
    public let averageWordsPerMinute: Double? // nil when no counted spoken time
    public let applicationCount: Int
    public let topApplications: [Application] // at most 5, most dictations first, ties by name
    public let timeSavedMinutes: Double?      // nil when no row in the period has a final count
    public let wordCountsSince: Date?         // earliest counted row, all time; nil if none
    public let heatmap: [HeatmapDay]
    public let hourProfile: [Int]             // 24 entries
    public let streak: Streak
    public let records: Records

    public init(period: StatisticsPeriod, hasAnyDictation: Bool, dictations: Int, words: Int,
                spokenSeconds: Double, averageWordsPerMinute: Double?, applicationCount: Int,
                topApplications: [Application], timeSavedMinutes: Double?, wordCountsSince: Date?,
                heatmap: [HeatmapDay], hourProfile: [Int], streak: Streak, records: Records) {
        self.period = period
        self.hasAnyDictation = hasAnyDictation
        self.dictations = dictations
        self.words = words
        self.spokenSeconds = spokenSeconds
        self.averageWordsPerMinute = averageWordsPerMinute
        self.applicationCount = applicationCount
        self.topApplications = topApplications
        self.timeSavedMinutes = timeSavedMinutes
        self.wordCountsSince = wordCountsSince
        self.heatmap = heatmap
        self.hourProfile = hourProfile
        self.streak = streak
        self.records = records
    }

    public static func compute(rows: [DictationStatisticsRow], period: StatisticsPeriod,
                               now: Date, calendar: Calendar, typingWordsPerMinute: Int) -> DictationStatistics {
        let counting = rows.filter { $0.outcome == .inserted || $0.outcome == .copiedToClipboard }
        let start = period.start(now: now, calendar: calendar)
        let inPeriod = counting.filter { row in
            guard let start else { return true }
            return row.startedAt >= start          // no upper bound: "today" is inclusive whatever the hour
        }

        let words = inPeriod.reduce(0) { $0 + ($1.finalWordCount ?? 0) }
        let spoken = inPeriod.reduce(0.0) { $0 + $1.durationSeconds }

        let rawCounted = inPeriod.filter { $0.rawWordCount != nil }
        let rawWords = rawCounted.reduce(0) { $0 + ($1.rawWordCount ?? 0) }
        let rawSeconds = rawCounted.reduce(0.0) { $0 + $1.durationSeconds }
        let averageWPM: Double? = rawSeconds > 0 ? Double(rawWords) / (rawSeconds / 60) : nil

        let finalCounted = inPeriod.filter { $0.finalWordCount != nil }
        let timeSaved: Double? = finalCounted.isEmpty ? nil : finalCounted.reduce(0.0) { acc, row in
            acc + Double(row.finalWordCount ?? 0) / Double(typingWordsPerMinute) - row.durationSeconds / 60
        }

        // Applications: distinct bundle ids, name taken from the most recent row, top 5 by count.
        var byApp: [String: (name: String, count: Int, lastSeen: Date)] = [:]
        for row in inPeriod {
            guard let bundleID = row.targetBundleID else { continue }
            let name = row.targetAppName ?? bundleID
            if let existing = byApp[bundleID] {
                byApp[bundleID] = (row.startedAt > existing.lastSeen ? name : existing.name,
                                   existing.count + 1, max(existing.lastSeen, row.startedAt))
            } else {
                byApp[bundleID] = (name, 1, row.startedAt)
            }
        }
        let top = byApp.map { Application(bundleID: $0.key, name: $0.value.name, dictations: $0.value.count) }
            .sorted { $0.dictations != $1.dictations ? $0.dictations > $1.dictations : $0.name < $1.name }
            .prefix(5)

        let since = counting.filter { $0.finalWordCount != nil }.map(\.startedAt).min()

        return DictationStatistics(
            period: period, hasAnyDictation: !counting.isEmpty,
            dictations: inPeriod.count, words: words, spokenSeconds: spoken,
            averageWordsPerMinute: averageWPM, applicationCount: byApp.count,
            topApplications: Array(top), timeSavedMinutes: timeSaved, wordCountsSince: since,
            heatmap: [], hourProfile: Array(repeating: 0, count: 24),
            streak: Streak(current: 0, longest: 0),
            records: Records(longestDictationSeconds: nil, mostWordsInADay: nil, fastestWordsPerMinute: nil))
    }
}
