import Foundation
import MurmureCore
import WhisperKit

/// What the Modes pane is looking at: the modes on disk, the one being edited, and the files that
/// could not be read.
///
/// Thin, like `VocabularyPaneModel` and for the same reason -- the app target has no test bundle,
/// so anything decided here is verified by reading. Everything that is a decision lives in
/// `MurmureCore` and is tested there: which field an error is shown under (`ModeField`), what
/// saving does to the folder (`ModeStore.save(_ draft:)`), how many badges a row carries
/// (`Mode.stages`), what key a new mode gets (`Mode.availableKey`). What is left below is the
/// store call, the published state, the two picker sources and one call into `FinderReveal`.
@MainActor
final class ModesPaneModel: ObservableObject {
    /// Every usable mode, in `ModeStore`'s own order -- by file name, which is the order the
    /// folder lists them in and therefore the one Louis sees in the Finder.
    @Published private(set) var modes: [Mode] = []

    /// Every speech model actually installed under the models store -- the Speech model picker's
    /// options (`ModesPaneView.speechModelPicker`). Re-read on every `reload()`, disk-only: this
    /// is a directory walk, never a download.
    @Published private(set) var installedSpeechModels: [SpeechModelReference] = []

    /// Ollama's own listing, for the Refiner model picker -- refreshed on every `reload()`.
    ///
    /// **Fetched on appear, and that is a deliberate relaxation, not an oversight -- but only when
    /// the endpoint actually is `localhost` (`OllamaEndpoint.isLoopback`).** `/api/tags` reads
    /// Ollama's own manifest directory and loads nothing into memory, which is why a loopback read
    /// is exempt from the "nothing on `onAppear`" rule elsewhere in this app; a mode is free to
    /// name a remote server instead (`Mode.validationError` only requires an http(s) URL that is
    /// its own root), and reaching THAT automatically on every appearance is exactly the silent
    /// network access the rule protects against. `refreshOllamaListing` is where that gate is
    /// applied. `ModelsPaneModel.reload()` documents the identical relaxation, and the identical
    /// gate, for the same reason.
    @Published private(set) var ollamaModels: [OllamaProbe.Listed] = []
    /// Set instead of `ollamaModels` when the listing could not be read at all -- Ollama's own
    /// remedy wording (`OllamaFailure.remedy`), the same sentence a dictation failure would show,
    /// so there are not two vocabularies for one server being unreachable.
    @Published private(set) var ollamaUnreachableNote: String?

    /// The Language picker's own options: every distinct language code WhisperKit's decoder
    /// accepts, one row each.
    ///
    /// Read from the engine's own table (`Constants.languages`, a name -> ISO-639-1 code
    /// dictionary) rather than typed out a second time in Murmure -- a hand-kept list here could
    /// drift from what `WhisperKitEngine.transcribe` can actually be told to decode, silently
    /// offering a code the engine does not recognise. `MurmureCore` cannot hold this itself: the
    /// package imports neither AppKit nor WhisperKit (`Mode.swift`'s own doc comment), so the one
    /// place that already links WhisperKit -- the app target -- is where the picker's source of
    /// truth has to live. A `static let` and not a read on `reload()`: it is a compiled-in
    /// dictionary, not a disk or network read, so there is nothing to refresh.
    ///
    /// **Not `WhisperKit.Constants`.** WhisperKit the package also names a *class* `WhisperKit`
    /// (the transcription engine `WhisperKitEngine` wraps), and that class -- not the module --
    /// is what a member-access qualifier resolves to first; the module's top-level `Constants`
    /// enum has to be named unqualified, already in scope from `import WhisperKit`.
    ///
    /// **`LanguageOptions.dedupe`, not a raw map.** The table names 112 languages across only 100
    /// codes -- `"chinese"`/`"mandarin"` both say `zh`, eleven such codes -- and a `Picker` tagged
    /// by code cannot hold two rows sharing one tag: `ForEach`'s behaviour over a duplicate id is
    /// undefined, and before this dedupe existed the picker drew twelve redundant rows for it
    /// (review, lot 3a, item 3). `LanguageOptions` is tested in `MurmureCore` against a literal
    /// copy of this exact table.
    static let languageOptions: [LanguageOption] = LanguageOptions.dedupe(Constants.languages)

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
    /// Where the speech-model store lives -- the exact URL `ModelsPaneModel` reads
    /// (`Storage.url(subfolder: "models")`), injected rather than derived a second time here so
    /// the two panes cannot end up describing different folders. PURE, like `supportFolder`:
    /// the picker only ever walks this, never creates it.
    private let modelsStore: URL
    /// Told after every write, so the menu's mode list and the mode a dictation resolves stop
    /// being the ones from before the edit. `DictationController.refreshModes()` is what it calls.
    ///
    /// `renamedKey` is non-nil when the write moved a mode's file. The editor is the only place
    /// that knows the old key became the new one, so it is the only place that can let the stored
    /// selection follow it (`ModePreference.selection(_:following:)`).
    private let didChangeModes: (_ renamedKey: (from: String, to: String)?) -> Void

    /// A session of its own, short-timed, on the loopback address -- the same shape and the same
    /// reason `ModelsPaneModel`'s own session gives: `OllamaChat.timeout`'s 120 s is sized for a
    /// model generating text, not for finding out that nothing is listening.
    private let ollamaSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

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
        modelsStore: URL,
        didChangeModes: @escaping (_ renamedKey: (from: String, to: String)?) -> Void = { _ in }
    ) {
        self.supportFolder = supportFolder
        self.modelsStore = modelsStore
        self.didChangeModes = didChangeModes
    }

    /// Re-reads the folder, the speech-model store and Ollama's own listing. Called every time
    /// the pane appears, which is the plan's own answer to the file being edited in two places:
    /// the window can be left open on another section for a day, and coming back to a list from
    /// yesterday is how a stale copy gets saved over a hand-edited prompt.
    ///
    /// Does not touch `draft`: reloading under an open editor would throw away what is being
    /// typed. The mode that is open is protected by its own modification date instead
    /// (`ModeStore.save(_ draft:)`), which is the check that can tell a stale copy from a current
    /// one -- a reload cannot. The picker options DO refresh under an open editor, deliberately:
    /// a model installed or pulled from the Models pane one click away should show up here without
    /// closing and reopening the row.
    func reload() async {
        problems = []
        modes = store.loadAll()
        installedSpeechModels = ModelInventory.installedSpeechModels(in: modelsStore)
        await refreshOllamaListing()
    }

    /// Asks Ollama's `/api/tags` on the first refining mode's own endpoint -- Ollama has always
    /// been the one local server every mode on this machine points at, and a second, differently
    /// configured endpoint is the same accepted limit `ModelsPaneModel.reference(forRowIdentifier:)`
    /// already documents elsewhere for pulling. A machine with no refining mode at all has no
    /// endpoint to ask, and the picker falls back to just the mode's own stored value
    /// (`ModesPaneView.refinerModelPicker`'s "(not installed)" item).
    ///
    /// **Only when that endpoint is loopback.** A mode naming a remote server still passes
    /// `Mode.validationError`, and this function runs from `reload()`, which runs on every
    /// appearance -- so a non-loopback endpoint is left unread here, exactly like "no endpoint at
    /// all", with a note saying why rather than the `OllamaFailure` vocabulary a real unreachable
    /// server would get. Reaching a remote endpoint stays possible, just never automatic: it is
    /// what `ModelsPaneModel.checkOllama()`'s press does, on the same mode's own endpoint.
    private func refreshOllamaListing() async {
        guard let endpoint = modes.first(where: \.llm.enabled)?.llm.endpoint,
              let base = URL(string: endpoint)
        else {
            ollamaModels = []
            ollamaUnreachableNote = nil
            return
        }
        guard OllamaEndpoint.isLoopback(base) else {
            ollamaModels = []
            ollamaUnreachableNote = "\(endpoint) is not this machine -- Murmure does not read it automatically."
            return
        }
        let url = OllamaProbe.endpoint(base: base)
        do {
            let (data, response) = try await ollamaSession.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                ollamaModels = []
                ollamaUnreachableNote = OllamaFailure.malformedResponse(detail: "not an HTTP response").remedy
                return
            }
            switch OllamaProbe.list(status: http.statusCode, body: data) {
            case .listed(let listed):
                ollamaModels = listed
                ollamaUnreachableNote = nil
            case .failed(let failure):
                ollamaModels = []
                ollamaUnreachableNote = failure.remedy
            }
        } catch {
            ollamaModels = []
            ollamaUnreachableNote = OllamaChat.failure(transport: error, elapsed: 0).remedy
        }
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
            Task { await reload() }
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
            Task { await reload() }
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
