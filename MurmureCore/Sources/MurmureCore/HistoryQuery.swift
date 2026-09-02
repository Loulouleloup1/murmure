import Foundation

/// What the search field's contents mean, before anything is asked of the database.
///
/// Three cases and not two, because "nothing typed" and "nothing searchable typed" are different
/// events with opposite answers. `HistoryStore.search` already refuses to return everything for a
/// pattern with no tokens in it — a search that matched everything would read as a search that
/// failed — and this is the type that keeps that refusal intact while still letting an empty field
/// show the whole history.
///
/// It is an enum rather than a `String?` so that the pane cannot mistake one for the other: a
/// query of `"..."` mapped to `nil` would list every dictation Louis has ever made in answer to
/// something he typed, which is the exact confusion the store's own guard exists to prevent.
public enum HistoryQuery: Equatable, Sendable {
    /// The field is empty. The pane lists the page, unfiltered — this is not a search at all.
    case unfiltered
    /// Something searchable was typed. The string is the one to hand to `HistoryStore.search`,
    /// whitespace-collapsed so that two spellings of the same query are one value.
    case tokens(String)
    /// Something was typed and none of it can be searched for: punctuation, quotes, a stray
    /// bracket. No rows, and the pane can say so — never every row.
    case unsearchable

    /// What the field currently holds, read as one of the three above.
    ///
    /// "Searchable" is decided by the presence of at least one alphanumeric **scalar**, which is
    /// Unicode's answer rather than ASCII's: `clé`, `Ω` and `2026` all carry one and are all
    /// things Louis might type. Punctuation, whitespace and the quotes and colons FTS5 would
    /// otherwise read as syntax carry none.
    ///
    /// This deliberately does not try to predict what the tokenizer will do with the string. It
    /// answers the one question the pane has to answer before it asks — is this worth a query —
    /// and `HistorySearchPattern` remains the authority on the rest, including which word is
    /// still being typed.
    public init(typed: String) {
        let collapsed = StatusPanelText.oneLine(typed)
        if collapsed.isEmpty {
            self = .unfiltered
        } else if collapsed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
            self = .tokens(collapsed)
        } else {
            self = .unsearchable
        }
    }
}
