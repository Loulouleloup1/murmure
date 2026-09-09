import Foundation

/// The one word-counting rule of the app. Deliberately simple and language-agnostic: split on
/// Unicode whitespace and newlines, keep the tokens that carry at least one letter or digit.
/// `l'affaire` is one word, `--` is none. Statistics are only comparable if every row was counted
/// the same way, so nothing else in the app may count words differently.
public enum WordCount {
    public static func count(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        var words = 0
        for token in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if token.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                words += 1
            }
        }
        return words
    }
}
