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
    /// A load or save failure. Never swallowed (ruling L7): a save that silently failed would leave
    /// the pane showing an entry that is not actually on disk.
    @Published private(set) var problem: String?

    private let fileURL: URL
    /// Lazy, not built in `init`: the store's `report` closure captures `self`, and `self` is not
    /// fully initialized until every stored property -- this one included -- has a value. Read for
    /// the first time from `reload()`, well after `init` has returned.
    private lazy var store = VocabularyStore(fileURL: fileURL) { [weak self] problem in
        self?.problem = problem.description
    }

    /// `fileURL` is injected rather than resolved here, the same reason `VocabularyStore` itself
    /// takes one: the app hands down `Storage.directory().appendingPathComponent("vocabulary.json")`.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Re-reads `vocabulary.json`. Sorted alphabetically, case-insensitive (design notes §1.2) --
    /// the store's own order is file order, which is not what the pane shows.
    func reload() {
        problem = nil
        entries = sorted(store.loadAll())
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

    func dismissProblem() {
        problem = nil
    }

    private func persist(_ updated: [VocabularyEntry]) {
        do {
            try store.save(updated)
            reload()
        } catch {
            problem = "The vocabulary could not be saved (\(error.localizedDescription))."
        }
    }

    private func sorted(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        entries.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }
}
