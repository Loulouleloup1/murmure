import Foundation
import MurmureCore

/// What the Modes pane is looking at: the modes on disk, the one being edited, and the files that
/// could not be read.
///
/// Thin, like `VocabularyPaneModel` and for the same reason -- the app target has no test bundle,
/// so anything decided here is verified by reading. Everything that is a decision lives in
/// `MurmureCore` and is tested there: which field an error is shown under (`ModeField`), what
/// saving does to the folder (`ModeStore.save(_ draft:)`), how many badges a row carries
/// (`Mode.stages`), what key a new mode gets (`Mode.availableKey`). What is left below is the
/// store call, the published state and one call into `FinderReveal`.
@MainActor
final class ModesPaneModel: ObservableObject {
    /// Every usable mode, in `ModeStore`'s own order -- by file name, which is the order the
    /// folder lists them in and therefore the one Louis sees in the Finder.
    @Published private(set) var modes: [Mode] = []

    /// The mode files that could not be used, one line each. `ModeStore` reports them one by one
    /// for exactly that, and this pane is the surface D15 wanted for them: the menu can only say
    /// that something is wrong, the window is beside the list the broken file is missing from.
    @Published private(set) var problems: [String] = []

    /// The mode currently open in the editor, or nil when the list is collapsed. One at a time:
    /// two expanded rows would be two copies of a folder that is also being hand-edited.
    @Published var draft: ModeDraft?

    /// The advanced screen is pushed over the pane. A property of the *draft* being edited and not
    /// of the pane, which is why closing the editor closes it too.
    @Published private(set) var screen: ModeEditorScreen = .basic

    /// The preset picker is open.
    @Published var isPickingPreset = false

    /// A save that was refused, or a folder that would not open. Never swallowed (ruling L7):
    /// silently dropping it would leave the editor showing a mode that is not on disk.
    @Published private(set) var writeProblem: String?

    /// The keys currently on disk -- what a new mode's key has to avoid.
    private var takenKeys: [String] { modes.map(\.key) }

    /// The dialog for a draft about to be thrown away, or nil. Raised only when the loss would be
    /// implicit -- see ``requestingDiscardIfNeeded(_:)``.
    @Published private(set) var discardPrompt: ConfirmationPrompt?

    /// What the pane was asked to do, held until the draft in the way is resolved. `[weak self]`
    /// at every call site: a closure stored on the object it captures is a cycle, and one that is
    /// only broken by the user answering a dialog is a cycle that survives being ignored.
    private var deferredAction: (() -> Void)?

    /// `Application Support/Murmure` itself, injected rather than resolved here for §5.4's
    /// reason: the app names the real one once, and a test can point this at a temporary
    /// directory. The PURE `Storage.url()` — nothing about building a settings pane may create a
    /// folder, and neither of the two things below needs it to exist beforehand.
    private let supportFolder: URL
    /// Told after every write, so the menu's mode list and the mode a dictation resolves stop
    /// being the ones from before the edit. `DictationController.refreshModes()` is what it calls.
    ///
    /// `renamedKey` is non-nil when the write moved a mode's file. The editor is the only place
    /// that knows the old key became the new one, so it is the only place that can let the stored
    /// selection follow it (`ModePreference.selection(_:following:)`).
    private let didChangeModes: (_ renamedKey: (from: String, to: String)?) -> Void

    /// Lazy for the reason `VocabularyPaneModel`'s store is: the `report` closure captures `self`,
    /// which is not fully initialized until every stored property has a value.
    private lazy var store = ModeStore(directory: directory) { [weak self] problem in
        self?.problems.append(problem.description)
    }

    /// The folder the store reads and writes, and the folder the button at the bottom of the pane
    /// opens. **One expression, from `RevealTarget.modes`**, so the two cannot drift apart into a
    /// pane that edits one folder and reveals another — which is the shape of the defect that had
    /// "Reveal Modes Folder" doing two different things in one window.
    ///
    /// `Storage.url(subfolder: "modes")` resolves to the same URL, trailing slash included; it is
    /// not used here because `RevealTarget` is the one that is tested against `Storage` in the
    /// package, and having a second expression for one location is what the test is guarding
    /// against.
    private var directory: URL { RevealTarget.modes.url(inSupportFolder: supportFolder) }

    /// `supportFolder` is injected rather than resolved here, the same reason `ModeStore` itself
    /// takes a directory: the app hands down `Storage.url()`, and nothing that is not the app may
    /// reach the real folder.
    init(
        supportFolder: URL,
        didChangeModes: @escaping (_ renamedKey: (from: String, to: String)?) -> Void = { _ in }
    ) {
        self.supportFolder = supportFolder
        self.didChangeModes = didChangeModes
    }

    /// Re-reads the folder. Called every time the pane appears, which is the plan's own answer to
    /// the file being edited in two places: the window can be left open on another section for a
    /// day, and coming back to a list from yesterday is how a stale copy gets saved over a
    /// hand-edited prompt.
    ///
    /// Does not touch `draft`: reloading under an open editor would throw away what is being
    /// typed. The mode that is open is protected by its own modification date instead
    /// (`ModeStore.save(_ draft:)`), which is the check that can tell a stale copy from a current
    /// one -- a reload cannot.
    func reload() {
        problems = []
        modes = store.loadAll()
    }

    // MARK: - The editor

    func isEditing(_ mode: Mode) -> Bool {
        draft?.previousKey == mode.key
    }

    /// Opens a row's editor, or closes it if it was the one open.
    ///
    /// The modification date is read **here**, at the same moment as the mode, and not at save
    /// time: read at save time it would always match, and the guard would be a check of the file
    /// against itself.
    /// Which of the two it is is decided **before** the dialog, not after. Deciding afterwards
    /// reads the state the dialog has just cleared, so collapsing the row being edited would find
    /// no editor open and helpfully open it again.
    func toggleEditor(for mode: Mode) {
        guard !isEditing(mode) else {
            return requestingDiscardIfNeeded { [weak self] in self?.closeEditor() }
        }
        requestingDiscardIfNeeded { [weak self] in
            guard let self else { return }
            writeProblem = nil
            screen = .basic
            draft = ModeDraft(editing: mode, modifiedAt: store.modificationDate(forKey: mode.key))
        }
    }

    /// Runs `action`, unless a draft with unsaved changes is in the way -- in which case the
    /// action waits behind a dialog.
    ///
    /// **Implicit losses only.** Opening another row and pressing `+` are the two ways the app
    /// throws away what is in the editor without having been asked to, and losing a saved
    /// keystroke without a word is the same family of fault as the overwrite
    /// `ModeStore.save(_ draft:)` refuses -- the difference is only that here it is the app
    /// destroying rather than the disk. Cancel is deliberately NOT routed through this: it already
    /// means discard, and a dialog confirming a button whose whole meaning is "throw this away" is
    /// how someone learns to click through the next one.
    ///
    /// Refusing to collapse at all was the other option and was rejected: a click that does
    /// nothing is its own kind of lie, and it leaves the reader with no way out and nothing said.
    private func requestingDiscardIfNeeded(_ action: @escaping () -> Void) {
        guard let draft, draft.hasUnsavedChanges else { return action() }
        deferredAction = action
        discardPrompt = draft.discardConfirmation
    }

    func confirmDiscard() {
        discardPrompt = nil
        closeEditor()
        deferredAction?()
        deferredAction = nil
    }

    func cancelDiscard() {
        discardPrompt = nil
        deferredAction = nil
    }

    /// Closes the editor without asking. The primitive: `save()` and `confirmDiscard()` call it
    /// once there is nothing left to lose, and Cancel calls it because pressing Cancel is the
    /// answer to the question this would otherwise ask.
    func closeEditor() {
        draft = nil
        screen = .basic
        writeProblem = nil
    }

    func showAdvanced() {
        screen = .advanced
    }

    func showBasic() {
        screen = .basic
    }

    /// Starts a new mode from a preset. Not written yet: it appears as an expanded card at the
    /// end of the list, and it reaches the disk when Save is pressed. A mode created by the act of
    /// picking a preset would put a file called `new-mode.json` in the folder for every misclick.
    func create(from preset: ModePreset) {
        isPickingPreset = false
        requestingDiscardIfNeeded { [weak self] in
            guard let self else { return }
            writeProblem = nil
            screen = .basic
            draft = ModeDraft(creating: preset.mode(avoiding: takenKeys))
        }
    }

    var isCreating: Bool {
        draft != nil && draft?.previousKey == nil
    }

    /// Writes the draft. The three refusals -- an invalid field, a file edited underneath, a key
    /// another mode owns -- all arrive here as an error and are shown rather than logged.
    func save() {
        guard let draft else { return }
        do {
            try store.save(draft)
            let renamed = draft.previousKey.flatMap { previous in
                draft.movesItsFile ? (from: previous, to: draft.mode.key) : nil
            }
            closeEditor()
            reload()
            didChangeModes(renamed)
        } catch let error as ModeWriteProblem {
            writeProblem = error.description
        } catch let error as ModeValidationError {
            writeProblem = error.description
        } catch {
            writeProblem = "The mode could not be saved (\(error.localizedDescription))."
        }
    }

    /// The mode whose removal is waiting on the dialog, or nil. A removal is irreversible, so it
    /// always asks -- and the mode is held here rather than acted on, because the sentence the
    /// dialog shows is `Mode.removalConfirmation` and it is the mode that knows it.
    @Published var pendingRemoval: Mode?

    func askToRemove(_ mode: Mode) {
        pendingRemoval = mode
    }

    /// Removes the file behind the mode the dialog named.
    ///
    /// Goes through the **draft**, so the removal is refused on the same modification date
    /// `save()` is refused on. Guarding only the reversible path would be the wrong way round: a
    /// correction made by hand while the editor was open would survive Save and not survive
    /// Delete.
    func confirmRemoval() {
        guard let mode = pendingRemoval, let draft, draft.previousKey == mode.key else {
            return pendingRemoval = nil
        }
        pendingRemoval = nil
        do {
            try store.delete(draft)
            closeEditor()
            reload()
            didChangeModes(nil)
        } catch let error as ModeWriteProblem {
            writeProblem = error.description
        } catch {
            writeProblem = "\(mode.key).json could not be removed (\(error.localizedDescription))."
        }
    }

    func dismissWriteProblem() {
        writeProblem = nil
    }

    // MARK: - The folder

    /// Design notes §6 closes on exactly this. Modes live in `Application Support`, which is more
    /// correct than Superwhisper's `~/Documents` "but it does hide them" -- and these files are
    /// meant to be opened in a text editor. The button is what gives the folder back.
    ///
    /// The list of `*.json` files rather than `Murmure` highlighted among thirty other application
    /// folders -- still true, and now a property of `RevealTarget.modes.isDirectory` rather than of
    /// this method choosing `NSWorkspace.open` on its own. `FinderReveal` is the single
    /// implementation and carries the argument, including why the folder is no longer created here.
    func revealModesFolder() {
        writeProblem = FinderReveal.show(.modes, inSupportFolder: supportFolder)
    }
}
