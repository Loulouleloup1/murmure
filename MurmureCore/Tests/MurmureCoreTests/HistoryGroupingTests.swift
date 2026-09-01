import XCTest
@testable import MurmureCore

/// The date headers, against an injected clock and an injected calendar.
///
/// Neither `Date()` nor `Calendar.current` appears below, and that is the point twice over: a test
/// of "Today" that reads the machine's clock passes at every hour and proves nothing at midnight,
/// and a test that reads the machine's time zone would pass in Paris and fail in CI.
///
/// **The boundary tested is LOCAL midnight, not UTC midnight.** Louis is in Paris; in summer that
/// is two hours ahead of the stored timestamps, so a dictation made at half past midnight is
/// `22:30Z` the day before. Grouped by its UTC date it files itself under yesterday the moment it
/// is made -- which is not a rounding error, it is the wrong day, on the surface whose whole job
/// is to say when something was said.
final class HistoryGroupingTests: XCTestCase {
    /// Paris, and named rather than `.current` so the assertions below mean the same thing on any
    /// machine that runs them.
    private let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = HistoryGrouping.locale
        return calendar
    }()

    private func at(_ iso: String) -> Date {
        guard let date = HistoryTimestamp.date(from: iso) else {
            XCTFail("fixture timestamp \(iso) is not ISO 8601")
            return .distantPast
        }
        return date
    }

    /// The text is invented, in the register Louis actually dictates. Nothing here comes from his
    /// real archive.
    private func record(_ iso: String, text: String = "on rebranche le connecteur") -> HistoryRecord
    {
        HistoryRecord(
            startedAt: at(iso), durationSeconds: 29.7, outcome: .inserted,
            modeKey: "voice", modeName: "Voice", sttModel: "large-v3-turbo",
            rawTranscript: text, insertedCharacters: text.count)
    }

    // MARK: - The three headers

    func testADictationMadeTodayIsUnderToday() {
        XCTAssertEqual(
            HistoryGrouping.header(
                for: at("2026-09-01T09:12:00.000Z"), now: at("2026-09-01T16:00:00.000Z"),
                calendar: paris),
            "Today")
    }

    func testADictationMadeYesterdayIsUnderYesterday() {
        XCTAssertEqual(
            HistoryGrouping.header(
                for: at("2026-08-31T09:12:00.000Z"), now: at("2026-09-01T16:00:00.000Z"),
                calendar: paris),
            "Yesterday")
    }

    /// Anything older is a date and not a third relative word: "this week" has to be read to be
    /// understood, where a date is recognised.
    func testAnythingOlderIsWrittenAsADate() {
        XCTAssertEqual(
            HistoryGrouping.header(
                for: at("2026-08-24T09:12:00.000Z"), now: at("2026-09-01T16:00:00.000Z"),
                calendar: paris),
            "24 August")
    }

    /// The year appears only outside the current one. Inside it, it is four characters repeated on
    /// every header; outside it, it is the whole question a history scrolled into December asks.
    func testADateInAnotherYearCarriesTheYear() {
        XCTAssertEqual(
            HistoryGrouping.header(
                for: at("2025-12-24T09:12:00.000Z"), now: at("2026-09-01T16:00:00.000Z"),
                calendar: paris),
            "24 December 2025")
    }

    // MARK: - The boundary, at local midnight

    /// **The mutation this whole file exists to catch.** 00:30 in Paris on 2 September is
    /// `2026-09-01T22:30Z`. Grouped by its UTC date it reads "Yesterday" while Louis is still
    /// awake in the same session that produced it.
    func testAOneAMDictationIsTodayInParisAndNotYesterdayInUTC() {
        let justAfterLocalMidnight = at("2026-09-01T22:30:00.000Z")
        XCTAssertEqual(
            HistoryGrouping.header(
                for: justAfterLocalMidnight, now: at("2026-09-02T08:00:00.000Z"), calendar: paris),
            "Today")
    }

    /// The other side of the same boundary, so the test above cannot be satisfied by a rule that
    /// answers "Today" to everything near it: 23:30 Paris on 1 September is `21:30Z` the same day,
    /// and it really is yesterday by the following morning.
    func testTheEveningBeforeThatMidnightIsYesterday() {
        XCTAssertEqual(
            HistoryGrouping.header(
                for: at("2026-09-01T21:30:00.000Z"), now: at("2026-09-02T08:00:00.000Z"),
                calendar: paris),
            "Yesterday")
    }

    /// The same instant, read in two zones, is two different days -- which is what makes the
    /// injected calendar a parameter rather than a convenience.
    func testTheSameInstantGroupsDifferentlyInAnotherTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = at("2026-09-01T22:30:00.000Z")
        let now = at("2026-09-02T08:00:00.000Z")
        XCTAssertEqual(HistoryGrouping.header(for: instant, now: now, calendar: paris), "Today")
        XCTAssertEqual(HistoryGrouping.header(for: instant, now: now, calendar: utc), "Yesterday")
    }

    // MARK: - The groups themselves

    func testRowsFromOneDayFormOneGroupInTheOrderTheyCameIn() {
        let rows = [record("2026-09-01T16:00:00.000Z"), record("2026-09-01T09:00:00.000Z")]
        let groups = HistoryGrouping.groups(
            for: rows, now: at("2026-09-01T18:00:00.000Z"), calendar: paris)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "Today")
        XCTAssertEqual(groups.first?.records.map(\.startedAt), rows.map(\.startedAt))
    }

    /// Three days, three headers, in the order the store hands them back -- newest first.
    func testThreeDaysProduceThreeHeadersNewestFirst() {
        let groups = HistoryGrouping.groups(
            for: [
                record("2026-09-01T16:00:00.000Z"),
                record("2026-08-31T16:00:00.000Z"),
                record("2026-08-24T16:00:00.000Z"),
            ],
            now: at("2026-09-01T18:00:00.000Z"), calendar: paris)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "24 August"])
        XCTAssertEqual(groups.map(\.records.count), [1, 1, 1])
    }

    /// The two sides of the local midnight boundary are two groups even though they are 40 minutes
    /// apart, and the one on the far side is the *newer*. A UTC cut would put them in one.
    func testARowEitherSideOfLocalMidnightIsTwoGroups() {
        let groups = HistoryGrouping.groups(
            for: [record("2026-09-01T22:30:00.000Z"), record("2026-09-01T21:50:00.000Z")],
            now: at("2026-09-02T08:00:00.000Z"), calendar: paris)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
    }

    func testAnEmptyHistoryProducesNoGroups() {
        XCTAssertTrue(
            HistoryGrouping.groups(
                for: [], now: at("2026-09-01T18:00:00.000Z"), calendar: paris
            ).isEmpty)
    }

    /// Two groups sharing a title are still two groups: `Identifiable` is answered by the day, not
    /// by the word, and "Today" is a word that comes back tomorrow.
    func testGroupsAreIdentifiedByTheirDayAndNotByTheirTitle() {
        let groups = HistoryGrouping.groups(
            for: [record("2026-09-01T22:30:00.000Z"), record("2026-09-01T21:50:00.000Z")],
            now: at("2026-09-02T08:00:00.000Z"), calendar: paris)
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)
    }
}
