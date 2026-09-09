import Foundation

/// The figures behind the Home pane: counts, applications, time saved and the hour profile for the
/// selected period; the heatmap over the last 52 weeks and the streaks and records over all time,
/// regardless of the period.
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

    /// Computes the Home pane figures for `rows` over `period`.
    ///
    /// `typingWordsPerMinute` must be greater than zero; it is expected to come from
    /// `AppSettings.typingWordsPerMinuteRange`.
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
        func isOrderedBefore(_ lhs: Application, _ rhs: Application) -> Bool {
            if lhs.dictations != rhs.dictations { return lhs.dictations > rhs.dictations }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.bundleID < rhs.bundleID
        }
        let top = byApp.map { Application(bundleID: $0.key, name: $0.value.name, dictations: $0.value.count) }
            .sorted(by: isOrderedBefore)
            .prefix(5)

        let since = counting.filter { $0.finalWordCount != nil }.map(\.startedAt).min()

        // Local day keys
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        var perDay: [Date: (dictations: Int, words: Int)] = [:]
        for row in counting {
            let key = day(row.startedAt)
            let entry = perDay[key] ?? (0, 0)
            perDay[key] = (entry.dictations + 1, entry.words + (row.finalWordCount ?? 0))
        }

        // Heatmap: Monday of the current week, minus 51 weeks, through today.
        let today = day(now)
        let weekday = calendar.component(.weekday, from: today)        // 1 = Sunday … 7 = Saturday
        let mondayOffset = (weekday + 5) % 7                            // Monday 0 … Sunday 6
        let thisMonday = calendar.date(byAdding: .day, value: -mondayOffset, to: today)!
        let firstDay = calendar.date(byAdding: .day, value: -51 * 7, to: thisMonday)!
        var heatmapDays: [Date] = []
        var cursor = firstDay
        while cursor <= today {
            heatmapDays.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let maxWords = heatmapDays.map { perDay[$0]?.words ?? 0 }.max() ?? 0
        let heatmap = heatmapDays.enumerated().map { index, date -> HeatmapDay in
            let entry = perDay[date] ?? (0, 0)
            let level: Int
            if entry.dictations == 0 { level = 0 }
            else if entry.words == 0 || maxWords == 0 { level = 1 }
            else {
                let ratio = Double(entry.words) / Double(maxWords)
                level = ratio <= 0.25 ? 1 : ratio <= 0.5 ? 2 : ratio <= 0.75 ? 3 : 4
            }
            return HeatmapDay(day: date, dictations: entry.dictations, words: entry.words,
                              level: level, column: index / 7, row: index % 7)
        }

        // Hour profile over the period
        var hours = Array(repeating: 0, count: 24)
        for row in inPeriod { hours[calendar.component(.hour, from: row.startedAt)] += 1 }

        // Streaks over all time
        let days = Set(perDay.keys)
        var current = 0
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            var probe: Date? = days.contains(today) ? today : (days.contains(yesterday) ? yesterday : nil)
            while let p = probe, days.contains(p) {
                current += 1
                probe = calendar.date(byAdding: .day, value: -1, to: p)
            }
        }
        var longest = 0, run = 0
        var previous: Date?
        for d in days.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == d { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = d
        }

        // Records over all time
        func wpm(_ r: DictationStatisticsRow) -> Double { Double(r.rawWordCount ?? 0) * 60 / r.durationSeconds }
        let longestRow = counting.max { $0.durationSeconds < $1.durationSeconds }
        let biggestDay = perDay.filter { $0.value.words > 0 }
            .max { $0.value.words != $1.value.words ? $0.value.words < $1.value.words : $0.key > $1.key }
        let fastestRow = counting
            .filter { $0.durationSeconds >= 10 && ($0.rawWordCount ?? 0) >= 20 }
            .max { wpm($0) < wpm($1) }

        return DictationStatistics(
            period: period, hasAnyDictation: !counting.isEmpty,
            dictations: inPeriod.count, words: words, spokenSeconds: spoken,
            averageWordsPerMinute: averageWPM, applicationCount: byApp.count,
            topApplications: Array(top), timeSavedMinutes: timeSaved, wordCountsSince: since,
            heatmap: heatmap, hourProfile: hours,
            streak: Streak(current: current, longest: longest),
            records: Records(
                longestDictationSeconds: longestRow.map { Record(value: $0.durationSeconds, day: day($0.startedAt)) },
                mostWordsInADay: biggestDay.map { Record(value: $0.value.words, day: $0.key) },
                fastestWordsPerMinute: fastestRow.map { Record(value: wpm($0), day: day($0.startedAt)) }))
    }
}
