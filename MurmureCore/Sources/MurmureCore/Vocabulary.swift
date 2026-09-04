import Foundation

/// One entry of the hand-edited vocabulary (spec §7).
///
/// `term` is what to look for in a transcript. `replacement` is the correct form, present only
/// when `term` is a known mis-hearing -- a bare `{ "term": "Claude Code" }` is already correct and
/// only biases the recogniser, while `{ "term": "cloud code", "replacement": "Claude Code" }`
/// corrects a mis-hearing. A consumer building the recogniser prompt must read `replacement ??
/// term`, never `term` alone: the prompt is only ever allowed to contain correct spellings, so an
/// entry that names a mis-hearing must contribute its fix and not the mis-hearing itself.
public struct VocabularyEntry: Codable, Equatable, Sendable {
    public var term: String
    public var replacement: String?

    public init(term: String, replacement: String? = nil) {
        self.term = term
        self.replacement = replacement
    }

    /// Trims `term` and `replacement`, and folds a blank `replacement` to nil. The one place that
    /// decides what a "usable" entry looks like, so `VocabularyStore.loadAll()` (an entry
    /// hand-typed into `vocabulary.json`) and `VocabularyReplacement.apply(to:using:)` (an entry a
    /// settings pane can build directly, never touching the store) call this rather than each
    /// keeping its own copy -- neither path can then be bypassed into treating an untrimmed term or
    /// an empty-string `replacement` as usable.
    ///
    /// Returns nil when `term` is empty or all whitespace once trimmed: there is nothing left to
    /// search for. A `replacement` that is empty or whitespace-only, once trimmed, is folded to nil
    /// rather than kept as-is -- `replacement: ""` read literally means "replace the matched term
    /// with nothing," erasing it from the transcript, when an empty field actually means "no
    /// correction."
    public func normalized() -> VocabularyEntry? {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else { return nil }

        let trimmedReplacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VocabularyEntry(
            term: trimmedTerm,
            replacement: (trimmedReplacement?.isEmpty ?? true) ? nil : trimmedReplacement)
    }

    /// Whether this entry corrects a mis-hearing rather than merely biasing the recogniser
    /// toward it -- the one bit `VocabularyGroup` splits the pane's two lists on, and the one
    /// `VocabularyPromptPlan.noticeText` reads to say what a dropped entry still does. Named here,
    /// once, rather than as `replacement != nil` at each call site, because that comparison
    /// carries meaning ("has been corrected before") that reads as an implementation detail
    /// wherever it is spelled out again.
    public var isCorrection: Bool { replacement != nil }

    /// Whether "New word"'s current text would add anything if committed right now -- the same
    /// emptiness rule `normalized()` enforces, named here so the pane's Add button can disable
    /// itself in lockstep with what pressing it (or Enter) would actually do, rather than the view
    /// re-deriving "is this blank, once trimmed" on its own.
    public static func isWordAddable(_ term: String) -> Bool {
        VocabularyEntry(term: term).normalized() != nil
    }

    /// Whether a correction row's two fields would add anything if committed right now. Both must
    /// hold real text: an empty "Should be" refuses the whole correction rather than downgrading
    /// it to a bare word, the rule `VocabularyPaneModel.add(term:replacement:)`'s caller
    /// (`commitCorrection`) already enforces -- so this is deliberately NOT
    /// `isWordAddable(term) && isWordAddable(replacement)` read as two independent words, it is
    /// `replacement` held to the stricter "must not be blank" rather than `normalized()`'s own
    /// "blank folds to nil, which is still usable" rule.
    public static func isCorrectionAddable(term: String, replacement: String) -> Bool {
        guard isWordAddable(term) else { return false }
        return !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `entries` with `self` in place of the existing entry of the same `term`
    /// (case-insensitive, matching `VocabularyStore.loadAll()`'s own duplicate rule) -- appended
    /// when there is none.
    ///
    /// **The one behaviour a user can hit by accident**, now that the pane draws two input rows
    /// for what is still one array keyed on `term` alone. Typing a bare "Trucost" into "Words to
    /// recognise" when a correction already exists for "Trucost" does not add a second row beside
    /// it -- it REPLACES the correction, moving the term into the other group and losing the
    /// replacement. This is deliberate, not a gap left over from the single-list pane: a file may
    /// never hold two entries for one term (`VocabularyStore.loadAll()`'s own duplicate rule,
    /// "the last one wins"), so upserting immediately does what a reload would collapse the file
    /// into anyway, rather than leaving a moment where two rows on screen disagree with what a
    /// save-then-reload would actually keep.
    public func upserting(into entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var updated = entries.filter {
            $0.term.localizedCaseInsensitiveCompare(term) != .orderedSame
        }
        updated.append(self)
        return updated
    }
}

/// A vocabulary entry that could not be used, and why. Reported one by one, mirroring
/// `ModeLoadProblem`, so the bad entry is named without costing the rest of the file.
public enum VocabularyLoadProblem: Equatable, CustomStringConvertible {
    case unreadableFile(message: String)
    case malformedJSON(message: String)
    case malformedEntry(index: Int, message: String)
    case unknownKey(index: Int, key: String)
    case emptyTerm(index: Int)
    case duplicateTerm(term: String)

    public var description: String {
        switch self {
        case .unreadableFile(let message): "vocabulary.json: unreadable -- \(message)"
        case .malformedJSON(let message): "vocabulary.json: not valid vocabulary JSON -- \(message)"
        case .malformedEntry(let index, let message):
            "vocabulary.json: entry \(index) is not a valid vocabulary entry -- \(message)"
        case .unknownKey(let index, let key):
            "vocabulary.json: entry \(index) has an unrecognized key \(key.debugDescription) -- skipped"
        case .emptyTerm(let index): "vocabulary.json: entry \(index) has an empty term -- skipped"
        case .duplicateTerm(let term):
            "vocabulary.json: \(term.debugDescription) appears more than once -- the last one wins"
        }
    }
}

/// Reads and writes `vocabulary.json` (spec §7, lot 4 decision Q-NB3), the plain JSON array of
/// `VocabularyEntry` that sits beside `modes/` and is meant to be edited by hand in a text editor.
public struct VocabularyStore {
    private let fileURL: URL
    private let report: (VocabularyLoadProblem) -> Void

    /// `fileURL` is injected rather than resolved here so tests never reach the real
    /// `Application Support/Murmure/vocabulary.json`; the app passes
    /// `Storage.directory().appendingPathComponent("vocabulary.json")`.
    ///
    /// `report` is not optional, for the same reason as `ModeStore`'s (ruling L7): `loadAll()`
    /// cannot throw -- one bad entry must not cost the rest of the vocabulary -- so this closure is
    /// the only way a skipped entry ever reaches anyone, and a store built without one would drop
    /// entries in silence.
    public init(fileURL: URL, report: @escaping (VocabularyLoadProblem) -> Void) {
        self.fileURL = fileURL
        self.report = report
    }

    /// Every usable entry, in file order except where a duplicate term reorders nothing (see
    /// below). Does not throw: a mistyped `vocabulary.json` may not cost the whole vocabulary, so a
    /// bad file or a bad entry is reported through `report` and skipped.
    public func loadAll() -> [VocabularyEntry] {
        // A file that has never been created is a fresh install with no vocabulary yet, not a
        // problem worth telling anyone about.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            report(.unreadableFile(message: error.localizedDescription))
            return []
        }

        // Parsed with `JSONSerialization`, not `JSONDecoder().decode([VocabularyEntry].self, ...)`
        // directly: the latter fails the WHOLE array the moment one entry has the wrong shape (a
        // `term` that is a number, say), which is exactly the failure this type promises never to
        // have. `JSONSerialization` gives per-element access to a syntactically valid array, so one
        // bad entry can be reported by index and skipped without costing its neighbours. A file
        // that is not valid JSON at all, or whose top level is not an array, has no per-element
        // structure to salvage and is still, correctly, a whole-file failure.
        let elements: [Any]
        do {
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                report(.malformedJSON(message: "top-level value is not a JSON array"))
                return []
            }
            elements = array
        } catch {
            report(.malformedJSON(message: error.localizedDescription))
            return []
        }

        var entries: [VocabularyEntry] = []
        // Term -> its position in `entries`, so a later duplicate overwrites the earlier one in
        // place instead of appending a second row for the same term.
        var indexForTerm: [String: Int] = [:]

        for (index, element) in elements.enumerated() {
            guard let entry = decodeEntry(element, at: index) else { continue }

            // Trimmed and blank-replacement-to-nil, not just checked for emptiness: this file is
            // hand-edited in a text editor, which is exactly where stray whitespace comes from, and
            // an untrimmed term or replacement breaks both consumers -- the prompt gets a padded
            // word, and the matcher looks for spaces that are never in the transcript.
            guard let normalized = entry.normalized() else {
                report(.emptyTerm(index: index))
                continue
            }

            // Case-insensitive, because a hand-edited file that has both "Claude Code" and
            // "claude code" is one term twice, not two -- and it would double that term in the
            // prompt built from this list. Last one in the file wins its content, which is what
            // whoever edited the file last, at the bottom, most likely meant to happen; but the
            // entry keeps the position of its FIRST appearance, so a hand-edit that only touches
            // the replacement of an existing term does not reshuffle the rest of the list.
            let key = normalized.term.lowercased()
            if let existing = indexForTerm[key] {
                report(.duplicateTerm(term: normalized.term))
                entries[existing] = normalized
            } else {
                indexForTerm[key] = entries.count
                entries.append(normalized)
            }
        }
        return entries
    }

    /// Decodes one array element, reporting and returning nil rather than throwing: a `{ "term": 42
    /// }` or a misspelled `"replacment"` key must cost only this one entry, never its neighbours.
    private func decodeEntry(_ element: Any, at index: Int) -> VocabularyEntry? {
        guard let object = element as? [String: Any] else {
            report(.malformedEntry(index: index, message: "not a JSON object"))
            return nil
        }

        // `JSONDecoder` silently ignores keys it does not recognize, so a misspelled "replacment"
        // would otherwise load as a bare term with no correction and no sign anything was wrong --
        // the exact failure this guards against, checked before `VocabularyEntry`'s own `Codable`
        // conformance ever sees the object.
        let knownKeys: Set<String> = ["term", "replacement"]
        if let unknownKey = object.keys.sorted().first(where: { !knownKeys.contains($0) }) {
            report(.unknownKey(index: index, key: unknownKey))
            return nil
        }

        do {
            // `object` was produced by `JSONSerialization` from `data`, so it is already a valid
            // top-level JSON object and safe to re-encode. Decoding it back through
            // `VocabularyEntry`'s own `Codable` conformance -- rather than reading `object["term"]`
            // by hand -- keeps a single source of truth for what a valid entry looks like.
            let entryData = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(VocabularyEntry.self, from: entryData)
        } catch {
            report(.malformedEntry(index: index, message: error.localizedDescription))
            return nil
        }
    }

    /// Writes the array back, pretty-printed with sorted keys so a hand-edited file and a saved
    /// file do not differ gratuitously in git-less diffs -- same reasoning as `ModeStore.encoder`.
    public func save(_ entries: [VocabularyEntry]) throws {
        try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
