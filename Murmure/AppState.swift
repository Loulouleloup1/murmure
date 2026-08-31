import MurmureCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle, recording, transcribing, inserting, failed
    }

    @Published var status: Status = .idle

    /// TEMPORARY (ruling L1): registers ⌥Space here so the hotkey is observable before the
    /// dictation pipeline exists. Task 7 owns the one and only `HotkeyManager` -- inside
    /// `DictationController` -- and must DELETE this property, `init()` and
    /// `registerTemporaryHotkey()` outright. Two Carbon registrations of the same combination
    /// are a double-fire or a failed registration, not two working shortcuts.
    let hotkeys = HotkeyManager()

    init() {
        registerTemporaryHotkey()
    }

    var menuBarSymbol: String {
        switch status {
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "hourglass"
        case .inserting: "arrow.down.doc"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// TEMPORARY (ruling L1): flips the menu-bar icon so a press is visible without a pipeline.
    /// Removed with `hotkeys` in Task 7.
    private func registerTemporaryHotkey() {
        hotkeys.register(.defaultToggle) { [weak self] in
            // Carbon calls back on the main thread, but hop explicitly rather than assume it:
            // a wrong assumption here would be a crash on a keypress.
            Task { @MainActor in
                guard let self else { return }
                self.status = self.status == .idle ? .recording : .idle
            }
        }
    }
}
