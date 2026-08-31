import MurmureCore
import SwiftUI

@main
struct MurmureApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Murmure", systemImage: appState.menuBarSymbol) {
            Text("Murmure — lot 1")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .environmentObject(appState)
    }
}
