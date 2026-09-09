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

    // MARK: Heatmap

    func testHeatmapRunsFromTheMondayFiftyOneWeeksAgoToToday() {
        let stats = compute([row("2026-09-09T10:00:00+02:00", raw: 5, final: 5)])
        // now is Wednesday 2026-09-09; this week's Monday is 09-07; 51 weeks earlier: 2025-09-15.
        XCTAssertEqual(stats.heatmap.first?.day, t("2025-09-15T00:00:00+02:00"))
        XCTAssertEqual(stats.heatmap.last?.day, t("2026-09-09T00:00:00+02:00"))
        XCTAssertEqual(stats.heatmap.count, 51 * 7 + 3)          // 51 full weeks + Mon, Tue, Wed
        XCTAssertEqual(stats.heatmap.first?.column, 0)
        XCTAssertEqual(stats.heatmap.first?.row, 0)
        XCTAssertEqual(stats.heatmap.last?.column, 51)
        XCTAssertEqual(stats.heatmap.last?.row, 2)
    }

    func testHeatmapLevelsAreQuartilesOfTheBusiestDayWithActivityWithoutWordsAtLevelOne() {
        let stats = compute([
            row("2026-09-01T10:00:00+02:00", raw: 100, final: 100),   // max → 4
            row("2026-09-02T10:00:00+02:00", raw: 30, final: 30),     // 0.30 → 2
            row("2026-09-03T10:00:00+02:00", raw: 25, final: 25),     // 0.25 → 1
            row("2026-09-04T10:00:00+02:00", raw: 76, final: 76),     // 0.76 → 4
            row("2026-09-05T10:00:00+02:00"),                         // dictated, no count → 1
        ], period: .last7Days)                                         // period must not matter
        func level(_ iso: String) -> Int? { stats.heatmap.first { $0.day == t(iso) }?.level }
        XCTAssertEqual(level("2026-09-01T00:00:00+02:00"), 4)
        XCTAssertEqual(level("2026-09-02T00:00:00+02:00"), 2)
        XCTAssertEqual(level("2026-09-03T00:00:00+02:00"), 1)
        XCTAssertEqual(level("2026-09-04T00:00:00+02:00"), 4)
        XCTAssertEqual(level("2026-09-05T00:00:00+02:00"), 1)
        XCTAssertEqual(level("2026-09-06T00:00:00+02:00"), 0)
    }

    func testHeatmapIgnoresTheSelectedPeriodButNotTheOutcome() {
        let stats = compute([
            row("2026-06-01T10:00:00+02:00", raw: 1, final: 1),
            row("2026-06-02T10:00:00+02:00", outcome: .failed, raw: 1, final: 1),
        ], period: .last7Days)
        XCTAssertEqual(stats.heatmap.first { $0.day == t("2026-06-01T00:00:00+02:00") }?.dictations, 1)
        XCTAssertEqual(stats.heatmap.first { $0.day == t("2026-06-02T00:00:00+02:00") }?.dictations, 0)
    }

    // MARK: Hour profile

    func testHourProfileUsesLocalHoursOverTheSelectedPeriod() {
        let stats = compute([
            row("2026-09-09T08:15:00+02:00"),
            row("2026-09-09T08:45:00+02:00"),
            row("2026-09-09T23:59:00+02:00"),
            row("2026-01-01T08:00:00+01:00"),          // outside 7 days
        ], period: .last7Days)
        XCTAssertEqual(stats.hourProfile.count, 24)
        XCTAssertEqual(stats.hourProfile[8], 2)
        XCTAssertEqual(stats.hourProfile[23], 1)
        XCTAssertEqual(stats.hourProfile.reduce(0, +), 3)
    }

    // MARK: Streak

    func testCurrentStreakCountsBackFromTodayWhenTodayHasADictation() {
        let stats = compute(["09-07", "09-08", "09-09"].map { row("2026-\($0)T10:00:00+02:00") })
        XCTAssertEqual(stats.streak.current, 3)
    }

    func testCurrentStreakSurvivesADayWithoutADictationYet() {
        let stats = compute(["09-06", "09-07", "09-08"].map { row("2026-\($0)T10:00:00+02:00") })
        XCTAssertEqual(stats.streak.current, 3)
    }

    func testCurrentStreakIsZeroWhenNeitherTodayNorYesterdayHasADictation() {
        let stats = compute(["09-05", "09-06", "09-07"].map { row("2026-\($0)T10:00:00+02:00") })
        XCTAssertEqual(stats.streak.current, 0)
        XCTAssertEqual(stats.streak.longest, 3)
    }

    func testLongestStreakSpansAGapAndIgnoresDuplicateDays() {
        let stats = compute(["03-01", "03-02", "03-03", "03-03", "03-04", "03-10", "03-11"]
            .map { row("2026-\($0)T10:00:00+01:00") })
        XCTAssertEqual(stats.streak.longest, 4)
    }

    func testStreakDaysAreLocalDaysAcrossMidnight() {
        // 23:30 Paris on the 8th and 00:30 Paris on the 9th are two consecutive days
        let stats = compute([row("2026-09-08T23:30:00+02:00"), row("2026-09-09T00:30:00+02:00")])
        XCTAssertEqual(stats.streak.current, 2)
    }

    // MARK: Records

    func testRecordsPickTheLongestTheBiggestDayAndTheFastestWithGuards() {
        let stats = compute([
            row("2026-09-01T10:00:00+02:00", seconds: 300, raw: 400, final: 400),   // 80 wpm
            row("2026-09-02T10:00:00+02:00", seconds: 60, raw: 150, final: 150),    // 150 wpm ← fastest
            row("2026-09-02T11:00:00+02:00", seconds: 60, raw: 100, final: 100),    // day total 250 ← biggest day
            row("2026-09-03T10:00:00+02:00", seconds: 5, raw: 30, final: 30),       // 360 wpm but < 10 s: ignored
            row("2026-09-04T10:00:00+02:00", seconds: 20, raw: 10, final: 10),      // 30 wpm but < 20 words: ignored
        ], period: .last7Days)                                                       // records are all time
        XCTAssertEqual(stats.records.longestDictationSeconds?.value, 300)
        XCTAssertEqual(stats.records.longestDictationSeconds?.day, t("2026-09-01T00:00:00+02:00"))
        XCTAssertEqual(stats.records.mostWordsInADay?.value, 400)
        XCTAssertEqual(stats.records.mostWordsInADay?.day, t("2026-09-01T00:00:00+02:00"))
        XCTAssertEqual(stats.records.fastestWordsPerMinute!.value, 150, accuracy: 0.0001)
        XCTAssertEqual(stats.records.fastestWordsPerMinute?.day, t("2026-09-02T00:00:00+02:00"))
    }

    func testRecordsAreNilWithoutEligibleRows() {
        let stats = compute([row("2026-09-09T10:00:00+02:00", seconds: 3)])
        XCTAssertEqual(stats.records.longestDictationSeconds?.value, 3)
        XCTAssertNil(stats.records.mostWordsInADay)
        XCTAssertNil(stats.records.fastestWordsPerMinute)
    }
}
