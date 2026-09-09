import Foundation

/// The two lists the Vocabulary pane draws, and the one thing every caller must split
/// `VocabularyEntry`s on to build either of them.
///
/// **Two lists, not one, because `VocabularyEntry` already carries two different things** (its
/// own header): a bare term only biases the recogniser, while a term with a `replacement` also
/// corrects the transcript afterwards. A single flat list with an arrow between two fields on
/// every row reads as one operation -- "turn A into B" -- for entries where B does not exist.
/// Naming the split here, once, means the pane, its empty state and its cap notice all read
/// `entry.isCorrection` through the same case rather than each re-deriving `replacement != nil`.
public enum VocabularyGroup: Equatable, Sendable, CaseIterable {
    /// Bare terms -- no `replacement`. Pure bias: they change what Whisper hears and nothing in
    /// the transcript.
    case wordsToRecognise
    /// Terms with a `replacement`. Corrects a known mis-hearing, both in the prompt (as its fixed
    /// form) and in the transcript afterwards.
    case corrections

    /// The heading drawn above this group's list.
    public var heading: String {
        switch self {
        case .wordsToRecognise: "Words to recognise"
        case .corrections: "Corrections"
        }
    }

    /// `heading`, with how many entries this group holds -- the pane's section header, named here
    /// so the separator is chosen once rather than glued together at the one call site.
    public func headingWithCount(_ count: Int) -> String {
        "\(heading) · \(count)"
    }

    /// The label on the composer's segmented picker -- singular, unlike `heading`'s plural list
    /// title, because the picker names the ONE entry being composed right now ("Word to
    /// recognise"), not the list it will join ("Words to recognise").
    public var composerTitle: String {
        switch self {
        case .wordsToRecognise: "Word to recognise"
        case .corrections: "Correction"
        }
    }

    /// One line saying what putting a word in THIS group's list actually does. The same wording
    /// `VocabularyEmptyState.nothingYet`'s sentence uses below -- reused, not restated, so the
    /// pane's section header and its empty-list message never drift into two descriptions of one
    /// group.
    public var subtitle: String {
        switch self {
        case .wordsToRecognise:
            "A word added here guides what Whisper hears -- it does not change your text."
        case .corrections:
            "Add the word Whisper mis-hears and the one it should have written, and this list "
                + "fixes it every time afterwards."
        }
    }

    /// This group's own entries out of the full vocabulary, in whatever order `vocabulary`
    /// already has -- filtering preserves it, so a caller that alphabetises the whole list before
    /// splitting gets an alphabetised group back, with no re-sort here.
    public func entries(in vocabulary: [VocabularyEntry]) -> [VocabularyEntry] {
        switch self {
        case .wordsToRecognise: return vocabulary.filter { !$0.isCorrection }
        case .corrections: return vocabulary.filter(\.isCorrection)
        }
    }
}

/// Why one of the Vocabulary pane's two lists is showing nothing.
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
    /// the sentence stays the one the store produced. Not specific to either group: a file that
    /// will not parse says so under whichever of the two groups asks, since both read from the
    /// same failed load.
    case unreadable(VocabularyLoadProblem)
    /// This group holds no entries -- a fresh install, or simply nothing of this kind yet (a
    /// vocabulary that is all bare terms has an empty Corrections list and nothing wrong with it).
    /// Carries which group it is, so the sentence can say what THIS group's own entries do rather
    /// than repeating what the other half of a `VocabularyEntry` does too.
    case nothingYet(VocabularyGroup)

    /// Which of the two this is, or nil when there are entries to list.
    ///
    /// **A problem outranks the entries only when there are none.** A file whose fifth entry has
    /// an unrecognised key still loaded the other four, and the pane shows them with the problem
    /// beside the list -- replacing a list that has content with an error message would hide
    /// working vocabulary because of one line that does not work.
    public static func current(
        problem: VocabularyLoadProblem?, hasEntries: Bool, group: VocabularyGroup
    ) -> VocabularyEmptyState? {
        if hasEntries { return nil }
        if let problem { return .unreadable(problem) }
        return .nothingYet(group)
    }

    public var description: String {
        switch self {
        case .unreadable(let problem):
            problem.description
        // **Each group says what putting a word in ITS OWN list will do**, not what a
        // vocabulary entry as a whole can do -- the two are drawn apart precisely because a
        // single sentence covering both reads as one operation, which is the affordance problem
        // this whole feature exists to fix.
        case .nothingYet(.wordsToRecognise):
            "No words yet. \(VocabularyGroup.wordsToRecognise.subtitle)"
        case .nothingYet(.corrections):
            "No corrections yet. \(VocabularyGroup.corrections.subtitle)"
        }
    }
}
