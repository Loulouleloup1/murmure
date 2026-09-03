import Foundation
import MurmureCore

/// What the Vocabulary pane is looking at: the entries and the one thing that can go wrong.
///
/// Thin, like `HistoryPaneModel` and for the same reason -- the app target has no test bundle, so
/// anything decided here is verified by reading. Everything that is a decision -- what counts as a
/// duplicate, what a malformed `vocabulary.json` reports, how the initial-prompt cap is computed --
/// lives in `MurmureCore` and is tested there. What is left below is the store call and the
/// published state.
@MainActor
final class VocabularyPaneModel: ObservableObject {
    @Published private(set) var entries: [VocabularyEntry] = []
    /// A save failure. Never swallowed (ruling L7): a save that silently failed would leave the
    /// pane showing an entry that is not actually on disk.
    @Published private(set) var saveProblem: String?
    /// The last thing `vocabulary.json` was refused for while loading. Kept as the value and not
    /// as its description, because whether it empties the pane or merely costs one entry is a
    /// decision, and it is `VocabularyEmptyState`'s.
    @Published private(set) var loadProblem: VocabularyLoadProblem?

    private let fileURL: URL
    /// Lazy, not built in `init`: the store's `report` closure captures `self`, and `self` is not
    /// fully initialized until every stored property -- this one included -- has a value. Read for
    /// the first time from `reload()`, well after `init` has returned.
    private lazy var store = VocabularyStore(fileURL: fileURL) { [weak self] problem in
        self?.loadProblem = problem
    }

    /// `fileURL` is injected rather than resolved here, the same reason `VocabularyStore` itself
    /// takes one: the app hands down `Storage.directory().appendingPathComponent("vocabulary.json")`.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Re-reads `vocabulary.json`. Sorted alphabetically, case-insensitive (design notes §1.2) --
    /// the store's own order is file order, which is not what the pane shows.
    func reload() {
        saveProblem = nil
        loadProblem = nil
        entries = sorted(store.loadAll())
    }

    /// The one sentence an empty list shows, or nil when there are entries to list.
    ///
    /// Which of the two empty states this is -- a file that will not parse, or no file at all --
    /// is `VocabularyEmptyState`'s decision and is tested there. A save failure comes first for
    /// the reason it does in History: it is the most recent thing that happened, and it is why
    /// the list looks the way it does.
    var emptyListMessage: String? {
        guard entries.isEmpty else { return nil }
        if let saveProblem { return saveProblem }
        return VocabularyEmptyState.current(problem: loadProblem, hasEntries: false)?.description
    }

    /// The line above the list. A save failure whatever the list looks like, then a load problem
    /// **only when there are entries**: with none, the empty list below already carries it, and
    /// saying it in both places is one failure wearing two labels.
    var banner: String? {
        if let saveProblem { return saveProblem }
        guard !entries.isEmpty else { return nil }
        return loadProblem?.description
    }

    /// Adds a term, or replaces the existing one of the same name (case-insensitive, matching
    /// `VocabularyStore.loadAll()`'s own duplicate rule). A bare term only biases the recogniser; a
    /// term with a replacement also corrects it after the fact.
    ///
    /// `term` alone commits nothing else; `term` and `replacement` commit both. An empty term
    /// commits nothing at all -- the input row's placeholder text is not a value.
    func add(term: String, replacement: String) {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else { return }
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = VocabularyEntry(
            term: trimmedTerm,
            replacement: trimmedReplacement.isEmpty ? nil : trimmedReplacement)
        var updated = entries.filter {
            $0.term.localizedCaseInsensitiveCompare(trimmedTerm) != .orderedSame
        }
        updated.append(entry)
        persist(updated)
    }

    func delete(_ entry: VocabularyEntry) {
        persist(entries.filter { $0 != entry })
    }

    /// Dismisses the banner. A load problem is not dismissed here on purpose: it is a property of
    /// the file as it is on disk, so the next `reload()` would raise it again -- and a cross that
    /// puts back what it just removed is a control that reads as broken.
    func dismissProblem() {
        saveProblem = nil
    }

    private func persist(_ updated: [VocabularyEntry]) {
        do {
            try store.save(updated)
            reload()
        } catch {
            saveProblem = "The vocabulary could not be saved (\(error.localizedDescription))."
        }
    }

    private func sorted(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        entries.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }
}
