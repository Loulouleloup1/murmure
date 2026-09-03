import Foundation

/// The find→replace pass a transcript goes through after transcription and before the refiner
/// (spec §5, lot 4 T6, §4.5) -- corrects a word Whisper keeps mis-hearing, using the vocabulary
/// Louis curated for exactly that.
///
/// **Single pass over the ORIGINAL text, not a loop of sequential replacements.** The obvious
/// implementation -- `for entry in entries { text = text.replacing(entry.term, entry.replacement) }`
/// -- cascades: an earlier entry's replacement can contain a later entry's term, and that later
/// entry then fires on ground the first one just created. Two entries `"cloud code" → "Claude Code"`
/// and `"Code" → "CODE"` applied to `"open cloud code now"` give `"open Claude CODE now"` in one
/// order and `"open Claude Code now"` in the other -- the plan's ordering requirement exists
/// precisely because that loop is the natural thing to write. Every entry here is matched against
/// the text as transcribed; the replacements are placed afterwards, all at once, so no replacement
/// is ever eligible to match inside another one's output and the entries' order in the array cannot
/// change the result.
///
/// **The word-boundary rule: a term matches only where neither the character immediately before
/// nor immediately after it is a Unicode letter or number.** `DCG` matches in `the DCG file` and in
/// `(DCG)` but not inside `ADCGX`, because `A` and `X` are letters. A term itself may contain an
/// internal space (`cloud code`) -- the boundary check only ever looks at the two characters
/// flanking the WHOLE term, never at the space inside it, so `the cloud coder` does not match: the
/// character right after `code` is `r`, a letter. A French elision like `l'code` DOES let `code`
/// match, because `'` is punctuation, not a letter -- the apostrophe already reads as a boundary,
/// which is the same reading a human proofreader would give it. Matching is case-insensitive
/// (`cloud code` and `Cloud Code` both match); what is written to the output is the replacement
/// exactly as the user typed it, never a case-adjusted copy of what matched -- the replacement is
/// authoritative, the transcript's casing is not.
///
/// Entries whose `replacement` is `nil` name a term that is already correctly spelled; they exist
/// only to bias the recogniser's prompt (`VocabularyPrompt`) and are skipped here entirely.
public enum VocabularyReplacement {
    /// Applies every entry that has a `replacement` to `text` in one non-cascading pass.
    ///
    /// The returned text is always canonically composed (NFC), whether or not any entry matched --
    /// see the note on `normalizedText` below. Beyond that, this is a no-op when `text` or `entries`
    /// is empty, or when no term occurs. Two entries whose terms overlap in the text (one term is a
    /// substring position of another's match) resolve by preferring the earlier match, then the
    /// longer one at a tie, then the entry whose replacement sorts first when even that ties; which
    /// entry that was in the array, or where it sat, never affects which span wins.
    public static func apply(to text: String, using entries: [VocabularyEntry]) -> String {
        // Composed UNCONDITIONALLY, before either guard below, not only on the path where a match
        // fires: a term or a transcript that reaches this pass in decomposed form (NFD -- a name
        // copied out of a macOS filename is a real source of this, not a hypothetical one) must
        // match its precomposed counterpart, which requires normalizing the haystack before the
        // regex ever runs. But the CALLER must not see a result that depends on whether some
        // unrelated word happened to match: the same NFD dictation would otherwise come back as NFC
        // on a run where a vocabulary term fired and as untouched NFD on a run where it did not --
        // two different byte sequences for the same transcript, silently, based on something the
        // caller has no way to predict. NFC and NFD render identically and Swift's `String ==`
        // already treats them as equal, so this is a deliberate, harmless canonicalization of the
        // output, not a leak of the matcher's internals -- and it is unconditional precisely so nothing
        // about `apply`'s result depends on whether anything matched.
        let normalizedText = text.precomposedStringWithCanonicalMapping
        guard !normalizedText.isEmpty, !entries.isEmpty else { return normalizedText }

        let nsText = normalizedText as NSString
        let matches = _matches(in: nsText, entries: entries)
        guard !matches.isEmpty else { return normalizedText }

        return _assemble(nsText, applying: _resolveOverlaps(matches))
    }

    /// One occurrence of one entry's term, found by its own regex against the untouched text.
    private struct _Match {
        let range: NSRange
        let replacement: String
    }

    /// Runs every entry's pattern over the full text independently. Nothing here reads a previous
    /// entry's result, which is what makes the pass non-cascading.
    private static func _matches(in nsText: NSString, entries: [VocabularyEntry]) -> [_Match] {
        let fullRange = NSRange(location: 0, length: nsText.length)
        var matches: [_Match] = []
        for entry in entries {
            // Normalized here too (Defect E), not only in `VocabularyStore.loadAll()`: an entry
            // built directly by a settings pane never passes through the store, and without this an
            // untrimmed term fails to match, or `replacement: ""` reaches `_assemble` literally and
            // erases the matched term from the transcript instead of leaving it alone.
            guard let normalized = entry.normalized(), let replacement = normalized.replacement,
                  let regex = _regex(for: normalized.term) else {
                continue
            }
            for result in regex.matches(in: nsText as String, range: fullRange) {
                matches.append(_Match(range: result.range, replacement: replacement))
            }
        }
        return matches
    }

    /// A case-insensitive, whole-term regex for `term`, or nil for a term too degenerate to search
    /// for (empty -- `_matches` above only ever calls this with an already-normalized term, but
    /// `_regex` stays defensive since it is a generally-applicable building block, not a promise
    /// that no caller could pass it something Defect E's normalization would have stripped).
    ///
    /// `\p{L}`, `\p{N}` and `\p{M}` -- Unicode letters, numbers and COMBINING MARKS, not ASCII `\w`
    /// -- so a term next to an accented word ("référentiel") is bounded correctly. `\p{M}` matters
    /// because a combining mark (e.g. U+0301 COMBINING ACUTE ACCENT in a decomposed "café") is
    /// neither a letter nor a digit; omitting it lets a shorter term match INSIDE a longer
    /// decomposed word instead of treating the mark as part of it.
    ///
    /// `term` is composed to NFC before the pattern is built, matching the NFC the haystack is
    /// composed to in `apply` -- a term copied out of a macOS filename can arrive decomposed (NFD)
    /// even when the transcript it must match is not, and the two must agree on one form or a
    /// byte-exact regex against the other form finds nothing at all.
    private static func _regex(for term: String) -> NSRegularExpression? {
        guard !term.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: term.precomposedStringWithCanonicalMapping)
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}])" + escaped + "(?![\\p{L}\\p{N}\\p{M}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Greedy interval selection: matches sorted by start position, then by length descending, and
    /// kept only when they start at or after the end of the last one kept. Depends solely on each
    /// match's own position, length and replacement text, never on which entry produced it or where
    /// that entry sat in the input array -- so the result is the same for any ordering of `entries`.
    private static func _resolveOverlaps(_ matches: [_Match]) -> [_Match] {
        let ordered = matches.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            // Same span, same length: two entries whose terms are case-variants of the same word
            // (`gpt` and `GPT`) produce a genuine tie neither position nor length can break.
            // Breaking it on the replacement text keeps the result total and independent of the
            // input array's order -- `Array.sorted` is not documented as stable, and even a stable
            // sort would just mean "whichever entry came first," reintroducing the very
            // order-dependence this is meant to remove.
            return $0.replacement < $1.replacement
        }
        var kept: [_Match] = []
        var end = 0
        for match in ordered where match.range.location >= end {
            kept.append(match)
            end = match.range.location + match.range.length
        }
        return kept
    }

    /// Rebuilds the string by walking the non-overlapping matches left to right, copying what is
    /// between them and substituting each match's replacement verbatim. Stays in `NSString`
    /// throughout -- `NSRange` counts UTF-16 code units, which disagree with Swift's own
    /// `String.Index` the moment the text holds a character (accented or emoji) that is not one
    /// UTF-16 unit, and mixing the two would either mis-slice the text or crash.
    private static func _assemble(_ nsText: NSString, applying matches: [_Match]) -> String {
        var result = ""
        var cursor = 0
        for match in matches {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += match.replacement
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }
}
