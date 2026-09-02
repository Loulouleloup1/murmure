import Foundation

/// What a half-typed search field means to FTS5.
///
/// The seam T3 left open and T5 did not close. `FTS5Pattern(matchingAllTokensIn:)` emits bare
/// tokens, so `mo` asked the index for the word `mo` and got nothing until the `i` landed — a
/// search field that answers only finished words answers nothing at all, because typing is the
/// only way anyone uses one. Louis reported it as `mo` finding nothing and `moi` finding five,
/// and as `t'av` finding nothing while `t'avoue` sat in the archive.
///
/// **The rule: every word you have finished is a word; the last one is still being typed.** The
/// last word matches as a prefix, the earlier ones whole. The alternative — every word a prefix —
/// makes a query vaguer the longer it gets, which is the failure prefix search is prone to:
/// `moi ava` would start returning `moins` as well, and Louis would be no better off than before.
/// A word he finished and put a space after is a word he meant.
///
/// **Why whole quoted words rather than tokens.** Each word is emitted as a quoted FTS5 phrase,
/// which does two things at once. It delegates every question about what a token is to the
/// *table's own* tokenizer — `unicode61 remove_diacritics 2`, so `cle` still finds `clé` — rather
/// than to a second tokenizer here that would have to agree with it. And it makes the pattern
/// safe by construction: inside a quoted phrase, FTS5 syntax is text. `cache OR pipeline` stays a
/// search for three words, which is what the search box promises and what `HistoryStore` was
/// already pinned to.
///
/// It also lands the prefix in the right place for `t'av`. The apostrophe is a separator, so that
/// word is the two tokens `t` and `av`; the phrase `"t'av"*` asks for `t` followed by something
/// starting with `av`, which is `t'avoue`. Hanging a `*` on the typed string as a whole would
/// have asked for a token starting with `av` anywhere and a token `t` anywhere — looser, and for
/// a query like `l'app` loose enough to be useless.
public enum HistorySearchPattern {
    /// The `MATCH` expression for what is currently typed, or nil when there is nothing to ask.
    ///
    /// Nil rather than a pattern matching everything: a search that returned the whole archive in
    /// answer to `...` would read as a search that had failed, and `HistoryStore.search` turns
    /// this nil into no rows. That refusal predates this type and survives it.
    ///
    /// Words carrying no alphanumeric scalar are dropped rather than quoted, on the same Unicode
    /// test `HistoryQuery` uses one layer up — one definition of "searchable", not two. So the
    /// prefix lands on the last word that could be a word, not on a trailing bracket.
    public static func matchExpression(for typed: String) -> String? {
        let words = typed
            .split(whereSeparator: \.isWhitespace)
            .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
        guard !words.isEmpty else { return nil }

        return words.enumerated()
            .map { index, word in
                let phrase = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                // Indexed rather than compared against the last word: `moi moi` is two words, and
                // only the second of them is the one under the cursor.
                return index == words.count - 1 ? phrase + "*" : phrase
            }
            .joined(separator: " ")
    }
}
