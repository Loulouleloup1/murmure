import Foundation

/// Why the Vocabulary list is showing nothing.
///
/// Two conditions, and telling them apart is the whole of this type. `VocabularyStore.loadAll()`
/// returns `[]` for a file that has never been created **and** for a file that will not parse --
/// it may not throw, because one bad entry must not cost the rest of the vocabulary -- so an
/// empty list alone cannot say which happened. "No vocabulary yet." over a `vocabulary.json` full
/// of terms that a stray comma made unreadable is the worst possible sentence: it says the file is
/// empty when the file is the problem, and it invites Louis to type back in words he already has.
///
/// **The messages themselves are `VocabularyLoadProblem`'s and are not restated here.** That enum
/// already names the file, the entry index and the key for all six of its cases, and it is already
/// what the pane and the log both show. A second vocabulary of error sentences beside it is two
/// wordings of one failure, which is the arrangement `MenuText` was written to end.
public enum VocabularyEmptyState: Equatable, CustomStringConvertible {
    /// `vocabulary.json` was read and something in it was refused. The problem carried whole, so
    /// the sentence stays the one the store produced.
    case unreadable(VocabularyLoadProblem)
    /// There is no vocabulary file, or it holds an empty array. A fresh install, not a failure.
    case nothingYet

    /// Which of the two this is, or nil when there are entries to list.
    ///
    /// **A problem outranks the entries only when there are none.** A file whose fifth entry has
    /// an unrecognised key still loaded the other four, and the pane shows them with the problem
    /// beside the list -- replacing a list that has content with an error message would hide
    /// working vocabulary because of one line that does not work.
    public static func current(
        problem: VocabularyLoadProblem?, hasEntries: Bool
    ) -> VocabularyEmptyState? {
        if hasEntries { return nil }
        if let problem { return .unreadable(problem) }
        return .nothingYet
    }

    public var description: String {
        switch self {
        case .unreadable(let problem):
            problem.description
        // **Two sentences and the second is not decoration.** An empty pane with one input row
        // above it does not say what putting a word in it will do, and the two halves of a
        // vocabulary entry do genuinely different things -- the term biases what Whisper hears,
        // the replacement corrects the text afterwards (spec §5). Said once, here, where the pane
        // is empty and there is room for it.
        case .nothingYet:
            "No vocabulary yet. A word added here guides what Whisper hears, and a replacement "
                + "beside it corrects the text afterwards."
        }
    }
}
