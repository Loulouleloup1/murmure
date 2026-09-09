import MurmureCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle, recording, transcribing, refining, inserting, failed
    }

    @Published var status: Status = .idle

    /// Every mode on disk, for the menu to list. Replaced -- never merged -- so a mode file
    /// deleted by hand stops being offered.
    ///
    /// Seeded with the built-ins rather than left empty: `ModeStore.createBuiltInsIfMissing()`
    /// repairs Voice at every launch and seeds Prompt once, so this is what the folder contains
    /// until `DictationController` reads it a few lines later. An empty menu would be a lie for
    /// that instant, and a worse one if the read ever failed.
    @Published var availableModes: [Mode] = Mode.builtIns

    /// The mode chosen by hand in the menu, or nil for "automatic" -- rule 1 of spec §5, which
    /// `ModeSelection.resolve` lets nothing overrule. Persisted on every change, including back
    /// to nil: see `ModePreference`.
    @Published var manualModeKey: String? {
        didSet { preference.selectedKey = manualModeKey }
    }

    /// The mode the last dictation actually resolved, and therefore the one running right now:
    /// with "automatic" ticked, the checkmark says nothing about which mode won. This is what
    /// answers "is what I am saying going to the LLM or not" while the recording is live.
    @Published var activeMode: Mode = .voice

    /// Set once, at launch, when Carbon refuses ⌥Space. There is no retry: the combination is
    /// taken for as long as the other application holds it, and a dead key with no explanation is
    /// exactly what task 4 refused to ship.
    @Published var hotkeyUnavailable = false

    /// `AXIsProcessTrusted()` answered false the last time it was asked: at launch, and at the
    /// start of every dictation since.
    ///
    /// **Re-asked per dictation because the launch answer goes stale, and silently.** The
    /// permission is stored against the app's code signature, so a rebuild revokes it without any
    /// dialog, and the only symptom is a ⌘V that does nothing -- which is exactly how Louis lost
    /// it. A flag set once at launch would go on reporting the state of the world at launch for as
    /// long as the app stayed running.
    ///
    /// Not cleared by the next `.recording` the way `clipboardWarning` and its neighbours are:
    /// it is REPLACED there by a fresh reading, which is the same shape `modeProblems` has and for
    /// the same reason -- the problem outlives the dictation that revealed it.
    @Published var accessibilityDenied = false

    /// The one problem with Murmure itself worth a surface of its own, or nil.
    ///
    /// Not `@Published`, and it does not need to be: it is derived from two properties that both
    /// are, so a SwiftUI view reading it is invalidated by whichever of them changed. The ranking
    /// is `AppAlert.mostSevere(among:)`, in the package, where it is tested.
    var alert: AppAlert? {
        AppAlert.mostSevere(among: [
            hotkeyUnavailable ? AppAlert.hotkeyUnavailable : nil,
            accessibilityDenied ? AppAlert.accessibilityDenied : nil,
        ].compactMap(\.self))
    }

    /// The clipboard was not handed back intact. Cleared when the next dictation starts.
    @Published var clipboardWarning: String?

    /// Why the last dictation failed, in the user's words. Cleared when the next one starts.
    @Published var lastFailureMessage: String?

    /// The text a failed insertion could not deliver, kept so it can be offered rather than lost
    /// (spec §9). Nil for every failure that happened before there was any text -- a refused
    /// microphone, a transcription that threw -- and cleared when the next dictation starts,
    /// alongside the message it belongs to.
    ///
    /// `DictationSession.lastTranscript` is what `repasteLast()` actually pastes; this is the
    /// same text held where a surface can SHOW it. Lot 3 T6 is what puts it on screen.
    @Published var recoveredText: String?

    /// The mode files that could not be used, and the selections that could not be honoured --
    /// one line per file to fix, because `ModeStore` reports them one by one for exactly that.
    ///
    /// Not cleared when a dictation starts, unlike the two above: a mode file stays broken until
    /// Louis edits it, and a warning that disappears on the next press is a warning he never
    /// finishes reading. Replaced wholesale at each resolution instead, so a fixed file stops
    /// being listed.
    @Published var modeProblems: [String] = []

    /// What happened to the refinement of the last dictation, when the text he got is not the
    /// text he expected. The dictation still produced text -- that is what makes this a notice
    /// and not a failure. Cleared when the next dictation starts.
    @Published var refinementNotice: String?

    /// Bumped once per row actually written to `murmure.sqlite`, by `DictationArchive`.
    ///
    /// The History pane's cue to re-read, and it exists because the obvious cue does not work:
    /// the archive is written **after** the session has already gone back to `.idle`
    /// (`DictationSession.finishRecording`, where `complete()` transitions and the `archive` call
    /// follows it), so a pane reloading on `.idle` would race the insert and show a list missing
    /// the dictation that just ended. This ticks when there is genuinely something new to read.
    @Published private(set) var historyRevision = 0

    func noteHistoryRow() {
        historyRevision &+= 1
    }

    private let preference: ModePreference

    /// `defaults` is a parameter with the real domain as its default so the app stays a
    /// `AppState()`, and so anything that ever tests this class cannot write into the preferences
    /// of the application Louis is using.
    init(defaults: UserDefaults = .standard) {
        preference = ModePreference(defaults: defaults)
        // `didSet` does not fire from an initialiser, which is what is wanted here: this reads the
        // stored choice, it does not make one.
        manualModeKey = preference.selectedKey
    }

    /// The checkmark of one item in the menu's mode list; `key` is nil for the "automatic" item.
    ///
    /// A `Toggle` is how a SwiftUI menu draws a checkmark, but these behave as radio buttons and
    /// not as switches: ticking one unticks the rest, and unticking the current one does nothing.
    /// "No mode at all" is not a state `ModeSelection` has -- going back to letting the rules
    /// decide is the "automatic" item, which is itself one of the choices.
    func modeSelection(_ key: String?) -> Binding<Bool> {
        Binding(
            get: { self.manualModeKey == key },
            set: { isOn in if isOn { self.manualModeKey = key } })
    }

    /// A mode's key was renamed in the Modes pane; the selection follows it if it was the one
    /// named.
    ///
    /// The key is the file name, so renaming it leaves a stored selection pointing at nothing.
    /// `ModeSelection.resolve` already survives that -- it falls through to the remaining rules
    /// and reports `unknownManualSelection` -- so this is not a repair. It is what stops the mode
    /// Louis had ticked from silently becoming another one the moment he renames a file, with the
    /// explanation only in a log.
    ///
    /// The rule itself is `ModePreference.selection(_:following:)`, in the package, where it is
    /// tested; the assignment below is what persists it, through `manualModeKey`'s own `didSet`.
    func followModeRename(from oldKey: String, to newKey: String) {
        manualModeKey = ModePreference.selection(
            manualModeKey, following: (from: oldKey, to: newKey))
    }

    var menuBarSymbol: String {
        switch status {
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "hourglass"
        // Distinct from the hourglass on purpose: a refinement runs 19 s at the p-high of the
        // measured calls and 57.5 s on the worst real one, and for all that time the only
        // question is whether the model is working or the app is stuck.
        case .refining: "wand.and.sparkles"
        case .inserting: "arrow.down.doc"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// The refinement did not produce what the mode asked for, and the text was inserted anyway.
    ///
    /// `RefinementNotice.message` is used as it stands rather than re-said in French: it is the
    /// sentence lot 2 wrote for a reader, it names the model and carries `OllamaFailure.remedy`,
    /// and paraphrasing it here would mean maintaining the six remedies in two places. The menu
    /// already shows `DictationSession`'s English failure messages the same way.
    func noteRefinement(_ notice: RefinementNotice) {
        refinementNotice = notice.message
    }

    /// Task 6's `RestoreOutcome` reaches a human here. A dictation that pasted correctly can still
    /// have destroyed what Louis had copied, and the menu is lot 1's only place to say so.
    ///
    /// The sentences themselves moved to `ClipboardWarning`, in the package: the branch that tells
    /// a type-level loss from an item-level one was wrong once, and a rule with that history has
    /// no business living where there is no test bundle. What is left here is the assignment,
    /// including the nil that CLEARS the warning when the clipboard came back intact.
    func noteClipboard(_ outcome: PasteboardSnapshot.RestoreOutcome) {
        clipboardWarning = ClipboardWarning.message(for: outcome)
    }
}
