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

    init() {
        // Spec §9's FIRST half: Accessibility is detected at launch, not at the first failed
        // paste, and the result is consumed rather than discarded -- a denied permission means
        // every future insertion does nothing at all.
        //
        // Spec §9's SECOND half is NOT done: it asks for a banner with a deep link to System
        // Settings, and this is a log line. A log line is invisible to Louis in a menu-bar app.
        // The banner belongs to the UI lot that owns Murmure's windows; until it exists, treat
        // this box as UNTICKED -- the denial is diagnosable, not surfaced.
        if !PasteInserter.requestAccessibilityIfNeeded() {
            logger.error("Accessibility permission not granted -- text insertion will do nothing")
        }
        // Built before the `StateObject` wrapper so the controller and the view observe the same
        // instance: `_appState`'s wrapped value must be handed in, not read back out of the
        // wrapper here (reading a `@StateObject` from `init` is unsupported).
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        controller = DictationController(appState: state)
    }

    var body: some Scene {
        MenuBarExtra("Murmure", systemImage: appState.menuBarSymbol) {
            if let warning = appState.clipboardWarning {
                Button(warning) {}.disabled(true)
            }
            if appState.hotkeyUnavailable {
                Button("⌥Espace indisponible — une autre app détient le raccourci") {}
                    .disabled(true)
            }
            if let message = appState.lastFailureMessage {
                Button(message) {}.disabled(true)
            }
            Button("Recoller la dernière transcription") { controller.repasteLast() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .environmentObject(appState)
    }
}
