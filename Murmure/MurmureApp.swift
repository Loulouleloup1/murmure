import MurmureCore
import SwiftUI
import os

/// Murmure is `LSUIElement: true`, so a normal launch from the Finder has no attached console
/// and `print` goes nowhere anybody will ever read. Anything permanent logs here instead, where
/// `log stream --predicate 'subsystem == "com.louiscourcier.Murmure"'` and Console.app can see it.
private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "app")

/// The process's entry point, which is the app's only when nobody asked for anything else.
///
/// `@main` sits here rather than on `MurmureApp` so that ONE argument can be answered before
/// SwiftUI exists: `--prepare-model`, which `scripts/bootstrap.sh` uses to pay the model's
/// first-load cost at the end of an install instead of inside somebody's first dictation. The
/// measurements, and why the warm-up is a flag on this binary rather than a helper of its own,
/// are in `ModelWarmup`.
///
/// **The check is the first statement of the process, and that is a guarantee rather than a
/// preference.** Everything `MurmureApp.init` does -- registering ⌥Space, putting an item in the
/// menu bar, and above all PROMPTING for Accessibility -- must not happen in a child process of a
/// shell script. Reached this way it cannot have, because none of it has been reached yet.
///
/// `MurmureApp.main()` below is the one `App` provides; the struct declares no `main` of its own,
/// which is what makes it reachable from here at all.
@main
enum Launch {
    static func main() {
        if CommandLine.arguments.contains(ModelWarmup.flag) {
            ModelWarmup.run()
        }
        MurmureApp.main()
    }
}

struct MurmureApp: App {
    /// Answers the one thing SwiftUI's `Window` scene cannot: a Dock-tile click. See
    /// `AppDelegate` for why that needs AppKit rather than an environment action.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var appState: AppState

    /// The one dictation controller, built here so the ⌥Space registration happens once at launch
    /// rather than the first time a menu is drawn. `App` is `@MainActor`, so this init is too.
    private let controller: DictationController

    /// The application window's state: whether it is up, where it sits, which section it is on.
    /// A `StateObject` rather than a `let` because the window's content observes it — an `App`
    /// struct is re-created, and a plain stored object would be a new controller each time.
    @StateObject private var windowController: WindowController

    /// Home's state: the computed statistics and the chosen period. A `StateObject` for the same
    /// reason the others are — an `App` struct is re-created, and a plain stored object would
    /// throw away the chosen period every time SwiftUI rebuilt the scene.
    @StateObject private var homeModel: HomePaneModel

    /// History's state: the query, the rows, the selection. A `StateObject` for the same reason
    /// the window controller is one — an `App` struct is re-created, and a plain stored object
    /// would throw away Louis's search every time SwiftUI rebuilt the scene.
    @StateObject private var historyModel: HistoryPaneModel

    /// The transcripts library's state: the tiles the folder yields, and the transcript open in
    /// reading mode. A `StateObject` for the same reason History is — an `App` struct is
    /// re-created, and a plain stored object would close the transcript Louis is reading every
    /// time SwiftUI rebuilt the scene.
    ///
    /// Built here rather than in the view because it resolves the one folder the transcripts live
    /// in (`TranscriptLibrary.defaultBase`, R3): the grid, the reveal button and — later — the
    /// queue that writes there must all point at the same directory, and a second resolution in a
    /// view is how two panes end up disagreeing about where a file is.
    @StateObject private var transcriptsModel: TranscriptsPaneModel

    /// The modes editor's state. A `StateObject` for the reason the others are, and built here
    /// rather than in the view for one it does not share: its `didChangeModes` has to reach both
    /// `DictationController` and `AppState`, and a `@StateObject` initialiser inside
    /// `MainWindowView` cannot read `self` to get at either.
    @StateObject private var modesModel: ModesPaneModel

    /// The models table's state. Built here because the language half of the table is derived from
    /// the modes `AppState` holds, and that list changes while the app runs.
    @StateObject private var modelsModel: ModelsPaneModel

    /// General's state. A `StateObject` for the reason the others are: an `App` struct is
    /// re-created, and a plain stored object would be a new one every time SwiftUI rebuilt the
    /// scene — which for this one would mean re-reading `SMAppService` on every redraw.
    ///
    /// Built here rather than in the view because it shares the settings object with the dictation
    /// pipeline: the two sound switches and the paste behaviour have to be the ones a dictation
    /// reads, not a second reader of the same keys.
    @StateObject private var generalModel: GeneralPaneModel

    /// Advanced's state. Built here for History's reason as well: its two erasure buttons act on
    /// the archive the controller opened, and §5.4 rule 3 allows exactly one connection to it.
    @StateObject private var advancedModel: AdvancedPaneModel

    init() {
        // Named once, here, and handed to both. `AppState` takes it for the reason its own init
        // gives -- a test must never write into the preferences of the application Louis is using
        // -- and `WindowController` stores the window's frame and section in the same domain, so
        // the two cannot end up in different ones. This is the single line where the real domain
        // is chosen.
        let defaults = UserDefaults.standard

        // Spec §9, BOTH halves, and the second one is lot 3 T6's.
        //
        // First: Accessibility is detected at launch rather than at the first failed paste, and
        // the answer is consumed rather than logged -- a denied permission means every future
        // insertion does nothing at all, silently. This is the one call that PROMPTS, which is why
        // it is here and once: `DictationController` re-reads the answer with a bare
        // `AXIsProcessTrusted()` at the start of every dictation, because a rebuild changes the
        // app's code signature and revokes the grant with no dialog at all.
        //
        // Second, which used to be an explicitly untickable box: the denial now reaches a surface.
        // `AppState.alert` turns it into an `AppAlert`, the notch or the strip flashes it, and
        // `ProblemPanelController` holds it with the System Settings deep link. The menu below
        // carries the same link, because a click on a floating panel is the one part of this that
        // no test can settle.
        //
        // Set BEFORE the controller is built: its init reads `appState.alert` on its last lines to
        // put whatever is already wrong on screen.
        let state = AppState(defaults: defaults)
        state.accessibilityDenied = !PasteInserter.requestAccessibilityIfNeeded()
        if state.accessibilityDenied {
            logger.error("Accessibility permission not granted -- text insertion will do nothing")
        }
        // Built before the `StateObject` wrapper so the controller and the view observe the same
        // instance: `_appState`'s wrapped value must be handed in, not read back out of the
        // wrapper here (reading a `@StateObject` from `init` is unsupported).
        _appState = StateObject(wrappedValue: state)
        _windowController = StateObject(wrappedValue: WindowController(defaults: defaults))
        // The fourth thing built on the one domain chosen above. `AppSettings` is a value type
        // over that `UserDefaults`, so handing the same one to the controller and to the two panes
        // is handing them one store rather than three readers of the same keys.
        let settings = AppSettings(defaults: defaults)
        let controller = DictationController(appState: state, settings: settings)
        self.controller = controller
        // The archive is opened once, by the controller, and READ here (§5.4 rule 3): one
        // connection, one place that knows the real path. A second `HistoryStore` on the same
        // file would be a second migration runner against Louis's own archive.
        _homeModel = StateObject(
            wrappedValue: HomePaneModel(store: controller.history, settings: settings))
        _historyModel = StateObject(
            wrappedValue: HistoryPaneModel(
                store: controller.history,
                archiveFailure: controller.historyFailure,
                recordings: controller.recordingsDirectory,
                reRefine: { transcript, mode in
                    await controller.reRefine(transcript, with: mode)
                }))
        // The default library, which is `Storage.url(subfolder: "Transcripts")` -- the PURE path,
        // like the Advanced pane's support folder below: opening the window must not create a
        // folder in Application Support, and the reveal button reports an absent folder rather
        // than making one. The transcripts lot's queue is what will write there (lot 8), and it
        // creates the root on its first write.
        //
        // Nothing is handed in beyond the library: this pane reads the folder and nothing else --
        // no store, no settings, no controller. That is what makes it the one section whose state
        // could have been built in the view, and it is built here anyway so that the folder is
        // resolved once for the whole app.
        // The pane is built WITH the dictation's engine (lot 11-S): the app constructs exactly one
        // `WhisperKitEngine`, in `DictationController`, and the video path reuses it instead of
        // paying a second 1.6 GB load. `library` keeps its default, as before.
        _transcriptsModel = StateObject(
            wrappedValue: TranscriptsPaneModel(engine: controller.transcriptionEngine))
        // `Storage.url()` and not `directory()`: the PURE path, for the reason the Advanced pane
        // below is given the same one. `ModeStore.save` creates `modes/` before it writes into it,
        // and the controller above has already created it on every launch that can reach
        // Application Support — so nothing about building this pane needs to.
        //
        // **`didChangeModes` is what makes the editor's Save reach the rest of the app**, and a
        // model built with the no-op default would look identical, compile identically and leave
        // the menu offering the list from before the edit.
        // `settings` plus `controller.releaseToggleHotkey`/`.restoreToggleHotkey` -- the exact
        // same closures `generalModel` below is handed, for the identical reason: recording a
        // mode's own shortcut needs every live binding released first, the same as recording the
        // toggle, and only `MurmureApp.init` can close over both this pane and the controller.
        _modesModel = StateObject(
            wrappedValue: ModesPaneModel(
                supportFolder: Storage.url(), modelsStore: Storage.url(subfolder: "models"),
                settings: settings, releaseToggleHotkey: controller.releaseToggleHotkey,
                restoreToggleHotkey: controller.restoreToggleHotkey
            ) { renamed in
                // The rename first, so the stored selection has already followed the key by the
                // time the list it is checked against is replaced. `ModePreference.selection` is
                // the rule; this is only the moment it is applied, and it is applied HERE because
                // the editor is the only thing in the process that knows the old key became the
                // new one.
                if let renamed {
                    state.followModeRename(from: renamed.from, to: renamed.to)
                }
                // Every write, rename or not: a mode created, deleted or merely renamed in the
                // window has to reach the menu and the next dictation without a restart.
                controller.refreshModes()
            })
        // The models folder, PURE: this pane walks it to report what is installed, and a settings
        // pane that created `models/` would be answering a question nobody asked. `WhisperKitEngine`
        // is what creates it, because it is what downloads into it.
        //
        // The language rows are a closure over `AppState`, not a snapshot: `refreshModes()` above
        // and the menu both write that list, and a table built from a copy of it would stop
        // agreeing with the modes the moment one was edited.
        _modelsModel = StateObject(
            wrappedValue: ModelsPaneModel(
                store: Storage.url(subfolder: "models"),
                speech: [ModelsPaneModel.dictationModel],
                language: { ModelInventory.languageModels(in: state.availableModes) },
                speechModels: {
                    state.availableModes.map {
                        SpeechModelResolution.reference(
                            storedAs: $0.stt.model, engineDefault: .shippedDefault)
                    }
                },
                modes: { state.availableModes }))
        // `controller.rebindToggleHotkey` rather than a copy of the logic: the pane decides
        // whether a captured press is legal (`HotkeyRecording`), the controller decides whether
        // Carbon will actually take it and rolls back a refusal -- and it can only do that from
        // where `HotkeyManager` and `settings` already both live.
        _generalModel = StateObject(
            wrappedValue: GeneralPaneModel(
                settings: settings, rebindToggleHotkey: controller.rebindToggleHotkey,
                releaseToggleHotkey: controller.releaseToggleHotkey,
                restoreToggleHotkey: controller.restoreToggleHotkey))
        // The same store the controller opened and the same recordings folder it resolved — read
        // here rather than resolved again, so the pane's Delete All Recordings and the retention
        // sweep cannot end up pointing at two different directories.
        //
        // `Storage.url()` is the PURE one: nothing about building a settings pane may create
        // `Application Support/Murmure`, and the three reveal buttons report an absent folder
        // rather than making one.
        _advancedModel = StateObject(
            wrappedValue: AdvancedPaneModel(
                settings: settings,
                store: controller.history,
                recordings: controller.recordingsDirectory,
                supportFolder: Storage.url()))
    }

    var body: some Scene {
        // Handed over here rather than in `init`: `appDelegate`, like `_appState` and every other
        // `@StateObject` above, is a SwiftUI dynamic property, and reading one before SwiftUI has
        // installed it is unsupported (see the note on `_appState` in `init`) -- Apple's own docs
        // stop short of saying exactly when that installation happens relative to a plain `init()`
        // call, so `init` is not where this can be guaranteed safe. `body` is: it is the one place
        // the framework is documented to call back into after wiring every dynamic property, which
        // is also why `appState` and `windowController` themselves are only ever read from here.
        //
        // `let _ = (assignment)` rather than a bare statement: `@SceneBuilder` requires every
        // statement in this block to build a `Scene`, and an assignment's type is `()`, which does
        // not conform. Wrapping it as a discarded `let` is the standard way to smuggle a side effect
        // past a result builder -- the same trick as `let _ = Self._printChanges()`.
        let _ = (appDelegate.windowController = windowController)
        // The second thing an AppKit surface needs from here, and handed over the same way: the
        // pane that owns the queue is a `@StateObject`, so `body` is the only place it can be
        // reached from. A file dropped on Murmure's icon goes through this.
        let _ = (appDelegate.transcribe = { source in _ = transcriptsModel.transcribe(source) })
        // The control server's handover (lot 11-S): the ONE queue and its submitter are the pane's
        // (10-S), and the server itself belongs to the delegate, which is what starts it on the
        // Finder path. Nothing here starts it — a handover that did would be a second entry point.
        let _ = appDelegate.configureControlServer(
            submitteur: { source in
                let element = await transcriptsModel.submit(source)
                return ControlJobHandle(
                    libelle: element.source,
                    attendu: { await Self.outcome(of: element, model: transcriptsModel) })
            },
            fournisseurStatut: { await transcriptsModel.queueStatus() })
        MenuBarExtra {
            // Which mode the dictation in progress is running under -- readable while it runs,
            // because that is what decides whether what he is saying goes to the LLM. The
            // checkmarks below cannot answer it: with "Automatique" ticked, the app picks.
            //
            // `onAppear` re-reads `modes/` so a file added or renamed by hand is offered without
            // restarting Murmure. It is attached to this line rather than to a conditional one so
            // it is always present in the menu, and it is a best effort: whether SwiftUI runs
            // `onAppear` for the items of a `MenuBarExtra` menu could not be verified without
            // launching the app. If it never fires, the list is the one the launch and the last
            // dictation left -- stale by at most one dictation, never wrong about the modes it
            // does show.
            Button(MenuText.activeMode(appState.activeMode.name)) {}
                .disabled(true)
                .onAppear { controller.refreshModes() }
            // `Toggle` is how a SwiftUI menu draws a checkmark. These are radio buttons, not
            // switches -- see `AppState.modeSelection`.
            //
            // "Automatique" is a real choice and the shipped one, not the absence of a choice: it
            // hands `ModeSelection.resolve` a nil `manualKey`, which is exactly what lot 2 did.
            // Without it, picking a mode once would make the `autoActivate` rule unreachable for
            // good, and Louis would have no way back to the behaviour he validated.
            Toggle(MenuText.automaticMode, isOn: appState.modeSelection(nil))
            ForEach(appState.availableModes, id: \.key) { mode in
                Toggle(mode.name, isOn: appState.modeSelection(mode.key))
            }
            Divider()
            if let warning = appState.clipboardWarning {
                Button(warning) {}.disabled(true)
            }
            if appState.hotkeyUnavailable {
                Button(AppAlert.hotkeyUnavailable.message) {}
                    .disabled(true)
            }
            // Accessibility, with the one thing that can be done about it. The standing panel
            // offers the same button; this is its fallback, and it is not redundant belt: whether
            // a click reaches a SwiftUI button inside a panel that can never become key is AppKit
            // behaviour on real hardware, and a menu item is a route known to work.
            if appState.accessibilityDenied {
                Button(AppAlert.accessibilityDenied.message) {}
                    .disabled(true)
                // Both the label and the destination come off the alert rather than being
                // written here, so the menu and the standing panel cannot end up offering the
                // same fix under two different words. Unwrapped together: an alert with a link
                // and no title, or a title and no link, is a button that says nothing or does
                // nothing, and neither belongs in a menu.
                if let raw = AppAlert.accessibilityDenied.settingsURL,
                   let url = URL(string: raw),
                   let title = AppAlert.accessibilityDenied.actionTitle {
                    Button(title) { NSWorkspace.shared.open(url) }
                }
            }
            if let message = appState.lastFailureMessage {
                Button(message) {}.disabled(true)
            }
            // The refinement produced something other than what the mode asked for, and the text
            // was inserted anyway. Held here rather than dropped: a raw transcript where a
            // rewrite was expected looks exactly like a model that did a poor job.
            if let notice = appState.refinementNotice {
                Button(notice) {}.disabled(true)
            }
            // One line per mode file to fix. `ModeStore` and `ModeSelection` report them one by
            // one so each names its own file, and collapsing them into a count would undo that.
            ForEach(appState.modeProblems, id: \.self) { problem in
                Button(problem) {}.disabled(true)
            }
            Button(MenuText.repasteLastTranscription) { controller.repasteLast() }
            // The recovery that survives a denied Accessibility: without that permission
            // `CGEvent.post` does nothing, so the line above cannot work and the clipboard is the
            // only way the transcript leaves Murmure. Also the standing panel's Copy button's
            // fallback, for the reason given above it.
            Button(MenuText.copyLastTranscription) { controller.copyLast() }
            Divider()
            // **« New Transcription »** (plan §2.7): the entry that takes a link. It is in the menu
            // bar and not only in the pane because it has to work with no window open -- and no
            // window open is exactly when a link gets pasted.
            //
            // It is the *whole* launch surface for a link: nothing declares `http`/`https` for this
            // app (decision R1). A declaration would put Murmure in the "Open with" list of every
            // web link on the machine, which is an effect nobody asked for, for a gesture the pane's
            // drop target and this prompt already cover.
            Button(MenuText.newTranscription) {
                NewTranscriptionPrompt.present { transcriptsModel.transcribe($0) }
            }
            // What the queue is doing, while it does it (criterion 19): one line per element, in the
            // order they were added, in its own state's word. The words come from the core
            // (`TranscriptQueueText`, frozen by lot 10's contract) -- a sentence written in this
            // view is a sentence `MenuTextTests`' language rule cannot see.
            ForEach(transcriptsModel.menuLines, id: \.id) { element in
                Button(TranscriptQueueText.label(for: element)) {}.disabled(true)
            }
            // The progress bar (criterion 18), and it covers the WHOLE work: each phase holds a
            // share of it, decided by the pane's own phase table
            // (`TranscriptsPaneModel.observe(_:)`), which increment 2's rework extends without the
            // bar changing shape.
            if let progress = transcriptsModel.progress {
                ProgressView(value: progress).frame(width: 220)
            } else if transcriptsModel.isWorking {
                // The model is being prepared: a 1.6 GB download the first time, then 112 s of
                // CoreML compiling this machine's model. No fraction of that is known, so the bar
                // turns rather than advancing, and the sentence says which wait it is -- the
                // `preparingModel` phase of the dictation panel exists for exactly this reason, and
                // it is the same sentence here because it is the same wait.
                ProgressView().frame(width: 220)
                if let preparation = transcriptsModel.preparation {
                    Button(StatusPanelText.label(for: .preparingModel(preparation))) {}.disabled(true)
                }
            }
            Divider()
            // The window's only entry point, and it has to be: an accessory app is not in ⌘Tab,
            // so once the window is behind Xcode nothing but this glyph brings it back
            // (plan §2.4, consequence 1).
            OpenWindowMenuItem(controller: windowController)
            Divider()
            Button(MenuText.quit) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            // The label, not the menu content, is what captures `openWindow`: it is the only view
            // guaranteed to exist for the app's whole life, including while no window does --
            // which is exactly when a Dock click needs the action `WindowController.reopen()` uses.
            HStack(spacing: 4) {
                Label("Murmure", systemImage: appState.menuBarSymbol)
                // The badge (criterion 18, decision O1): TWO distinct states off the queue itself,
                // never one. A dot while a job is waiting or running, a check once one has finished
                // -- so "finished" no longer looks like "nothing ever ran" -- and nothing at rest,
                // where Murmure's own glyph already carries the dictation's state. The shape is the
                // whole distinction (`TranscriptBadgeState.symbol`, frozen by lot 10-O1's contract):
                // no colour, no word. The notification is still what says a job ended *now*; the
                // check is what still says it afterwards. The progress bar in the menu is what says
                // how far.
                TranscriptBadgeLabel(state: transcriptsModel.badge)
            }
            .background(OpenWindowCapture(controller: windowController))
        }
        .environmentObject(appState)

        // One resizable window, not a `Settings` scene and not Superwhisper's two (D1). A
        // `Settings` scene gives ⌘, for free and nothing else: it cannot be opened programmatically
        // without a private selector whose name changed between macOS 13 and 14, and this menu is
        // the only entry point there is. It is also not resizable, and History is the section that
        // wants the size.
        //
        // `Window` and not `WindowGroup`, which is what makes "never a second window" structural
        // rather than defended: a `Window` scene is single-instance by construction.
        //
        // Named for the application rather than "Settings", because six of its eight sections are
        // settings and the other two -- History and Transcripts -- are the reason it gets opened
        // (D3, R8).
        Window("Murmure", id: WindowController.windowID) {
            MainWindowView(
                controller: windowController, home: homeModel, history: historyModel,
                transcripts: transcriptsModel, modes: modesModel,
                models: modelsModel, general: generalModel, advanced: advancedModel)
                .environmentObject(appState)
                // The Transcripts tab's drop target (plan §2.7): this is where a local FILE and a
                // WEB LINK are accepted by dropping them into the window -- a link never reaches
                // the icon, because nothing here declares `http`/`https` for it (R1).
                //
                // It is attached to the window's content rather than inside the pane for a reason of
                // its own: the drop has to be refused while another section is showing. A drop that
                // queues a transcription while the person is looking at General would start
                // something somewhere else than where the gesture was made, and the pane's own
                // layout is not where that rule belongs -- which section is up is the window
                // controller's state, and this is the one file that can read it beside the model.
                .dropDestination(for: URL.self) { urls, _ in
                    guard windowController.section == .transcripts, !urls.isEmpty else {
                        return false
                    }
                    // A multi-file drop is one batch: all URLs reach the queue in the order they
                    // were dropped, and the model owns the one resolution point.
                    _ = transcriptsModel.transcribe(TranscriptDrop.sources(for: urls))
                    return true
                }
        }
        .defaultSize(
            width: WindowLayout.defaultSize.width, height: WindowLayout.defaultSize.height)
        .windowResizability(.contentMinSize)
    }
}

/// The menu item, as its own view for one reason: `openWindow` is a SwiftUI *environment* value,
/// and reading it needs a view to read it from.
///
/// ⌘, is the shortcut every Mac user tries first, and it is free here — Murmure has no `Settings`
/// scene to claim it.
private struct OpenWindowMenuItem: View {
    let controller: WindowController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(MenuText.openWindow) { controller.show(using: openWindow) }
            .keyboardShortcut(",")
    }
}

/// Hands `WindowController` the `OpenWindowAction` it cannot read for itself -- it is not a view --
/// so that a Dock-tile click can present the `Window` scene the same way this menu's item does.
/// Attached to the menu bar label rather than any menu content: the label is on screen for the
/// app's whole life, unlike the menu items, which SwiftUI builds only while the menu is open.
/// Renders nothing; `Color.clear` is just a view for `.onAppear` to hang off.
private struct OpenWindowCapture: View {
    let controller: WindowController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear { controller.register(openWindow: openWindow) }
    }
}

/// The paste prompt behind the menu bar's « New Transcription » (plan §2.7).
///
/// **Why a modal `NSAlert` and not a SwiftUI sheet.** The menu bar item is the app's only launch
/// surface that exists with NO window open -- and no window open is exactly when a link gets
/// pasted. A sheet would need the window first, which is the thing this entry is avoiding.
///
/// **Why the alert has no second button.** Its two words are `MenuText.newTranscription` and
/// AppKit's own default button, which is already in the system's language. A "Cancel" written here
/// would be a word of Murmure's interface living outside `MenuText` -- and by the plan's own rule
/// (§2.7, last bullet) interface words live in `MenuText`, where lot 10's frozen contract has
/// exactly three, none of them that one. It is not needed either: an empty field is the way out,
/// and a refusal re-presents the same field with the reason under it, so a mistyped link is fixed
/// where it was typed instead of being reported somewhere else.
private enum NewTranscriptionPrompt {
    /// `transcribe` answers nil when the entry was accepted and queued; anything else is the
    /// sentence that says why it was not.
    static func present(transcribe: (String) -> String?) {
        let champ = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        var refus: String?
        while true {
            let alerte = NSAlert()
            alerte.messageText = MenuText.newTranscription
            if let refus {
                alerte.informativeText = refus
            }
            alerte.accessoryView = champ
            // The field takes the keyboard when the alert comes up: ⌘V is the gesture this entry
            // is named after, and it would otherwise need a click first.
            alerte.window.initialFirstResponder = champ
            alerte.runModal()
            let texte = champ.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty field asks for nothing. It is the way out of a prompt that has no "Cancel"
            // button, and it is not a refusal to report -- nothing was typed.
            guard !texte.isEmpty, let sentence = transcribe(texte) else { return }
            refus = sentence
        }
    }
}

/// The mapping between the queue's outcome (10-S) and the socket's one (11-S): one table, here.
///
/// The queue ends on a **stem** it carried from the document the work wrote; the socket answers
/// with the **document** itself, because `murmure transcribe` prints it. A stem the disk cannot
/// read is a failure with a reason — never a success nobody can open.
private extension MurmureApp {
    static func outcome(
        of element: TranscriptQueueEntry, model: TranscriptsPaneModel
    ) async -> ControlJobOutcome {
        switch await model.outcome(of: element) {
        case .complete(let documentID):
            guard let document = model.finishedDocument(id: documentID) else {
                return .failed("« \(documentID) » finished without a readable transcript.")
            }
            return .complete(document)
        case .failed(let raison):
            return .failed(raison ?? "The transcription was cancelled.")
        }
    }
}
