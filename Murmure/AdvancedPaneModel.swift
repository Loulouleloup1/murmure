import Foundation
import MurmureCore
import SwiftUI
import os

/// What the Advanced pane is looking at: the two insertion settings, the three folders, and the
/// two erasures.
///
/// Thin, like the other pane models. Everything decided lives in `MurmureCore` and is tested there:
/// what the two settings mean for one insertion (`InsertionPlan`, against a real pasteboard), where
/// each folder is and what to say when it is not there (`RevealTarget`), which erasure asks and
/// what it destroys (`HistoryClearing`), and that each one takes its own half and nothing else
/// (`RetentionPurge.clearNow`). What is left below is one call into `FinderReveal`, one sweep off
/// the main actor, and the published state.
@MainActor
final class AdvancedPaneModel: ObservableObject {
    /// The dialog for the erasure waiting on an answer, or nil.
    ///
    /// Held rather than acted on, the same shape `ModesPaneModel` uses for a removal: the sentence
    /// belongs to `HistoryClearing` and names a count, so the pane cannot compose it on the way
    /// past.
    @Published private(set) var confirmation: ConfirmationPrompt?

    /// What the last button did, in a sentence. Not a log line: the recordings button has no
    /// dialog, so the report afterwards is the only account Louis gets of what it took.
    @Published private(set) var outcome: String?

    /// A reveal that had nothing to open, or a sweep that failed. Never swallowed (ruling L7).
    @Published private(set) var problem: String?

    /// How many dictations still have text to lose. Drives both the number in the dialog and
    /// whether the button is offered at all -- `HistoryClearing.confirmation(dictationCount:)` says
    /// a caller with nothing to delete disables the button rather than asking about zero.
    @Published private(set) var dictationsWithText = 0

    /// True while a sweep is running, so a second press cannot start one over the top of the first
    /// -- two sweeps over one folder would have each deleting files the other had counted.
    @Published private(set) var isClearing = false

    /// The action the open dialog is about. Separate from `confirmation` because the dialog is a
    /// value the view draws and this is what the confirm button carries out.
    private var pendingAction: HistoryClearing?

    private let settings: AppSettings
    /// The archive, opened once by `DictationController` and read here (§5.4 rule 3): one
    /// connection, one place that knows the real path. Nil when it could not be opened, which
    /// disables both erasure buttons rather than offering an action against nothing.
    private let store: HistoryStore?
    private let recordings: URL
    /// `Application Support/Murmure` itself, for the three reveal targets. The PURE path: nothing
    /// about drawing this pane may create a folder.
    private let supportFolder: URL
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "advanced")

    /// Every path is injected rather than resolved here, for §5.4's reason: the app names the real
    /// ones once, and nothing else in the process is able to reach them by accident.
    init(settings: AppSettings, store: HistoryStore?, recordings: URL, supportFolder: URL) {
        self.settings = settings
        self.store = store
        self.recordings = recordings
        self.supportFolder = supportFolder
    }

    /// Re-reads the count behind the transcripts button. Called every time the pane appears: the
    /// archive gains a row on every dictation, and the retention sweep empties rows every six
    /// hours, so a count from when the window opened is a number in a warning that is already wrong.
    func refresh() {
        problem = nil
        outcome = nil
        guard let store else { return dictationsWithText = 0 }
        do {
            dictationsWithText = try store.countWithText()
        } catch {
            dictationsWithText = 0
            problem = "The archive could not be read (\(error.localizedDescription))."
        }
    }

    // MARK: - Insertion

    /// What happens to a finished transcript. `PasteBehaviour` has two cases and the picker draws
    /// both; the wording of each is here because it is the only place it is shown.
    var pasteBehaviour: Binding<PasteBehaviour> {
        Binding(
            get: { self.settings.pasteBehaviour },
            set: { behaviour in
                self.settings.pasteBehaviour = behaviour
                // `AppSettings` is a value type over `UserDefaults`, so there is nothing for
                // SwiftUI to observe unless the pane says so.
                self.objectWillChange.send()
            })
    }

    var restoreClipboardAfterPaste: Binding<Bool> {
        Binding(
            get: { self.settings.restoreClipboardAfterPaste },
            set: { isOn in
                self.settings.restoreClipboardAfterPaste = isOn
                self.objectWillChange.send()
            })
    }

    /// Whether the clipboard row is live.
    ///
    /// **Disabled under copy-only rather than quietly overridden.** `AppSettings.willRestoreClipboard`
    /// says why: there, the transcript on the clipboard IS the delivery, so handing the clipboard
    /// back would erase the only copy of the dictation. A switch left enabled would be a promise
    /// the app cannot keep.
    var canRestoreClipboard: Bool {
        settings.pasteBehaviour == .pasteIntoFrontmostApp
    }

    /// Why the row above is greyed out, or nil when it is not.
    var clipboardDisabledNote: String? {
        canRestoreClipboard
            ? nil
            : "With copy-only, the transcript on the clipboard is the delivery — restoring would "
                + "erase it."
    }

    func label(for behaviour: PasteBehaviour) -> String {
        switch behaviour {
        case .pasteIntoFrontmostApp: "Paste into the app in front"
        case .copyToClipboardOnly: "Copy to the clipboard only"
        }
    }

    func note(for behaviour: PasteBehaviour) -> String {
        switch behaviour {
        case .pasteIntoFrontmostApp:
            "Presses ⌘V into whatever is in front. Needs Accessibility permission."
        case .copyToClipboardOnly:
            "Leaves the transcript on the clipboard and presses nothing. Needs no permission at "
                + "all — the answer for apps where a synthetic ⌘V lands in the wrong field."
        }
    }

    // MARK: - Reveal

    /// Opens one of the three in the Finder, or says why it could not.
    ///
    /// **Nothing is created**, and a folder is opened where a file is selected: both are
    /// `FinderReveal`'s, which is the single implementation this and the Modes pane's own button
    /// now share. The rules it follows, and why the vocabulary case is the one that cannot be
    /// opened like the other two, are argued there.
    func reveal(_ target: RevealTarget) {
        outcome = nil
        // Assigned rather than cleared-then-set: `FinderReveal` returns nil when it revealed
        // something, so one write both clears the last complaint and records this one.
        problem = FinderReveal.show(target, inSupportFolder: supportFolder)
    }

    // MARK: - The two erasures

    /// Whether the button has anything to act on. The recordings one is always offered: what is in
    /// the folder is not something this pane counts, and its report afterwards says what it took.
    /// The transcripts one goes dead when there is no text left, so a second press cannot open a
    /// dialog about zero dictations.
    func isEnabled(_ action: HistoryClearing) -> Bool {
        guard store != nil, !isClearing else { return false }
        switch action {
        case .recordings: return true
        case .transcripts: return dictationsWithText > 0
        }
    }

    /// A button was pressed. Opens the dialog, or acts -- and **which of the two is
    /// `HistoryClearing.requiresConfirmation`'s answer, never this method's**. The same property
    /// puts the ellipsis on the button title, so a dialog that appeared here without one would be
    /// a button whose label had stopped describing it.
    func press(_ action: HistoryClearing) {
        problem = nil
        outcome = nil
        guard let prompt = action.confirmation(dictationCount: dictationsWithText) else {
            return perform(action)
        }
        pendingAction = action
        confirmation = prompt
    }

    /// The dialog's destructive button.
    func confirmPending() {
        guard let action = pendingAction else { return }
        dismissConfirmation()
        perform(action)
    }

    func dismissConfirmation() {
        confirmation = nil
        pendingAction = nil
    }

    /// One sweep, off the main actor.
    ///
    /// `Task.detached` for `DictationController.purge`'s reason: emptying Louis's folder is up to
    /// 148 `stat`s and 122 `unlink`s plus two SQLite writes, and none of it belongs on the actor
    /// that is drawing the window.
    ///
    /// `Date()` is read here, at the one place allowed to know what time it is, and handed in --
    /// `RetentionPurge.clearNow` takes `now:` so every cutoff it computes can be asked about in a
    /// test.
    private func perform(_ action: HistoryClearing) {
        guard let store, !isClearing else { return }
        isClearing = true
        let recordings = recordings
        let now = Date()
        Task.detached(priority: .utility) { [log] in
            let result: Result<RetentionPurgeReport, Error>
            do {
                result = .success(try RetentionPurge.clearNow(
                    action, store: store, recordings: recordings, now: now))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finish(action, result: result, log: log)
            }
        }
    }

    private func finish(
        _ action: HistoryClearing, result: Result<RetentionPurgeReport, Error>, log: Logger
    ) {
        isClearing = false
        switch result {
        case .success(let report):
            outcome = Self.sentence(for: action, report: report)
            // Every pass, including the ones that did nothing -- the same line the automatic sweep
            // logs, and for the same reason: a mechanism whose job is to delete things quietly
            // needs one line saying it ran.
            log.notice("""
                manual clear -- \(report.audioFilesDeleted, privacy: .public) audio files \
                deleted, \(report.audioDeletionFailures.count, privacy: .public) failed, \
                \(report.textRowsCleared, privacy: .public) rows lost their text
                """)
            if !report.audioDeletionFailures.isEmpty {
                problem = "\(report.audioDeletionFailures.count) recording(s) could not be deleted."
            }
            if let unreadable = report.recordingsUnreadable {
                problem = "The recordings folder could not be listed (\(unreadable))."
            }
        case .failure(let error):
            // The archive refused, so the sweep deliberately did not run: the pin set comes from
            // the database, and a purge that cannot read it does not know what it may delete.
            // Nothing was deleted, which is what the sentence has to say.
            problem = "Nothing was deleted — the archive could not be read "
                + "(\(error.localizedDescription))."
        }
        refreshCountOnly()
    }

    /// The count alone, after a sweep. Not `refresh()`, which clears `outcome` -- and the outcome
    /// is the only thing the recordings button ever says about itself.
    private func refreshCountOnly() {
        guard let store else { return }
        dictationsWithText = (try? store.countWithText()) ?? dictationsWithText
    }

    /// What the pane says afterwards. **Says the number, including when it is zero**: "there was
    /// nothing to delete" and "122 recordings deleted" are the two things Louis could want to know
    /// after pressing a button that opened no dialog, and a silent success is indistinguishable
    /// from a button that did not work.
    private static func sentence(
        for action: HistoryClearing, report: RetentionPurgeReport
    ) -> String {
        switch action {
        case .recordings:
            switch report.audioFilesDeleted {
            case 0: "There were no recordings to delete."
            case 1: "1 recording deleted."
            case let count: "\(count) recordings deleted."
            }
        case .transcripts:
            switch report.textRowsCleared {
            case 0: "There was no text left to delete."
            case 1: "The text of 1 dictation was deleted. The row is still there."
            case let count: "The text of \(count) dictations was deleted. The rows are still there."
            }
        }
    }
}
