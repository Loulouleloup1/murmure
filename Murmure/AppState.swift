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
    /// rewrites exactly these at every launch, so this is what the folder contains until
    /// `DictationController` reads it a few lines later. An empty menu would be a lie for that
    /// instant, and a worse one if the read ever failed.
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

    /// The clipboard was not handed back intact. Cleared when the next dictation starts.
    @Published var clipboardWarning: String?

    /// Why the last dictation failed, in the user's words. Cleared when the next one starts.
    @Published var lastFailureMessage: String?

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
    /// Surfacing this in the notch belongs to the UI lot; dropping it on the floor does not.
    func noteClipboard(_ outcome: PasteboardSnapshot.RestoreOutcome) {
        switch outcome {
        case .restored:
            clipboardWarning = nil
        case let .restoredPartially(lost, captured, lostTypes):
            // Task 6 fix round 2 folded TYPE-level loss into this same case, so that `.restored`
            // again means what its doc says. An item that survived amputated -- an eager `.string`
            // kept, its unfulfilled `.rtf` promise gone forever -- arrives here with `lost == 0`
            // and a non-empty `lostTypes`. The old shape reported that as `.restored` and this
            // switch cleared the warning at the exact moment content had been destroyed.
            // NOT a `switch` on `(lost, captured)`: `case (_, captured)` would BIND a new
            // `captured` and match everything, silently. An if-expression compares, a case pattern
            // binds.
            clipboardWarning = if lost == 0 {
                "Presse-papiers restauré en partie (formats perdus : \(lostTypes.count))"
            } else if lost == captured {
                "Presse-papiers perdu (\(lost) élément(s) non restaurables)"
            } else {
                "Presse-papiers partiellement restauré (\(lost)/\(captured) perdus)"
            }
        case .declinedPasteboardChanged:
            // Measured cross-process, after two wrong descriptions of this case: it means exactly
            // what it says. The third party's newer copy is in place and wins; our write was
            // refused (`setString` returned false, the counter was already theirs) and the
            // pre-dictation contents are deliberately not restored over it.
            clipboardWarning = "Presse-papiers modifié pendant la dictée — contenu antérieur non restauré"
        case .writeFailed:
            clipboardWarning = "Restauration du presse-papiers échouée"
        }
    }
}
