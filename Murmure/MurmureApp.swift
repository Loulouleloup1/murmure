import MurmureCore
import SwiftUI

@main
struct MurmureApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Murmure", systemImage: appState.menuBarSymbol) {
            Text("Murmure — lot 1")
            // Temporary scaffolding for the Task 3 manual gate; removed in Task 7.
            Button("Debug: record 3 s") { Self.debugRecord(seconds: 3) }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .environmentObject(appState)
    }

    private static func debugRecord(seconds: Double) {
        let recorder = AudioRecorder()
        do {
            try recorder.start()
        } catch {
            print("debug: start failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard let url = recorder.stop() else {
                print("debug: recording failed: \(recorder.lastFailure?.localizedDescription ?? "no recording")")
                return
            }
            print("debug: recorded: \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
