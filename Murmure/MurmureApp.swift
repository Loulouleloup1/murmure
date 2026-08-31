import MurmureCore
import SwiftUI

@main
struct MurmureApp: App {
    @StateObject private var appState = AppState()

    /// Temporary scaffolding for the Task 5 manual gate; removed in Task 7 with the menu items.
    /// `--debug-transcribe <path>` runs the same code as the menu item without a click, so the
    /// gate can be run against the shipped binary from a terminal instead of driving the UI.
    init() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-transcribe"),
              index + 1 < CommandLine.arguments.count else { return }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        Task {
            await Self.debugTranscribe(wav: url)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("Murmure", systemImage: appState.menuBarSymbol) {
            Text("Murmure — lot 1")
            // Temporary scaffolding for the Task 3 manual gate; removed in Task 7.
            Button("Debug: record 3 s") { Self.debugRecord(seconds: 3) }
            // Temporary scaffolding for the Task 5 manual gate; removed in Task 7.
            Button("Debug: transcribe last recording") { Self.debugTranscribeLastRecording() }
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

    private static func debugTranscribeLastRecording() {
        Task {
            guard let directory = try? Storage.appSupportDirectory(subfolder: "recordings"),
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: directory, includingPropertiesForKeys: nil
                  ),
                  let latest = files.filter({ $0.pathExtension == "wav" }).sorted(by: {
                      $0.lastPathComponent < $1.lastPathComponent
                  }).last
            else {
                print("debug: no recording to transcribe")
                return
            }
            await debugTranscribe(wav: latest)
        }
    }

    private static func debugTranscribe(wav: URL) async {
        print("debug: transcribing \(wav.path)")
        let start = Date()
        do {
            let text = try await WhisperKitEngine().transcribe(wav: wav)
            print("debug: transcribed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            print("debug: text: [\(text)]")
        } catch {
            print("debug: failed: \(error.localizedDescription)")
        }
    }
}
