import AppKit
import AVFoundation
import Foundation
import MurmureCore
import SwiftUI

/// What the General pane is looking at: the hotkey, the microphone, the login item, the two sounds.
///
/// Thin, like `VocabularyPaneModel` and for the same reason -- the app target has no test bundle,
/// so anything decided here is verified by reading. Everything that is a decision lives in
/// `MurmureCore` and is tested there: what a shortcut looks like as chips (`Keycap`), what a
/// captured press is allowed to become (`HotkeyRecording`), what the microphone row says
/// (`MicrophoneStatus`), what every setting defaults to and stores (`AppSettings`), and -- the one
/// that would fail silently -- that the two sound switches actually reach `CueFeedback`
/// (`SoundSettingsWiringTests`). What is left below is the `NSEvent` capture the app target has to
/// own (`HotkeyRecording` has no AppKit import), three reads of the system, and the bindings the
/// view writes through.
///
/// **One of the four rows is a report and not a control**: the microphone, because `AudioRecorder`
/// has no way to be told which device to open, and a picker beside it would store an answer and
/// change nothing. The hotkey row used to be the other one; see ``startRecordingHotkey()`` for why
/// it no longer is.
@MainActor
final class GeneralPaneModel: ObservableObject {
    /// Whether macOS currently has Murmure registered to start with the session.
    ///
    /// **Read from `SMAppService`, never from `UserDefaults`** -- `AppSettings.launchAtLogin`'s own
    /// note says the service wins on read, and this is that rule applied: System Settings can
    /// revoke the registration while Murmure is not running, and a toggle drawn from the stored
    /// boolean would then be on for a launch that is not going to happen.
    @Published private(set) var launchesAtLogin = false

    /// macOS is holding the registration back (`.requiresApproval`), or nil. The one status a
    /// toggle cannot express: flipping it again does nothing, because the refusal is not Murmure's
    /// to lift.
    @Published private(set) var loginApprovalNote: String?

    /// A registration that was refused. Never swallowed (ruling L7): the switch has to go back
    /// where it was and something has to say why, or it reads as a control that will not stay put.
    @Published private(set) var loginProblem: String?

    /// The device macOS is currently using as its input, as its human-readable name -- nil when
    /// there is none attached.
    ///
    /// **Named, never opened.** Enumerating devices needs no permission; starting a capture does,
    /// and a settings pane that raised the microphone prompt merely by being looked at would be
    /// asking for a permission on behalf of a dictation nobody started.
    @Published private(set) var defaultDeviceName: String?

    private let settings: AppSettings

    /// `DictationController.rebindToggleHotkey(to:)`, handed in rather than reached through a
    /// stored reference to the controller. The pane's job stops at "here is a legal combo"; what
    /// registering it with Carbon and rolling back a refusal looks like is `DictationController`'s
    /// own decision, made where `HotkeyManager` and `settings` already both live. The same shape
    /// `ModesPaneModel`'s `didChangeModes` and `AdvancedPaneModel`'s closures use, for the same
    /// reason: `MurmureApp.init` is the one place that can close over both objects.
    private let rebindToggleHotkey: (KeyCombo) -> Bool

    /// `settings` is injected rather than built here for the reason every store in this app is:
    /// the `UserDefaults` domain is chosen once, in `MurmureApp.init`, and a pane that picked its
    /// own would be writing somewhere the dictation pipeline is not reading.
    init(settings: AppSettings, rebindToggleHotkey: @escaping (KeyCombo) -> Bool) {
        self.settings = settings
        self.rebindToggleHotkey = rebindToggleHotkey
    }

    deinit {
        // Belt beside `GeneralPaneView`'s `.onDisappear`: this object is a `@StateObject` that
        // outlives the pane (`MurmureApp` builds it once), so the view going away is the ordinary
        // way recording stops -- but a monitor left installed past that point would keep
        // swallowing every keystroke Louis's window receives, silently, until the process quits.
        //
        // `deinit` is nonisolated whatever the type says, the same fact `HotkeyManager.deinit`
        // documents; asserted here rather than assumed for the same reason -- the last release of
        // a `@MainActor` object is not guaranteed to happen on the main thread by the type system
        // alone, only by how this app is actually built (every strong owner is itself main-actor).
        MainActor.assumeIsolated {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
    }

    /// Re-reads the three things that live outside this object: the login registration, its
    /// approval status, and the current input device.
    ///
    /// Called every time the pane appears rather than once at launch, because all three can change
    /// while the window is open on another section -- a headset gets plugged in, and Login Items
    /// is a switch in a different application.
    func refresh() {
        loginProblem = nil
        launchesAtLogin = LoginItem.isEnabled
        loginApprovalNote = LoginItem.approvalNote
        defaultDeviceName = Self.currentInputDeviceName()
    }

    // MARK: - The hotkey, recorded

    /// Whether the pane is currently listening for a new shortcut. `@Published` because the
    /// Record button's label and the note underneath both depend on it.
    @Published private(set) var isRecordingHotkey = false

    /// The sentence a refusal leaves on screen, or nil. Cleared at the start of the next recording
    /// so a stale refusal does not linger under a shortcut that has since changed.
    @Published private(set) var hotkeyRecordingMessage: String?

    /// The local monitor capturing the recording, or nil while none is running. `Any?` rather than
    /// a concrete type because that is what `NSEvent.addLocalMonitorForEvents` returns -- an opaque
    /// token meaningful only to `NSEvent.removeMonitor`.
    private var eventMonitor: Any?

    /// The shortcut, as one chip per key in macOS's own ⌃⌥⇧⌘ order. The decomposition is
    /// `Keycap`'s and is tested there; `settings.toggleHotkey` is read fresh on every access
    /// rather than cached, so a successful rebind is reflected the moment `isRecordingHotkey`
    /// flips back to `false` and SwiftUI redraws the row.
    var toggleKeycaps: [Keycap] {
        settings.toggleHotkey.keycaps
    }

    /// What the sentence under the shortcut says: idle instructions, what is happening while
    /// recording, or why the last attempt was refused.
    var hotkeyNote: String {
        if let hotkeyRecordingMessage { return hotkeyRecordingMessage }
        return isRecordingHotkey
            ? "Press the keys for your new shortcut."
            : "Click Record, then press the keys you want. Needs ⌃, ⌥, ⇧ or ⌘, except for the "
                + "F-keys, which can be bound on their own."
    }

    /// Starts listening for a new shortcut. A no-op if already recording, so a second click of
    /// Record cannot install a second monitor over the first.
    ///
    /// **`.addLocalMonitorForEvents`, never a global monitor.** A global monitor needs
    /// Accessibility permission and would watch every keystroke on the machine for as long as this
    /// pane is open; a local one only sees events delivered to Murmure's own window, which is
    /// exactly where Louis is while he is pressing Record. The trade this makes is deliberate: a
    /// combination can only be recorded while the General pane's window is key, never in the
    /// background -- which is the right place for a feature that changes what every OTHER
    /// application's keystrokes might get stolen by.
    func startRecordingHotkey() {
        guard eventMonitor == nil else { return }
        isRecordingHotkey = true
        hotkeyRecordingMessage = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            self?.handle(event)
            // Returning nil swallows the event: the press being recorded must not also reach
            // whatever text field or button happens to be focused behind the Record button.
            return nil
        }
    }

    /// Stops listening, with or without a shortcut having been accepted. Idempotent: called from
    /// every exit of a recording (`handle(_:)`'s three outcomes) and from
    /// `GeneralPaneView`'s `.onDisappear`, and safe to call when nothing is running.
    func stopRecordingHotkey() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        isRecordingHotkey = false
    }

    /// One captured event, handed to `MurmureCore`'s pure rule and acted on.
    ///
    /// The raw `UInt`/`UInt16` values cross into `MurmureCore` rather than an `NSEvent` itself,
    /// because that package has no AppKit import (`HotkeyRecording`'s own note) -- this function
    /// is the one seam where an `NSEvent` becomes the numbers that rule can read.
    private func handle(_ event: NSEvent) {
        let captured: CapturedKeyEvent = event.type == .flagsChanged
            ? .flagsChanged(appKitModifierFlags: event.modifierFlags.rawValue)
            : .keyDown(keyCode: event.keyCode, appKitModifierFlags: event.modifierFlags.rawValue)

        switch HotkeyRecording.evaluate(captured) {
        case .stillPressing:
            // Not done yet -- keep the monitor installed and say nothing.
            return

        case .refused(let message):
            hotkeyRecordingMessage = message
            stopRecordingHotkey()

        case .accepted(let combo):
            // `rebindToggleHotkey` is `DictationController`'s -- it registers with Carbon first
            // and writes `settings.toggleHotkey` only on success, so this call is what decides
            // whether the row below ends up showing the new combo or the one it already had.
            if !rebindToggleHotkey(combo) {
                hotkeyRecordingMessage =
                    "macOS refused that combination -- it may already be in use by another app. "
                    + "Your previous shortcut is still active."
            }
            stopRecordingHotkey()
        }
    }

    // MARK: - The microphone, reported

    /// The row's text -- the device name and where the answer comes from, or the sentence for a
    /// Mac with nothing attached. `MicrophoneStatus` owns the wording and is tested on it.
    var microphoneLine: String {
        MicrophoneStatus.line(defaultDeviceName: defaultDeviceName)
    }

    /// The system's current default audio input, by name.
    ///
    /// `AVCaptureDevice.default(for: .audio)` is the same device `AVAudioEngine.inputNode` opens,
    /// which is what makes this row a report of what Murmure records from rather than a guess
    /// beside it. It returns an object, not a stream: nothing here starts a capture, and nothing
    /// here raises the microphone permission prompt.
    private static func currentInputDeviceName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    // MARK: - Launch at login

    /// The toggle. A binding rather than a `@Published var` with a `didSet`, so that the write
    /// path is a method that can refuse -- `SMAppService` can say no, and a stored property would
    /// have already changed by the time it did.
    var launchAtLogin: Binding<Bool> {
        Binding(get: { self.launchesAtLogin }, set: { self.setLaunchAtLogin($0) })
    }

    /// Registers or unregisters, then re-reads the service.
    ///
    /// **The stored boolean is written only after the service has agreed**, which is
    /// `AppSettings.launchAtLogin`'s own rule. Written at all because it is what a future launch
    /// path would read; the toggle above never consults it.
    ///
    /// On refusal the switch goes back where it was -- `launchesAtLogin` is re-read from the
    /// service rather than assigned from `wanted` -- and the reason is put on screen. A switch
    /// that stayed where it was put while nothing had happened is the failure this whole lot keeps
    /// finding.
    private func setLaunchAtLogin(_ wanted: Bool) {
        loginProblem = nil
        guard LoginItem.setEnabled(wanted) else {
            loginProblem = wanted
                ? "macOS refused to add Murmure to your login items."
                : "macOS refused to remove Murmure from your login items."
            launchesAtLogin = LoginItem.isEnabled
            return
        }
        launchesAtLogin = LoginItem.isEnabled
        loginApprovalNote = LoginItem.approvalNote
        settings.launchAtLogin = launchesAtLogin
    }

    // MARK: - The two sounds

    /// One binding per cue, keyed on `FeedbackCue` rather than on two invented names -- the same
    /// reason `AppSettings` is keyed that way: lot 3 T11 already decided what the sounds are, and a
    /// second list of them would be one more thing to keep in step.
    func soundEnabled(_ cue: FeedbackCue) -> Binding<Bool> {
        Binding(
            get: { self.settings.isSoundEnabled(cue) },
            set: { isEnabled in
                self.settings.setSoundEnabled(isEnabled, for: cue)
                // `AppSettings` is a value type over `UserDefaults`, so nothing here changes and
                // SwiftUI has nothing to observe. The pane is told by hand, or the switch draws in
                // its old position until something else redraws the view.
                self.objectWillChange.send()
            })
    }

    /// What each switch is called, and the one line under it that says when it is heard.
    ///
    /// Written without a `default` so a third cue has to be named here rather than appear as an
    /// unlabelled switch.
    func soundRow(_ cue: FeedbackCue) -> (title: String, note: String) {
        switch cue {
        case .recordingStarted:
            ("Sound when recording starts",
             "The one that matters: it tells you the microphone is live, so you can start "
                + "speaking without looking for the capsule on screen.")
        case .textInserted:
            ("Sound when text is inserted",
             "Confirms the transcript reached the app in front. Silent when nothing was heard.")
        }
    }
}
