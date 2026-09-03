import Foundation

/// The General pane's microphone row: **what Murmure is recording from, stated, not chosen.**
///
/// **There is no picker, and that is a correction rather than a simplification.** `AudioRecorder`
/// opens `engine.inputNode` and nothing else — there is no `AudioDeviceID` anywhere in the app —
/// so a picker would store an answer, tick a row, and leave every dictation recording from the
/// system input regardless. That is the exact shape this lot keeps refusing: a control that
/// reports success and changes nothing, with no error, no warning and no failing test to say so.
/// The stored `microphoneUniqueID` went with it, because a setting nobody reads is the same lie
/// one layer down.
///
/// What is left is honest and is also enough: macOS switches its default input when Louis plugs a
/// headset in, and `AVAudioEngine` follows it, so the row tracks his hardware without Murmure
/// having an opinion. Naming a device requires no permission; opening one does — this row is
/// built from the name alone and never starts a capture.
public enum MicrophoneStatus {
    /// The row's label. "Recording from" and not "Microphone": a noun would read as the name of a
    /// setting, and the point of the row is that it is a report.
    public static let label = "Recording from"

    /// What the row says, given the system's current default input device.
    ///
    /// The suffix is the load-bearing half. Without it the row is a device name sitting where a
    /// picker would be, which invites a click; `(system input)` says both where the answer comes
    /// from and, by saying it, that it is not Murmure's to change.
    ///
    /// `nil` is a Mac with no input device attached at all. It gets a sentence rather than a blank
    /// or a dash, because it is the state in which the next dictation fails
    /// (`AudioRecorder.Failure.noInputDevice`) and this row is the only place that is visible
    /// before it happens.
    public static func line(defaultDeviceName: String?) -> String {
        guard let defaultDeviceName, !defaultDeviceName.isEmpty else {
            return "No microphone is connected"
        }
        return "\(defaultDeviceName) (system input)"
    }

    /// The line under the row, saying where the choice actually lives.
    ///
    /// A read-only row with no explanation is a dead end: the reasonable next move on seeing the
    /// wrong microphone named here is to look for the control that changes it, and it is not in
    /// this window. Naming the pane in System Settings is the difference between a report and a
    /// shrug.
    public static let note =
        "Murmure records from whatever macOS is using. Change it in System Settings › Sound › "
        + "Input."

    /// Where ``note`` sends him — the same deep-link shape `AppAlert` uses for Accessibility, so
    /// every row in this window that has a fix offers it the same way.
    public static let settingsURL = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
}
