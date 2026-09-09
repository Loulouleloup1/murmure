import XCTest
@testable import MurmureCore

final class StatisticsPeriodTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.firstWeekday = 2
        return c
    }()
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); return f.date(from: iso)!
    }

    func testSevenDaysStartsSixLocalDaysBeforeTodayAtMidnight() {
        let now = date("2026-09-09T15:30:00+02:00")
        XCTAssertEqual(StatisticsPeriod.last7Days.start(now: now, calendar: calendar),
                       date("2026-09-03T00:00:00+02:00"))
    }

    func testThirtyDaysStartsTwentyNineDaysBeforeToday() {
        let now = date("2026-09-09T00:10:00+02:00")
        XCTAssertEqual(StatisticsPeriod.last30Days.start(now: now, calendar: calendar),
                       date("2026-08-11T00:00:00+02:00"))
    }

    func testTwelveMonthsStartsTwelveCalendarMonthsBeforeToday() {
        let now = date("2026-09-09T15:30:00+02:00")
        XCTAssertEqual(StatisticsPeriod.last12Months.start(now: now, calendar: calendar),
                       date("2025-09-09T00:00:00+02:00"))
    }

    func testAllTimeHasNoStart() {
        XCTAssertNil(StatisticsPeriod.allTime.start(now: Date(), calendar: calendar))
    }

    func testTitlesAndOrderArePinned() {
        XCTAssertEqual(StatisticsPeriod.allCases.map(\.title), ["7 days", "30 days", "12 months", "All time"])
    }
}
