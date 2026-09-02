import XCTest
@testable import MurmureCore

/// What the search field's contents mean before anything is asked of the database.
///
/// The distinction being defended is between "nothing typed" and "nothing searchable typed". They
/// have opposite answers -- the whole history, and none of it -- and a type with two cases would
/// have to pick one of them for both.
final class HistoryQueryTests: XCTestCase {
    func testAnEmptyFieldIsNotASearchAtAll() {
        XCTAssertEqual(HistoryQuery(typed: ""), .unfiltered)
    }

    func testAFieldOfOnlyWhitespaceIsAlsoNotASearch() {
        XCTAssertEqual(HistoryQuery(typed: "   \n\t "), .unfiltered)
    }

    /// **The refusal that must not be undone.** `HistoryStore.search` already answers a pattern
    /// with no tokens in it with no rows rather than with every row, because a search that matched
    /// everything reads as a search that failed. Mapping punctuation to `.unfiltered` here would
    /// undo that one layer up: Louis types `...` and gets every dictation he has ever made.
    func testAFieldOfOnlyPunctuationIsASearchThatCanMatchNothing() {
        XCTAssertEqual(HistoryQuery(typed: "..."), .unsearchable)
        XCTAssertEqual(HistoryQuery(typed: "«»"), .unsearchable)
        XCTAssertEqual(HistoryQuery(typed: " ?! "), .unsearchable)
    }

    func testAnOrdinaryWordIsSearchedFor() {
        XCTAssertEqual(HistoryQuery(typed: "connecteur"), .tokens("connecteur"))
    }

    /// Unicode's answer and not ASCII's: Louis dictates French, and `clé` carries a letter in the
    /// only sense that matters here.
    func testAnAccentedWordIsSearchable() {
        XCTAssertEqual(HistoryQuery(typed: "clé"), .tokens("clé"))
    }

    func testADigitIsSearchable() {
        XCTAssertEqual(HistoryQuery(typed: "2026"), .tokens("2026"))
    }

    /// Collapsed, so that two spellings of one query are one value -- which is what lets the pane
    /// compare the query it has against the query it ran without re-running it.
    func testTheQueryIsCollapsedSoTwoSpellingsAreOneValue() {
        XCTAssertEqual(
            HistoryQuery(typed: "  connecteur   staging \n"), .tokens("connecteur staging"))
        XCTAssertEqual(HistoryQuery(typed: "connecteur staging"), .tokens("connecteur staging"))
    }

    /// FTS5 syntax is not stripped here. `HistoryStore` hands the string to
    /// `HistorySearchPattern`, which is the authority on what a word is and on which of them
    /// is still being typed; this type
    /// answers only the question the pane has before it asks -- is this worth a query.
    func testSomethingCarryingFTS5SyntaxIsStillASearchableQuery() {
        XCTAssertEqual(HistoryQuery(typed: "\"connecteur\" OR"), .tokens("\"connecteur\" OR"))
    }
}
