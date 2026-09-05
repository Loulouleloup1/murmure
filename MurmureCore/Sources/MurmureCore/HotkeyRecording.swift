import Foundation

/// One key event as this package can see it: a raw AppKit modifier mask, and a virtual key code
/// -- always, now, on both cases.
///
/// **Two cases and not one struct with an optional `keyCode`.** "No key yet" is not a missing
/// field, it is the other event `NSEvent.addLocalMonitorForEvents(matching: [.keyDown,
/// .flagsChanged])` can deliver, and ``HotkeyRecording`` answers the two very differently: a
/// `flagsChanged` alone is a press still in progress on its own, in isolation
/// (``HotkeyRecordingOutcome/stillPressing``), never a refusal -- pressing and holding ⌥ is not a
/// mistake, it might be a chord that is not finished yet, or it might be the whole gesture of a
/// modifier-only binding, and telling the two apart takes more than one event
/// (``HotkeyRecordingSession``).
///
/// **`flagsChanged` carries `keyCode` too, not just the mask.** `NSEvent` hands it over on a
/// `.flagsChanged` the same as on a `.keyDown` -- it is the virtual key code of the modifier that
/// just changed, not of whatever else happens to be held -- and ``HotkeyRecordingSession`` needs
/// exactly that to tell "this modifier went down" from "this modifier went up" without having to
/// reverse-engineer it out of a bitmask that only says which CLASSES of modifier (⌃⌥⇧⌘, and fn --
/// `.function`, 1<<23, is a real bit in that mask too, see `KeyComboTests.swift`) are currently
/// down as a whole, never which of a class's one or two PHYSICAL keys it was, and never, on its
/// own, whether this particular event is that class's down or its up.
public enum CapturedKeyEvent: Equatable {
    /// Only the held modifiers changed -- `.flagsChanged`, no character key involved yet.
    /// `keyCode` is the modifier that changed, not the full set currently held.
    case flagsChanged(keyCode: UInt16, appKitModifierFlags: UInt)
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

/// Turns a captured `.keyDown` into a legal ``KeyCombo``, or says why not.
///
/// The rules, and why each exists:
///
/// - **At least one of ⌃⌥⇧⌘ is required, except for F1-F12.** A global hotkey with no modifier on
///   an ordinary key steals that character from every application on the machine; a function key
///   is not a character anyone types into a document, so it is bindable bare.
/// - **Escape is refused, bare or modified.** `KeyCombo.cancelRecording` is bare Escape, and
///   `CancelHotkey` registers it for as long as a recording is in progress -- a toggle bound to
///   Escape would fight it.
///
/// **A modifier-only press is a binding, but not one this function decides.** A single ⌘ or
/// right-⌥ tapped alone is legal (``KeyCombo/isModifierOnly``) -- Superwhisper's own signature
/// gesture -- but telling a tap from a chord attempt needs to remember more than one event
/// (was a second modifier ever added? did a key go down before release?), which a stateless
/// function over one event cannot do. That is ``HotkeyRecordingSession``'s job: it owns every
/// `.flagsChanged`, and calls this function only for a `.keyDown`, which is always the LAST event
/// of an interaction -- accepted or refused, there is nothing left to track afterwards. The two
/// are not competing rules over the same event; they are rules over disjoint ones.
///
/// Pure. The only part that looks like it should not be -- converting an AppKit modifier mask --
/// lives beside `KeyCombo` (`KeyCombo.carbonModifierMask(fromAppKitModifierFlags:)`) because it is
/// the one place this package converts a foreign bitmask, and is tested there directly against
/// the real AppKit literals.
public enum HotkeyRecording {
    /// Named once so ``evaluate(_:)`` and ``wouldRefuse(_:)`` -- which asks the same question
    /// about a `KeyCombo` that never passed through this recorder at all -- can never drift to two
    /// different sentences for what is one and the same rule.
    private static let escapeRefusal =
        "Escape can't be the shortcut -- it already cancels a recording in progress."
    private static let bareKeyRefusal =
        "Add ⌃, ⌥, ⇧ or ⌘ -- a bare key would be taken from every app on your Mac."

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
                return .refused(escapeRefusal)
            }
            if carbonModifiers != 0 {
                return .accepted(KeyCombo(keyCode: code, carbonModifiers: carbonModifiers))
            }
            if KeyCombo.functionKeyCodes.contains(code) {
                return .accepted(KeyCombo(keyCode: code, carbonModifiers: 0))
            }
            return .refused(bareKeyRefusal)
        }
    }

    /// Whether `combo` is one this recorder would refuse if it were ever captured through it, and
    /// the sentence to show if so -- `nil` when it would be accepted.
    ///
    /// **Exists because a mode's `hotkey` can bypass the recorder entirely.** There is no editor
    /// for it yet (`docs/plans/2026-09-backlog.md` §7) -- today the only way to set one is
    /// hand-editing the mode's JSON file, which ``evaluate(_:)`` above never sees at all: nothing
    /// stands between a bare Escape written into `modes/prompt.json` and `HotkeyManager.register`
    /// actually taking the key from every application on the Mac, fighting `CancelHotkey` for it on
    /// every recording. `HotkeyAssignments.resolve` calls this on every mode's `hotkey` for exactly
    /// that reason -- a mode-file value is not a value this recorder has ever approved, unlike the
    /// toggle, which can only ever be set by rebinding it through `evaluate(_:)`/
    /// `HotkeyRecordingSession` in the first place.
    ///
    /// **Modifier-only combos are legal here too**, unlike asking ``evaluate(_:)`` about the same
    /// combo as a synthetic `.keyDown`. A modifier-only combo's own acceptance is decided by
    /// `HotkeyRecordingSession`, watching a RUN of `.flagsChanged` events (the tap gesture itself,
    /// `KeyCombo.isModifierOnly`'s own doc comment) -- `evaluate(_:)` only ever sees one `.keyDown`
    /// at a time and would refuse a modifier-only combo as "no modifier held", which is exactly
    /// backwards for the one binding shape that IS legal with none.
    public static func wouldRefuse(_ combo: KeyCombo) -> String? {
        // Checked first, matching `evaluate(_:)`'s own order: Escape is refused whether or not
        // something else is held with it.
        if combo.keyCode == KeyCombo.cancelRecording.keyCode {
            return escapeRefusal
        }
        if combo.carbonModifiers != 0 {
            return nil
        }
        if combo.isModifierOnly {
            return nil
        }
        if KeyCombo.functionKeyCodes.contains(combo.keyCode) {
            return nil
        }
        return bareKeyRefusal
    }
}
