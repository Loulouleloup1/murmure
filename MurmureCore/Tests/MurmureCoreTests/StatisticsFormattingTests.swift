import XCTest
@testable import MurmureCore

final class StatisticsFormattingTests: XCTestCase {
    func testMinutesRoundToWholeMinutesAndSplitHours() {
        XCTAssertEqual(StatisticsFormatting.minutes(nil), "—")
        XCTAssertEqual(StatisticsFormatting.minutes(0), "0 min")
        XCTAssertEqual(StatisticsFormatting.minutes(12.4), "12 min")
        XCTAssertEqual(StatisticsFormatting.minutes(65), "1h 05min")
        XCTAssertEqual(StatisticsFormatting.minutes(600), "10h 00min")
        XCTAssertEqual(StatisticsFormatting.minutes(-1.5), "−2 min")
        XCTAssertEqual(StatisticsFormatting.minutes(-75), "−1h 15min")
    }

    func testWordsPerMinuteIsAWholeNumberOrADash() {
        XCTAssertEqual(StatisticsFormatting.wordsPerMinute(nil), "—")
        XCTAssertEqual(StatisticsFormatting.wordsPerMinute(141.6), "142")
    }

    func testCountsAreGrouped() {
        XCTAssertEqual(StatisticsFormatting.count(12345), "12,345")
        XCTAssertEqual(StatisticsFormatting.count(7), "7")
    }

    func testDurationsPickTheRightUnits() {
        XCTAssertEqual(StatisticsFormatting.duration(38.25), "38 s")
        XCTAssertEqual(StatisticsFormatting.duration(158), "2 min 38 s")
        XCTAssertEqual(StatisticsFormatting.duration(3720), "1 h 02 min")
    }
}
