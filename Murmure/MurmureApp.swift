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
    @StateObject private var appState: AppState

    /// The one dictation controller, built here so the ⌥Space registration happens once at launch
    /// rather than the first time a menu is drawn. `App` is `@MainActor`, so this init is too.
    private let controller: DictationController

    /// The application window's state: whether it is up, where it sits, which section it is on.
    /// A `StateObject` rather than a `let` because the window's content observes it — an `App`
    /// struct is re-created, and a plain stored object would be a new controller each time.
    @StateObject private var windowController: WindowController

    /// History's state: the query, the rows, the selection. A `StateObject` for the same reason
    /// the window controller is one — an `App` struct is re-created, and a plain stored object
    /// would throw away Louis's search every time SwiftUI rebuilt the scene.
    @StateObject private var historyModel: HistoryPaneModel

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
        _historyModel = StateObject(
            wrappedValue: HistoryPaneModel(
                store: controller.history,
                archiveFailure: controller.historyFailure,
                recordings: controller.recordingsDirectory,
                reRefine: { transcript, mode in
                    await controller.reRefine(transcript, with: mode)
                }))
        // `Storage.url()` and not `directory()`: the PURE path, for the reason the Advanced pane
        // below is given the same one. `ModeStore.save` creates `modes/` before it writes into it,
        // and the controller above has already created it on every launch that can reach
        // Application Support — so nothing about building this pane needs to.
        //
        // **`didChangeModes` is what makes the editor's Save reach the rest of the app**, and a
        // model built with the no-op default would look identical, compile identically and leave
        // the menu offering the list from before the edit.
        _modesModel = StateObject(
            wrappedValue: ModesPaneModel(supportFolder: Storage.url()) { renamed in
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
                language: { ModelInventory.languageModels(in: state.availableModes) }))
        // `controller.rebindToggleHotkey` rather than a copy of the logic: the pane decides
        // whether a captured press is legal (`HotkeyRecording`), the controller decides whether
        // Carbon will actually take it and rolls back a refusal -- and it can only do that from
        // where `HotkeyManager` and `settings` already both live.
        _generalModel = StateObject(
            wrappedValue: GeneralPaneModel(
                settings: settings, rebindToggleHotkey: controller.rebindToggleHotkey))
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
        MenuBarExtra("Murmure", systemImage: appState.menuBarSymbol) {
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
            // The window's only entry point, and it has to be: an accessory app is not in ⌘Tab,
            // so once the window is behind Xcode nothing but this glyph brings it back
            // (plan §2.4, consequence 1).
            OpenWindowMenuItem(controller: windowController)
            Divider()
            Button(MenuText.quit) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
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
        // Named for the application rather than "Settings", because five of its six sections are
        // settings and the sixth -- History -- is the reason it gets opened (D3).
        Window("Murmure", id: WindowController.windowID) {
            MainWindowView(
                controller: windowController, history: historyModel, modes: modesModel,
                models: modelsModel, general: generalModel, advanced: advancedModel)
                .environmentObject(appState)
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
