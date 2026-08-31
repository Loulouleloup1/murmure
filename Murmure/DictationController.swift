import Foundation
import MurmureCore
import os
import SwiftUI

/// Owns the one dictation session, the one hotkey registration, and the binding between the
/// session's state and what the menu bar shows.
///
/// No capture list on the closures below: nothing `AppState` holds points back here, so a strong
/// capture is not a cycle — and the controller lives for the whole process anyway.
@MainActor
final class DictationController {
    private let session: DictationSession
    private let hotkeys = HotkeyManager()
    private let inserter: PasteInserter
    private let appState: AppState
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "dictation")

    init(appState: AppState) {
        self.appState = appState

        // Task 6 made `onClipboardOutcome` a REQUIRED init parameter with no default, precisely so
        // this line cannot forget to decide. `PasteInserter()` no longer compiles.
        let inserter = PasteInserter { outcome in
            Task { @MainActor in appState.noteClipboard(outcome) }
        }
        self.inserter = inserter

        session = DictationSession(
            recorder: AudioRecorder(),
            transcriber: WhisperKitEngine(),
            inserter: inserter
        ) { state in
            Task { @MainActor in
                if case .recording = state {
                    // Starting a dictation clears the previous one's warnings, and this is the only
                    // thing that ever will: `PasteInserter` reports an outcome only when it actually
                    // touched the clipboard, so its empty-transcript early return would otherwise
                    // leave the last warning on screen indefinitely.
                    appState.clipboardWarning = nil
                    appState.lastFailureMessage = nil
                }
                // The message is not just an icon (ruling L7): `.failed`'s payload says whether the
                // microphone is denied, the model failed to download or the paste was refused, and
                // an exclamation triangle with no text is a failure mechanism with no consumer.
                if case .failed(let message, _) = state {
                    appState.lastFailureMessage = message
                }
                appState.status = switch state {
                case .idle: .idle
                case .recording: .recording
                case .transcribing: .transcribing
                case .inserting: .inserting
                case .failed: .failed
                }
            }
        }

        // Task 4 deliberately shipped `register` WITHOUT `@discardableResult`. A ⌥Space that
        // another app already owns leaves Murmure with no way to start a dictation at all, so the
        // failure has to reach the only surface lot 1 has.
        let registered = hotkeys.register(.defaultToggle) { [session] in
            Task { await session.toggle() }
        }
        if !registered {
            log.error("⌥Space registration refused -- another application owns the combination")
            appState.hotkeyUnavailable = true
            appState.status = .failed
        }
    }

    /// Menu action: paste the last transcript again — after an insertion failure, or into a second
    /// app. Reuses the session's own inserter; a second `PasteInserter` would be a second
    /// clipboard-outcome consumer.
    func repasteLast() {
        Task {
            guard let text = await session.lastTranscript else {
                log.notice("re-paste requested but the last dictation produced no text")
                return
            }
            do {
                try await inserter.insert(text)
            } catch {
                // A re-paste is itself an insertion and fails for the same reasons. Swallowing it
                // would make the menu item look like it did nothing for no stated reason.
                log.error("re-paste failed: \(error.localizedDescription, privacy: .public)")
                appState.lastFailureMessage = "Recollage échoué : \(error.localizedDescription)"
                appState.status = .failed
            }
        }
    }
}
