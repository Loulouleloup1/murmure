import XCTest
@testable import MurmureCore

final class DictationStatisticsTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.firstWeekday = 2
        return c
    }()
    /// Wednesday 2026-09-09, 15:30 Paris.
    private let now = ISO8601DateFormatter().date(from: "2026-09-09T15:30:00+02:00")!

    private func t(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func row(_ startedAt: String, seconds: Double = 60, outcome: DictationOutcome = .inserted,
                     raw: Int? = nil, final: Int? = nil, app: (String, String)? = ("com.example.a", "A"),
                     mode: String = "Voice") -> DictationStatisticsRow {
        DictationStatisticsRow(startedAt: t(startedAt), durationSeconds: seconds, outcome: outcome,
                               rawWordCount: raw, finalWordCount: final,
                               targetBundleID: app?.0, targetAppName: app?.1, modeName: mode)
    }

    private func compute(_ rows: [DictationStatisticsRow], period: StatisticsPeriod = .allTime,
                         typing: Int = 40) -> DictationStatistics {
        DictationStatistics.compute(rows: rows, period: period, now: now, calendar: calendar,
                                    typingWordsPerMinute: typing)
    }

    // MARK: Which rows count

    func testOnlyInsertedAndCopiedRowsCount() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", raw: 10, final: 10),
            row("2026-09-09T10:01:00+02:00", outcome: .copiedToClipboard, raw: 10, final: 10),
            row("2026-09-09T10:02:00+02:00", outcome: .nothingHeard),
            row("2026-09-09T10:03:00+02:00", outcome: .failed, raw: 99, final: 99),
            row("2026-09-09T10:04:00+02:00", outcome: .cancelled),
        ])
        XCTAssertEqual(stats.dictations, 2)
        XCTAssertEqual(stats.words, 20)
        XCTAssertEqual(stats.spokenSeconds, 120)
        XCTAssertTrue(stats.hasAnyDictation)
    }

    func testNoCountingRowAnywhereMeansNoDictation() {
        let stats = compute([row("2026-09-09T10:00:00+02:00", outcome: .failed)])
        XCTAssertFalse(stats.hasAnyDictation)
        XCTAssertEqual(stats.dictations, 0)
        XCTAssertNil(stats.averageWordsPerMinute)
        XCTAssertNil(stats.timeSavedMinutes)
    }

    // MARK: Period

    func testSevenDaysIncludesTodayAndSixDaysBeforeInLocalTime() {
        let stats = compute([
            row("2026-09-03T00:30:00+02:00", raw: 1, final: 1),   // first minute of the window
            row("2026-09-02T23:30:00+02:00", raw: 1, final: 1),   // just before it
            row("2026-09-09T23:00:00+02:00", raw: 1, final: 1),   // later today
        ], period: .last7Days)
        XCTAssertEqual(stats.dictations, 2)
    }

    func testAllTimeIgnoresTheWindow() {
        let stats = compute([row("2019-01-01T10:00:00+01:00", raw: 3, final: 3)])
        XCTAssertEqual(stats.dictations, 1)
        XCTAssertEqual(stats.words, 3)
    }

    // MARK: Figures

    func testAverageWpmIsWeightedByDurationNotAMeanOfMeans() {
        // 60 s with 60 words (60 wpm) and 180 s with 60 words (20 wpm): 120 words / 4 min = 30 wpm
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 60, final: 60),
            row("2026-09-09T10:05:00+02:00", seconds: 180, raw: 60, final: 60),
        ])
        XCTAssertEqual(stats.averageWordsPerMinute!, 30, accuracy: 0.0001)
    }

    func testRowsWithoutARawCountDoNotDragTheAverageDown() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 100, final: 100),
            row("2026-09-09T10:05:00+02:00", seconds: 600),      // purged row, no counts
        ])
        XCTAssertEqual(stats.averageWordsPerMinute!, 100, accuracy: 0.0001)
        XCTAssertEqual(stats.spokenSeconds, 660)                  // it still counts as spoken time
        XCTAssertEqual(stats.dictations, 2)
    }

    func testTimeSavedUsesTheTypingBaselineAndMayBeNegative() {
        // 80 final words at 40 wpm = 2 min to type, spoken in 1 min: +1 min
        let fast = compute([row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 80, final: 80)])
        XCTAssertEqual(fast.timeSavedMinutes!, 1, accuracy: 0.0001)
        // 20 words = 0.5 min to type, spoken in 2 min: −1.5 min
        let slow = compute([row("2026-09-09T10:00:00+02:00", seconds: 120, raw: 20, final: 20)])
        XCTAssertEqual(slow.timeSavedMinutes!, -1.5, accuracy: 0.0001)
        // baseline 80 wpm halves the typing time
        let quickTypist = compute([row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 80, final: 80)], typing: 80)
        XCTAssertEqual(quickTypist.timeSavedMinutes!, 0, accuracy: 0.0001)
    }

    func testRowsWithoutAFinalCountAreExcludedFromTimeSaved() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 80, final: 80),
            row("2026-09-09T10:05:00+02:00", seconds: 3600),      // an hour of purged dictation
        ])
        XCTAssertEqual(stats.timeSavedMinutes!, 1, accuracy: 0.0001)
    }

    func testWordCountsSinceIsTheEarliestCountedRowAllTime() {
        let stats = compute([
            row("2026-01-05T10:00:00+01:00"),
            row("2026-03-05T10:00:00+01:00", raw: 2, final: 2),
            row("2026-09-09T10:00:00+02:00", raw: 2, final: 2),
        ], period: .last7Days)
        XCTAssertEqual(stats.wordCountsSince, t("2026-03-05T10:00:00+01:00"))
    }

    // MARK: Applications

    func testApplicationsAreCountedDistinctAndRankedWithTiesByName() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", app: ("com.b", "Bravo")),
            row("2026-09-09T10:01:00+02:00", app: ("com.b", "Bravo")),
            row("2026-09-09T10:02:00+02:00", app: ("com.a", "Alpha")),
            row("2026-09-09T10:03:00+02:00", app: ("com.c", "Charlie")),
            row("2026-09-09T10:04:00+02:00", app: nil),
        ])
        XCTAssertEqual(stats.applicationCount, 3)
        XCTAssertEqual(stats.topApplications.map(\.name), ["Bravo", "Alpha", "Charlie"])
        XCTAssertEqual(stats.topApplications.first?.dictations, 2)
    }

    func testTopApplicationsIsCappedAtFive() {
        let rows = (0..<7).map { i in
            row("2026-09-09T10:0\(i):00+02:00", app: ("com.app\(i)", "App \(i)"))
        }
        XCTAssertEqual(compute(rows).topApplications.count, 5)
    }

    func testAnApplicationSeenUnderTwoNamesKeepsTheMostRecentName() {
        let stats = compute([
            row("2026-09-08T10:00:00+02:00", app: ("com.x", "Old Name")),
            row("2026-09-09T10:00:00+02:00", app: ("com.x", "New Name")),
        ])
        XCTAssertEqual(stats.topApplications.map(\.name), ["New Name"])
    }
}
