import Foundation

/// One key event as this package can see it: a raw AppKit modifier mask, and a virtual key code
/// when the event was a `keyDown` rather than a bare change of the held modifiers.
///
/// **Two cases and not one struct with an optional `keyCode`.** "No key yet" is not a missing
/// field, it is the other event `NSEvent.addLocalMonitorForEvents(matching: [.keyDown,
/// .flagsChanged])` can deliver, and ``HotkeyRecording`` answers the two very differently: a
/// `flagsChanged` alone is a press still in progress
/// (``HotkeyRecordingOutcome/stillPressing``), never a refusal -- pressing and holding ⌥ is not a
/// mistake, it is a chord that is not finished yet.
public enum CapturedKeyEvent: Equatable {
    /// Only the held modifiers changed -- `.flagsChanged`, no character key involved yet.
    case flagsChanged(appKitModifierFlags: UInt)
    /// A real key went down, with whatever modifiers were held at that moment -- `.keyDown`.
    case keyDown(keyCode: UInt16, appKitModifierFlags: UInt)
}

/// What became of a captured press.
public enum HotkeyRecordingOutcome: Equatable {
    /// A legal binding.
    case accepted(KeyCombo)
    /// Only a modifier is held so far -- not an error, the user has not finished pressing yet.
    case stillPressing
    /// Refused, with the one sentence to show: English, one sentence, naming what to do instead
    /// -- the register `ModeValidationError.description` and `OllamaFailure.remedy` already use.
    case refused(String)
}

/// Turns a captured keypress into a legal ``KeyCombo``, or says why not.
///
/// The rules, and why each exists:
///
/// - **At least one of ⌃⌥⇧⌘ is required, except for F1-F12.** A global hotkey with no modifier on
///   an ordinary key steals that character from every application on the machine; a function key
///   is not a character anyone types into a document, so it is bindable bare.
/// - **Escape is refused, bare or modified.** `KeyCombo.cancelRecording` is bare Escape, and
///   `CancelHotkey` registers it for as long as a recording is in progress -- a toggle bound to
///   Escape would fight it.
/// - **A modifier-only press is not a binding.** See ``CapturedKeyEvent``'s own note.
///
/// Pure. The only part that looks like it should not be -- converting an AppKit modifier mask --
/// lives beside `KeyCombo` (`KeyCombo.carbonModifierMask(fromAppKitModifierFlags:)`) because it is
/// the one place this package converts a foreign bitmask, and is tested there directly against
/// the real AppKit literals.
public enum HotkeyRecording {
    public static func evaluate(_ event: CapturedKeyEvent) -> HotkeyRecordingOutcome {
        switch event {
        case .flagsChanged:
            return .stillPressing

        case .keyDown(let keyCode, let appKitModifierFlags):
            let code = UInt32(keyCode)
            let carbonModifiers = KeyCombo.carbonModifierMask(
                fromAppKitModifierFlags: appKitModifierFlags)

            // Checked before the modifier rule below: Escape is refused whether or not something
            // else is held with it, so a modified Escape must not fall through to "accepted".
            if code == KeyCombo.cancelRecording.keyCode {
                return .refused(
                    "Escape can't be the shortcut -- it already cancels a recording in progress.")
            }
            if carbonModifiers != 0 {
                return .accepted(KeyCombo(keyCode: code, carbonModifiers: carbonModifiers))
            }
            if KeyCombo.functionKeyCodes.contains(code) {
                return .accepted(KeyCombo(keyCode: code, carbonModifiers: 0))
            }
            return .refused(
                "Add ⌃, ⌥, ⇧ or ⌘ -- a bare key would be taken from every app on your Mac.")
        }
    }
}
