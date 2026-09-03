import AVFoundation
import Foundation
import MurmureCore
import SwiftUI

/// What the General pane is looking at: the hotkey, the microphone, the login item, the two sounds.
///
/// Thin, like `VocabularyPaneModel` and for the same reason -- the app target has no test bundle,
/// so anything decided here is verified by reading. Everything that is a decision lives in
/// `MurmureCore` and is tested there: what a shortcut looks like as chips (`Keycap`), what the
/// microphone row says (`MicrophoneStatus`), what every setting defaults to and stores
/// (`AppSettings`), and -- the one that would fail silently -- that the two sound switches actually
/// reach `CueFeedback` (`SoundSettingsWiringTests`). What is left below is three reads of the
/// system and the bindings the view writes through.
///
/// **Two of the four rows are reports and not controls**, which is unusual enough to say once:
/// the hotkey is displayed because rebinding it is a second hotkey lifecycle, and the microphone
/// is displayed because `AudioRecorder` has no way to be told which device to open. Both would
/// otherwise be controls that store an answer and change nothing.
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

    /// `settings` is injected rather than built here for the reason every store in this app is:
    /// the `UserDefaults` domain is chosen once, in `MurmureApp.init`, and a pane that picked its
    /// own would be writing somewhere the dictation pipeline is not reading.
    init(settings: AppSettings) {
        self.settings = settings
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

    // MARK: - The hotkey, displayed

    /// ⌥Space as one chip per key, in macOS's own ⌃⌥⇧⌘ order. The decomposition is `Keycap`'s and
    /// is tested there; this is only which shortcut is shown.
    var toggleKeycaps: [Keycap] {
        KeyCombo.defaultToggle.keycaps
    }

    /// Why there is no Record button beside it.
    ///
    /// **The screen has to be honest that the binding is fixed rather than look like a field that
    /// is not working.** Capturing a new combination is a second hotkey lifecycle -- an event
    /// monitor, a conflict check against the rest of the system, and an unregister/re-register
    /// path with a rollback when the new one is refused -- and it belongs with push-to-talk in a
    /// lot of its own. Saying so is the difference between a decision and an omission.
    let hotkeyNote = "This shortcut is fixed for now. Changing it, and push-to-talk, come together "
        + "in a later release."

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
