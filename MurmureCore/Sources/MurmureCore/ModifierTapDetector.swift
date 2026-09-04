import Foundation

/// Whether one specific physical modifier key, watched continuously rather than for the length of
/// one recording, was just tapped alone -- the pure logic behind `HotkeyManager`'s modifier-only
/// firing path in the app target, which cannot itself carry a unit test (`Murmure` has no test
/// bundle, and what it watches are real `NSEvent`s delivered through Accessibility-gated
/// monitors). Everything decidable without an `NSEvent` lives here instead, and is tested here.
///
/// **Not `HotkeyRecordingSession`, and this is a correction, not a stylistic choice.** See
/// `HotkeyManager.swift`'s own doc comment (on `registerModifierOnly`) for the traced ⌘C example
/// that is the reason this type exists apart from that one -- a duration ceiling alone cannot
/// separate a tap from a chord; only seeing the character key can, and only a detector that
/// survives across an indefinite number of presses (rather than resetting on every `.keyDown`,
/// which `HotkeyRecordingSession` correctly does for a one-shot recording) can watch for it.
///
/// **The rule, in full, and it is simpler than a chord recording's:** the target key goes down;
/// if ANYTHING else happens before it comes back up -- a `.keyDown` for any character, a mouse
/// button going down, or a `.flagsChanged` for any OTHER key -- the eventual release does not
/// fire. Only a target down immediately followed by the SAME target's own up, with nothing at all
/// observed in between, is a tap. The duration ceiling is a SECOND guard on top of that, not the
/// rule: it catches a hold that never sees an interrupting event at all (a finger resting on the
/// key), which "nothing intervened" alone cannot.
///
/// **Down and up are read off the authoritative modifier-class bit, never inferred by toggling.**
/// An earlier version of this file tracked `isDown` as a plain `Bool` flipped on every
/// `.flagsChanged` for the target key -- which is wrong the moment a single such event is ever
/// missed (secure input engaged, a hold that spans `register()`, monitor-ordering during
/// teardown): flip it once too few, and the flag is inverted for the rest of the process --
/// a clean tap never fires again, and the SECOND tap within the ceiling fires on the key going
/// DOWN instead of up. `appKitModifierFlags` on the very same event already says, as a fact
/// rather than a guess, whether the target's modifier CLASS (⌘, ⌥, ⇧, ⌃, fn) is down right now --
/// so that bit, not a toggle, is what `isDown` is derived from below. A duplicate or glitched
/// event that reports no change is simply ignored (`.notYet`), rather than toggling into the
/// wrong state.
///
/// **The one edge case this does not resolve, and does not need to.** Both keys of one class
/// (e.g. left ⌘ and right ⌘) held at once, then only ONE of them released: the class bit stays
/// set, because the other physical ⌘ key is still down, so this reads as "still down" even for
/// the specific physical key this detector was told to watch. `KeyCombo.modifierKeyCodes` binds a
/// SPECIFIC physical key, and AppKit's device-independent mask cannot tell two keys of the same
/// class apart once one is known to still be held -- this is a real limitation, not a bug, and
/// the failure mode is silent (the eventual release of the other key is what fires, later than
/// expected), never a wrong combo firing.
public struct ModifierTapDetector {
    public enum Outcome: Equatable {
        /// No verdict yet -- the target is not involved in this event, or is still held.
        case notYet
        /// The target went down and came back up alone, within the ceiling, with nothing else
        /// observed in between.
        case fire
        /// The target came back up, but something intervened, or took too long.
        case suppressed
    }

    private let target: KeyCombo
    private var isDown = false
    private var interrupted = false

    public init(target: KeyCombo) {
        self.target = target
    }

    /// Whether the target is currently held, as this detector's own authoritative state (the
    /// class-bit derivation above, not a guess). Exposed so `HotkeyManager` can stamp or clear its
    /// own down-time bookkeeping only on a genuine transition THIS type recognises, rather than
    /// keeping a second, independent toggle of its own that could desync from this one after
    /// exactly the dropped event this type's own note describes.
    public var isTargetDown: Bool { isDown }

    /// The device-independent bit that is set in `NSEvent.modifierFlags` whenever ANY physical key
    /// of `keyCode`'s class is held -- the four `RegisterEventHotKey`-relevant classes plus `fn`,
    /// spelled out as raw values for the same reason `KeyCombo.carbonModifierMask` does: this
    /// package has no AppKit import to name them from. `0` for a keyCode with no modifier class
    /// (unreachable in practice -- `target.keyCode` is always one of `KeyCombo.modifierKeyCodes`
    /// -- but a total function is cheaper than asserting a precondition no caller can violate).
    private static func classBit(forKeyCode keyCode: UInt32) -> UInt {
        switch keyCode {
        case 54, 55: return 0x0010_0000 // ⌘, right (54) and left (55)
        case 56, 60: return 0x0002_0000 // ⇧, left (56) and right (60)
        case 58, 61: return 0x0008_0000 // ⌥, left (58) and right (61)
        case 59, 62: return 0x0004_0000 // ⌃, left (59) and right (62)
        case 63: return 0x0080_0000 // fn (`.function`)
        default: return 0
        }
    }

    /// Feeds one event. `elapsedSinceDown` is read only on the release that would otherwise fire,
    /// and is the caller's to compute (`Date().timeIntervalSince(downAt)` against a timestamp the
    /// caller stamped) -- kept out of this type so it stays free of a wall clock and is driven by
    /// a literal number in a test, not real elapsed time.
    public mutating func observe(
        _ event: CapturedKeyEvent, elapsedSinceDown: @autoclosure () -> TimeInterval,
        ceiling: TimeInterval
    ) -> Outcome {
        switch event {
        case .keyDown:
            // A character key going down while the target is held is a chord attempt elsewhere
            // (⌘C, ⌘Tab, ...) -- see the type's own note. A keyDown while the target is NOT held
            // is none of this detector's business.
            if isDown { interrupted = true }
            return .notYet

        case .flagsChanged(let keyCode, let appKitModifierFlags):
            guard keyCode == target.keyCode else {
                // Some OTHER modifier changed. If the target is currently down, this is exactly
                // the two-modifiers-held case a chord recording would refuse -- interrupt it the
                // same way a keyDown does. If the target is not down, this is not our concern.
                if isDown { interrupted = true }
                return .notYet
            }

            let classBit = Self.classBit(forKeyCode: target.keyCode)
            let isNowDown = classBit != 0 && (appKitModifierFlags & 0xFFFF_0000) & classBit != 0
            guard isNowDown != isDown else {
                // No real transition -- a duplicate event, or (the documented edge case above)
                // the other physical key of this same class changing while this one stays held.
                // Toggling here, blindly, is exactly the bug this rewrite removes.
                return .notYet
            }

            guard isDown else {
                // The target's own down -- a fresh hold starts clean.
                isDown = true
                interrupted = false
                return .notYet
            }
            // The target's own up -- the hold is over, decide, and reset for the next one.
            isDown = false
            defer { interrupted = false }
            return (!interrupted && elapsedSinceDown() < ceiling) ? .fire : .suppressed
        }
    }

    /// A mouse button went down while the target may be held. Not a `CapturedKeyEvent` -- that
    /// enum's two cases are shaped for `NSEvent.addLocalMonitorForEvents(matching: [.keyDown,
    /// .flagsChanged])`, which is all `HotkeyRecordingSession`'s recording monitor ever watches;
    /// `HotkeyManager`'s persistent modifier-only monitors watch mouse buttons too (an ⌥-click
    /// must not start a dictation), and a click held down while the target is pressed is exactly
    /// the kind of "something else happened" a `.keyDown` already interrupts, so this is handled
    /// the same way rather than by adding a case those other two callers can never receive.
    public mutating func observeMouseDown() -> Outcome {
        if isDown { interrupted = true }
        return .notYet
    }
}
