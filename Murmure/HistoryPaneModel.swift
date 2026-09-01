import AVFoundation
import AppKit
import MurmureCore
import SwiftUI
import os

/// What the History pane is looking at: the query, the rows it produced, the selected row, and
/// the five things that can be done to it.
///
/// Thin, like `DictationArchive` and `ModeAwareRefinement` and for the same reason -- the app
/// target has no test bundle, so anything decided here is verified by reading. Everything that is
/// a decision is in `MurmureCore` and tested there: what the query means (`HistoryQuery`), which
/// day a row is under (`HistoryGrouping`), what its two lines say (`HistoryRow`), which lens it
/// offers and what its metadata block is (`HistoryDetail`). What is left below is the database
/// call, the pasteboard, the Finder, an `AVAudioPlayer` and one `FileManager.removeItem`.
@MainActor
final class HistoryPaneModel: ObservableObject {
    /// What is typed in the header's search field. Every keystroke re-runs the query: FTS5 over a
    /// month of dictations is an index lookup, and a debounce would buy nothing and cost the
    /// feeling the search is meant to have. (The gate that decides whether that holds on the real
    /// database is Louis's, not a test's.)
    @Published var searchField: String = "" {
        didSet { if oldValue != searchField { reload() } }
    }

    @Published private(set) var groups: [HistoryDateGroup] = []
    /// Something was typed that cannot be searched for -- punctuation, a stray bracket. Distinct
    /// from "no results", because the pane says different things about them, and never the same
    /// thing as an empty field (`HistoryQuery`).
    @Published private(set) var unsearchable = false
    /// The database would not open, or a read failed. The window is where T9 will put this
    /// properly; until then it is at least held rather than dropped.
    @Published private(set) var problem: String?

    @Published var selectedID: Int64?
    /// Which text the detail pane is showing. Reset whenever the selection moves, because a lens
    /// is a property of the record being read and not a preference.
    @Published var lens: HistoryLens = .refined

    /// A re-refinement is in flight; the actions are disabled while it is.
    @Published private(set) var isProcessing = false
    @Published private(set) var isPlaying = false

    let recordings: URL
    private let store: HistoryStore?
    private let reRefine: (String, Mode) async -> ReRefinement
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "history")
    private var player: AVAudioPlayer?
    private var playbackWatcher: PlaybackWatcher?

    /// What a re-refinement produced, and what it cost.
    struct ReRefinement {
        let text: String
        /// Nil when the refinement ran and returned something. Non-nil means the raw transcript
        /// came back instead -- Ollama unreachable, the model missing, the mode unusable -- and
        /// the row must not then be rewritten to claim a refinement happened.
        let notice: RefinementNotice?
        let seconds: Double
    }

    init(
        store: HistoryStore?,
        recordings: URL,
        reRefine: @escaping (String, Mode) async -> ReRefinement
    ) {
        self.store = store
        self.recordings = recordings
        self.reRefine = reRefine
    }

    // MARK: - Reading

    /// The selected record, found by scanning what is on screen rather than fetched again.
    ///
    /// A second fetch by id would be a second answer, and the two could disagree the instant
    /// anything else wrote to the database -- which is every dictation Louis makes with the window
    /// open.
    var selected: HistoryRecord? {
        guard let selectedID else { return nil }
        for group in groups {
            if let match = group.records.first(where: { $0.id == selectedID }) { return match }
        }
        return nil
    }

    var isEmpty: Bool { groups.isEmpty }

    /// Re-reads the history under the current query.
    ///
    /// `Date()` and `Calendar.current` are read HERE and handed down, which is the whole reason
    /// `HistoryGrouping` takes them: the grouping is pure, and this is the one place in the app
    /// that is allowed to ask what day it is.
    func reload() {
        guard let store else {
            problem = "The history database could not be opened."
            groups = []
            return
        }
        do {
            let records: [HistoryRecord]
            switch HistoryQuery(typed: searchField) {
            case .unfiltered:
                unsearchable = false
                records = try store.page(limit: HistoryLayout.pageSize)
            case .tokens(let query):
                unsearchable = false
                records = try store.search(query, limit: HistoryLayout.pageSize)
            case .unsearchable:
                unsearchable = true
                records = []
            }
            groups = HistoryGrouping.groups(
                for: records, now: Date(), calendar: Calendar.current)
            problem = nil
            // A selection that the new query no longer contains has to go, or the detail pane
            // keeps showing a row that is not in the list beside it.
            if let selectedID, selected == nil { self.selectedID = nil }
            if selectedID == nil { selectedID = groups.first?.records.first?.id }
            resetLens()
        } catch {
            log.error("history read failed: \(error.localizedDescription, privacy: .public)")
            problem = "The history could not be read (\(error.localizedDescription))."
            groups = []
        }
    }

    /// The lens the newly selected record opens on. Called on every selection change, because a
    /// `Refined` lens left over from the previous row would show an empty pane on a `Voice`
    /// dictation.
    func resetLens() {
        guard let selected else { return }
        lens = HistoryDetail.defaultLens(for: selected)
    }

    // MARK: - Copy

    /// The text currently on screen, not "the refined text": the button copies what is being
    /// looked at, which is the only reading of it that cannot surprise anyone.
    func copySelection() {
        guard let selected, let text = HistoryDetail.text(lens, of: selected) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - The audio

    func audioURL(for record: HistoryRecord) -> URL? {
        guard let url = record.audioURL(inRecordings: recordings),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Reveals the WAV in the Finder. Nil-guarded at the call site as well: the audio is purged
    /// after three days, so a row whose text is still live and whose file is gone is the normal
    /// state of most of this list.
    func revealAudio() {
        guard let selected, let url = audioURL(for: selected) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Plays the recording, or stops the one playing. One player at a time: pressing Play on a
    /// second row while the first is still going would give two dictations talking at once.
    func togglePlayback() {
        if isPlaying { stopPlayback(); return }
        guard let selected, let url = audioURL(for: selected) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let watcher = PlaybackWatcher { [weak self] in self?.stopPlayback() }
            player.delegate = watcher
            self.player = player
            playbackWatcher = watcher
            isPlaying = player.play()
        } catch {
            log.error("""
                could not play \(url.lastPathComponent, privacy: .public) -- \
                \(error.localizedDescription, privacy: .public)
                """)
            problem = "That recording could not be played (\(error.localizedDescription))."
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playbackWatcher = nil
        isPlaying = false
    }

    /// `AVAudioPlayer`'s delegate has to be an `NSObject`, and `HistoryPaneModel` is not one.
    private final class PlaybackWatcher: NSObject, AVAudioPlayerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            MainActor.assumeIsolated { onFinish() }
        }
    }

    // MARK: - Delete

    /// Removes the row **and its WAV**.
    ///
    /// The store deliberately never touches files (`HistoryStore`), so the decision is the
    /// caller's and it is this: the file goes. The retention purge finds audio through the rows,
    /// so a WAV left behind by a deleted row is a file nothing would ever collect -- 4.6 MB,
    /// measured, per dictation, for ever. The confirmation in front of this is what makes it safe
    /// to be irreversible.
    func deleteSelection() {
        guard let store, let selected, let id = selected.id else { return }
        stopPlayback()
        let audio = audioURL(for: selected)
        do {
            try store.delete(id: id)
            if let audio { try? FileManager.default.removeItem(at: audio) }
            selectedID = nil
            reload()
        } catch {
            log.error("history row not deleted: \(error.localizedDescription, privacy: .public)")
            problem = "That dictation could not be deleted (\(error.localizedDescription))."
        }
    }

    // MARK: - Process again (D12)

    /// The modes a re-refinement can be run through: the ones that have a refiner.
    ///
    /// A transcribe-only mode would return the transcript unchanged, so offering it would be
    /// offering a button that does nothing.
    func refiningModes(from modes: [Mode]) -> [Mode] {
        modes.filter(\.llm.enabled)
    }

    /// Re-refines the stored RAW transcript through the chosen mode and writes the result back.
    ///
    /// **Re-refine only, never re-transcribe** (D12): re-transcribing needs the WAV, which the
    /// retention policy deletes after three days, so the expensive variant is the one that stops
    /// working. Nothing is inserted anywhere -- this rewrites a row, it does not paste.
    ///
    /// The row's mode and language model follow the new refinement, because the metadata block
    /// describes the text on screen: a row that kept "Voice / no language model" beside a refined
    /// paragraph would be lying about where that paragraph came from. What it costs is that the
    /// mode the dictation originally ran under is forgotten, which is the right way round -- the
    /// text is the row, and the mode is a fact about the text.
    func processAgain(with mode: Mode) async {
        guard let store, var record = selected, let raw = record.rawTranscript,
              HistoryDetail.canProcessAgain(record)
        else { return }

        isProcessing = true
        defer { isProcessing = false }

        let outcome = await reRefine(raw, mode)
        // The refinement did not happen and the raw transcript came back in its place. Rewriting
        // the row now would record a refinement by a model that never answered.
        if let notice = outcome.notice {
            problem = notice.message
            return
        }

        record.refinedText = outcome.text
        record.modeKey = mode.key
        record.modeName = mode.name
        record.llmModel = mode.llm.model
        record.refinementSeconds = outcome.seconds
        do {
            try store.update(record)
            reload()
            lens = .refined
        } catch {
            log.error("re-refined row not written: \(error.localizedDescription, privacy: .public)")
            problem = "The re-refined text could not be saved (\(error.localizedDescription))."
        }
    }

    func dismissProblem() {
        problem = nil
    }
}
