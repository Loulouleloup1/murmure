import MurmureCore
import SwiftUI
import os

/// Murmure is `LSUIElement: true`, so a normal launch from the Finder has no attached console
/// and `print` goes nowhere anybody will ever read. Anything permanent logs here instead, where
/// `log stream --predicate 'subsystem == "com.louiscourcier.Murmure"'` and Console.app can see it.
private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "app")

@main
struct MurmureApp: App {
    @StateObject private var appState: AppState

    /// The one dictation controller, built here so the ⌥Space registration happens once at launch
    /// rather than the first time a menu is drawn. `App` is `@MainActor`, so this init is too.
    private let controller: DictationController

    /// The application window's state: whether it is up, where it sits, which section it is on.
    /// A `StateObject` rather than a `let` because the window's content observes it — an `App`
    /// struct is re-created, and a plain stored object would be a new controller each time.
    @StateObject private var windowController: WindowController

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
        controller = DictationController(appState: state)
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
            Button("Mode : \(appState.activeMode.name)") {}
                .disabled(true)
                .onAppear { controller.refreshModes() }
            // `Toggle` is how a SwiftUI menu draws a checkmark. These are radio buttons, not
            // switches -- see `AppState.modeSelection`.
            //
            // "Automatique" is a real choice and the shipped one, not the absence of a choice: it
            // hands `ModeSelection.resolve` a nil `manualKey`, which is exactly what lot 2 did.
            // Without it, picking a mode once would make the `autoActivate` rule unreachable for
            // good, and Louis would have no way back to the behaviour he validated.
            Toggle("Automatique", isOn: appState.modeSelection(nil))
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
                if let raw = AppAlert.accessibilityDenied.settingsURL,
                   let url = URL(string: raw) {
                    Button("Ouvrir Réglages…") { NSWorkspace.shared.open(url) }
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
            Button("Recoller la dernière transcription") { controller.repasteLast() }
            // The recovery that survives a denied Accessibility: without that permission
            // `CGEvent.post` does nothing, so the line above cannot work and the clipboard is the
            // only way the transcript leaves Murmure. Also the standing panel's Copy button's
            // fallback, for the reason given above it.
            Button("Copier la dernière transcription") { controller.copyLast() }
            Divider()
            // The window's only entry point, and it has to be: an accessory app is not in ⌘Tab,
            // so once the window is behind Xcode nothing but this glyph brings it back
            // (plan §2.4, consequence 1).
            OpenWindowMenuItem(controller: windowController)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
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
            MainWindowView(controller: windowController)
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
        Button("Ouvrir la fenêtre Murmure") { controller.show(using: openWindow) }
            .keyboardShortcut(",")
    }
}
