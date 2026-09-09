import XCTest
@testable import MurmureCore

final class WordCountTests: XCTestCase {
    func testWhitespaceSeparatedTokensWithALetterOrDigitAreWords() {
        XCTAssertEqual(WordCount.count("bonjour tout le monde"), 4)
        XCTAssertEqual(WordCount.count("dbt runs 2026 pipelines"), 4)
        XCTAssertEqual(WordCount.count("line one\nline two\ttabbed"), 5)
    }

    func testAnApostropheKeepsTheContractionAsOneWord() {
        XCTAssertEqual(WordCount.count("l'affaire fit grand bruit"), 4)
        XCTAssertEqual(WordCount.count("qu'il n'y avait"), 3)
    }

    func testPunctuationOnlyTokensAreNotWords() {
        XCTAssertEqual(WordCount.count("--"), 0)
        XCTAssertEqual(WordCount.count("…"), 0)
        XCTAssertEqual(WordCount.count("fin . -- …"), 1)
        XCTAssertEqual(WordCount.count("Bonjour, ça va ?"), 3)
    }

    func testAThinSpaceInsideANumberSplitsItInTwo() {
        XCTAssertEqual(WordCount.count("12\u{202F}000 euros"), 3)
    }

    func testNilAndEmptyAndBlankCountZero() {
        XCTAssertEqual(WordCount.count(nil), 0)
        XCTAssertEqual(WordCount.count(""), 0)
        XCTAssertEqual(WordCount.count("   \n\t "), 0)
    }
}
