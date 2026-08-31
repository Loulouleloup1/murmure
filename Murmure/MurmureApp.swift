import MurmureCore
import SwiftUI
import os

/// Murmure is `LSUIElement: true`, so a normal launch from the Finder has no attached console
/// and `print` goes nowhere anybody will ever read. Anything permanent logs here instead, where
/// `log stream --predicate 'subsystem == "com.louiscourcier.Murmure"'` and Console.app can see it.
private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "app")

@main
struct MurmureApp: App {
    @StateObject private var appState = AppState()

    /// Temporary scaffolding for the Task 5 manual gate; removed in Task 7 with the menu items.
    /// `--debug-transcribe <path>` runs the same code as the menu item without a click, so the
    /// gate can be run against the shipped binary from a terminal instead of driving the UI.
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
            // Temporary scaffolding for the Task 6 manual gate; removed in Task 7. The delay is
            // there so the click can be followed by clicking into the target app.
            Button("Debug: insert in 3 s") { Self.debugInsertAfterDelay(seconds: 3) }
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

    private static func debugInsertAfterDelay(seconds: Double) {
        let text = "murmure round-trip \(Int.random(in: 100...999))"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            print("debug: clipboard before: [\(NSPasteboard.general.string(forType: .string) ?? "nil")]")
            let inserter = PasteInserter { outcome in
                print("debug: clipboard outcome: \(outcome)")
            }
            do {
                try await inserter.insert(text)
                print("debug: inserted [\(text)]")
            } catch {
                print("debug: insert failed: \(error.localizedDescription)")
            }
            print("debug: clipboard after: [\(NSPasteboard.general.string(forType: .string) ?? "nil")]")
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
