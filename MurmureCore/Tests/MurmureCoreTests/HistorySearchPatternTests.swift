import XCTest
@testable import MurmureCore

/// The `MATCH` expression a half-typed search field turns into.
///
/// `HistoryStoreTests` proves the rule against a real index, which is the test that matters; this
/// one pins the shape of the expression, which is where the rule can be got wrong in ways an
/// index full of French sentences would still let through.
final class HistorySearchPatternTests: XCTestCase {
    private func expression(_ typed: String) -> String? {
        HistorySearchPattern.matchExpression(for: typed)
    }

    /// **The refusal that must not be undone**, one layer below `HistoryQuery`'s. No expression
    /// means no rows, and a search that answered `...` with the whole archive would read as a
    /// search that had failed.
    func testNothingSearchableYieldsNoExpressionAtAll() {
        XCTAssertNil(expression(""))
        XCTAssertNil(expression("   \n\t "))
        XCTAssertNil(expression("..."))
        XCTAssertNil(expression("«» ?! ("))
    }

    /// The word under the cursor is the one still being typed.
    func testTheOnlyWordTypedIsAPrefix() {
        XCTAssertEqual(expression("mo"), "\"mo\"*")
    }

    /// And the words behind it are not. A query that grew vaguer as it grew longer would be worse
    /// than the one Louis complained about, not better.
    func testTheWordsAlreadyFinishedAreMatchedWhole() {
        XCTAssertEqual(expression("moi ava"), "\"moi\" \"ava\"*")
        XCTAssertEqual(expression("le connecteur de stag"), "\"le\" \"connecteur\" \"de\" \"stag\"*")
    }

    /// By position, not by value. `moi moi` is two words and only the second is under the cursor —
    /// a rule written as "the word equal to the last one" would star both.
    func testARepeatedWordIsPrefixedOnlyWhereItIsLast() {
        XCTAssertEqual(expression("moi moi"), "\"moi\" \"moi\"*")
    }

    /// The apostrophe is a separator to `unicode61`, so this word is two tokens. Quoting it as a
    /// phrase puts the `*` on the second one — `t` then something starting with `av` — which is
    /// what reaches `t'avoue`.
    func testAWordCarryingAnApostropheStaysOneWordWithThePrefixOnItsLastToken() {
        XCTAssertEqual(expression("t'av"), "\"t'av\"*")
    }

    /// **The pattern is safe by construction.** Every word is quoted, so FTS5 syntax handed to
    /// the search box is text to search for and never an operator to run — the property
    /// `HistoryStore` was already pinned to, now held here.
    func testFTS5SyntaxIsQuotedIntoTextRatherThanLeftAsOperators() {
        XCTAssertEqual(expression("cache OR pipeline"), "\"cache\" \"OR\" \"pipeline\"*")
        XCTAssertEqual(expression("(worker"), "\"(worker\"*")
    }

    /// A quote of his own is doubled, which is FTS5's own escape. Left alone it would close the
    /// phrase early and the rest of the word would become syntax.
    func testATypedQuoteIsEscapedRatherThanEndingThePhrase() {
        XCTAssertEqual(expression("\"cache\""), "\"\"\"cache\"\"\"*")
    }

    /// Accents are handed through untouched, because the folding belongs to the table's tokenizer
    /// (`remove_diacritics 2`) and not to a second one here that would have to agree with it.
    func testAnAccentedWordReachesTheIndexAsItWasTyped() {
        XCTAssertEqual(expression("clé"), "\"clé\"*")
    }

    /// A stray bracket after a word is dropped rather than quoted into an empty phrase, and the
    /// prefix stays on the last word that is one. Same Unicode test `HistoryQuery` uses — one
    /// definition of searchable, not two.
    func testAWordThatIsOnlyPunctuationIsDroppedAndThePrefixStaysOnTheLastRealWord() {
        XCTAssertEqual(expression("mo --"), "\"mo\"*")
        XCTAssertEqual(expression("... moi ... ava"), "\"moi\" \"ava\"*")
    }

    /// Digits are words. `2026` is something Louis types.
    func testADigitIsAWord() {
        XCTAssertEqual(expression("2026"), "\"2026\"*")
    }
}
