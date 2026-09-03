import Foundation

/// The initial prompt Whisper is handed before it hears a word, built from Louis's vocabulary.
///
/// See `docs/benchmarks/2026-09-vocabulary-prompt.md` — 2 180 decodes over 109 real dictations —
/// for every number cited below. Nothing here is a guess.
///
/// **A leading space, always.** WhisperKit's tokenizer cuts a term written at the head of a
/// string into character fragments (`C`, `la`, `ude`) that never occur in transcribed speech,
/// where every word arrives preceded by a space. Measured: `Claude Code` alone repaired 17 of 60
/// occurrences without the space and 50 of 60 with it — for one token FEWER, because
/// `" Claude Code."` tokenizes to 4 tokens against 5 for `"Claude Code."`. This is the single
/// most valuable line in the type.
///
/// **The entries most likely to be mis-heard go last, nearest the audio.** A first-position
/// penalty survives the leading-space fix and has no known mechanism: `WeeFin` repaired 1 of 10
/// times in first position against 10 of 10 anywhere else, on byte-identical prompt tokens,
/// merely permuted. `replacement != nil` means Louis noticed the term coming out wrong often
/// enough to teach the app its correct spelling, so those entries go last, nearest the audio;
/// entries with no `replacement` are pure bias and sort first among the user's own terms.
///
/// **The first slot itself is filled by a filler word, unconditionally.** It rescues whatever
/// term would otherwise sit there regardless of whether that term carries a `replacement` — the
/// benchmark that measured this used plain word lists with no such field, so the correction
/// status of the displaced term played no part in the result. See `sacrificialFillerTerm` for the
/// numbers.
///
/// **Capped at 20 terms and 240 characters, dropping from the front.** The measured toll on the
/// transcript stays under 3 % of words up to ~70 tokens (20 terms) and roughly doubles beyond it.
/// Separately, WhisperKit truncates any prompt over 111 tokens with
/// `Array(promptTokens.suffix(111))`, keeping the tail and discarding the front with no error at
/// all — a 35-term list ordered with its best terms first repaired 0 of 106 occurrences where the
/// same words, reordered, repaired 75. So the cap here must bite well before WhisperKit's does,
/// and it drops from the front for the same reason WhisperKit's own truncation does: what survives
/// nearest the audio is what matters. 240 characters is a PROXY for tokens (~4 characters/token
/// observed on this vocabulary), not a token count — Whisper's tokenizer is not run here.
public enum VocabularyPrompt {
    /// Terms beyond this many are dropped from the front of the ordered list before building.
    public static let maximumTermCount = 20

    /// Characters beyond this many are dropped from the front of the ordered list before building.
    /// A proxy for the ~70-token budget the benchmark measured as safe, not a token count.
    public static let maximumCharacterCount = 240

    /// A semantically inert filler word prepended ahead of every real entry, rescuing whatever
    /// term would otherwise sit in the penalised first slot. Measured against the same benchmark:
    /// prepending it to a 3-term prompt raised repairs from 86 to 92 of 106 for 4 more tokens
    /// (11 -> 15), `Claude Code` alone going from 49/60 to 58/60 — the best result of the whole
    /// campaign. `Murmure` was chosen because it is the app's own name, French rather than English
    /// so it does not tilt the language prior, and it appeared in 0 of 109 transcripts under the
    /// arm that carried it — the same 0 as the baseline, so it does not leak into what gets
    /// written.
    ///
    /// This is unconditional, not dependent on whether the rescued term carries a `replacement`:
    /// the benchmark's arms are plain word lists with no `replacement` field, so what the
    /// measurement shows is that a filler rescues whatever sits first, regardless of correction
    /// status. The "entries with a replacement go last" rule stays as a secondary refinement this
    /// measurement does not test either way.
    public static let sacrificialFillerTerm = "Murmure"

    /// Entries Louis has had to correct carry the most value and go last, nearest the audio.
    /// Alphabetical within each group so the output is deterministic.
    private static func orderedByPriority(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        entries.sorted { lhs, rhs in
            let lhsCorrected = lhs.replacement != nil
            let rhsCorrected = rhs.replacement != nil
            if lhsCorrected != rhsCorrected { return !lhsCorrected && rhsCorrected }
            return (lhs.replacement ?? lhs.term) < (rhs.replacement ?? rhs.term)
        }
    }

    /// Collapses entries that contribute the same word to the prompt -- `replacement ?? term` --
    /// case-insensitively, keeping the LAST occurrence so the survivor sits nearest the audio.
    /// `VocabularyStore` de-duplicates on `term`, a different key space: the correct spelling of a
    /// word plus one of its mis-hearings both contribute the same corrected form here and would
    /// otherwise double it in the prompt.
    private static func deduplicatedByContributedForm(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var lastIndexForKey: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            lastIndexForKey[(entry.replacement ?? entry.term).lowercased()] = index
        }
        let survivingIndices = Set(lastIndexForKey.values)
        return entries.enumerated()
            .filter { survivingIndices.contains($0.offset) }
            .map(\.element)
    }

    private static func joined(_ entries: [VocabularyEntry]) -> String {
        " " + entries.map { $0.replacement ?? $0.term }.joined(separator: ", ") + "."
    }

    /// The prompt, together with the entries a cap dropped to build it.
    ///
    /// Both caps drop whole entries from the front of the ordered list until what remains fits --
    /// never a comma scan or a slice of the joined string, which would cut a term in the middle of
    /// itself the moment it contains one, or stop cutting once no comma is left even though the
    /// single remaining entry alone still exceeds the cap. The character cap is checked against
    /// what this function returns (leading space and full stop included), not the bare joined
    /// list, so a "240-character cap" never quietly returns 242.
    ///
    /// An entry that cannot fit under the character cap on its own is removed before the
    /// front-drop runs, not during it: such an entry can never be part of any valid prompt, so it
    /// is not competing for the tail, and front-dropping in list order would otherwise sacrifice
    /// entries that DO fit while chasing one that never could.
    ///
    /// The filler word (`sacrificialFillerTerm`) is prepended after ordering, de-duplication and
    /// the term cap, so it never counts against the user's 20-term budget and never appears in
    /// `dropped` -- it was never a user entry to begin with. It DOES count against the character
    /// cap, a proxy for a real token budget: the front-drop below trims real entries around it
    /// rather than ever dropping the filler itself, which always stays first. A vocabulary that
    /// collapses to nothing real to say -- empty to start with, or emptied by the caps -- gets no
    /// prompt at all, not a prompt of the filler alone.
    public static func plan(for entries: [VocabularyEntry]) -> VocabularyPromptPlan {
        guard !entries.isEmpty else { return VocabularyPromptPlan(prompt: nil, dropped: []) }

        let ordered = orderedByPriority(entries)
        let deduplicated = deduplicatedByContributedForm(ordered)

        var dropped: [VocabularyEntry] = []
        var kept = deduplicated.filter { entry in
            guard joined([entry]).count > maximumCharacterCount else { return true }
            dropped.append(entry)
            return false
        }

        if kept.count > maximumTermCount {
            let overflow = kept.count - maximumTermCount
            dropped.append(contentsOf: kept.prefix(overflow))
            kept.removeFirst(overflow)
        }

        let filler = VocabularyEntry(term: sacrificialFillerTerm)
        while !kept.isEmpty, joined([filler] + kept).count > maximumCharacterCount {
            dropped.append(kept.removeFirst())
        }

        guard !kept.isEmpty else { return VocabularyPromptPlan(prompt: nil, dropped: dropped) }
        return VocabularyPromptPlan(prompt: joined([filler] + kept), dropped: dropped)
    }

    /// The prompt string, or nil when there is nothing to say.
    ///
    /// Nil rather than `""`: an empty prompt is not the same thing as no prompt, and a caller that
    /// received `""` would have to know to treat it as absent rather than simply passing it on.
    public static func build(from entries: [VocabularyEntry]) -> String? {
        plan(for: entries).prompt
    }
}

/// The result of building a vocabulary prompt: the prompt itself, and what a cap left out of it.
public struct VocabularyPromptPlan: Equatable {
    /// The prompt, or nil when there is nothing to say.
    public let prompt: String?
    /// Entries whose contributed form does not appear in `prompt`, because a cap dropped it.
    /// A term merged into an identical form is NOT dropped -- it is the same word, and reporting
    /// it as lost would be a lie the interface repeats to the user.
    public let dropped: [VocabularyEntry]
}
