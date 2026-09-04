import Foundation

/// A recording in progress: tracks which modifier keys are currently held, and which have been
/// held at all since the last time none were, so a single modifier tapped alone can be told apart
/// from a chord attempt that never added a character key -- something no single ``CapturedKeyEvent``
/// carries enough history to answer on its own (``HotkeyRecording``'s own note).
///
/// **A struct with a mutating method, not a class.** The state is nothing more than two sets of
/// key codes, there is exactly one owner at a time -- `GeneralPaneModel`'s local monitor closure,
/// built fresh for every recording -- and `observe(_:)` is the whole of the API. That is unlike
/// `CancelHotkey`, which several call sites reach at once and needs a lock; nothing here is
/// shared, so nothing here needs one. (`HotkeyManager`'s persistent firing path uses a different
/// type, `ModifierTapDetector`, for a different reason -- see that type's own note.)
///
/// **The rule, in full:**
/// - A `.keyDown` is always final. It resets this session and hands straight to
///   `HotkeyRecording.evaluate`, which already knows the chord rules (Escape, bare key, ⌃⌥⇧⌘
///   required) -- a keyDown ends the interaction, accepted or refused, so there is nothing left
///   to track afterwards.
/// - A `.flagsChanged` toggles that key's membership in the currently-held set. The physical key
///   an event is FOR is stated on the event itself (``CapturedKeyEvent``'s own note), so there is
///   no bitmask to reverse-engineer a down/up out of.
/// - When the held set empties back out with no `.keyDown` having interrupted it, the press is
///   over: **exactly one** distinct modifier key involved is a tap (``HotkeyRecordingOutcome/accepted(_:)``
///   with a modifier-only ``KeyCombo``); **more than one** is a chord attempt that never reached a
///   character key, refused with one sentence -- there is no partial credit for having been close.
///   "Involved" counts every key held CONCURRENTLY during that one hold, not across separate holds:
///   ⌘ down, ⌘ up (the set empties, judged, and reset), then ⇧ down, ⇧ up is two SEPARATE one-key
///   taps, not one two-modifier refusal -- nothing empties the held set until every physical key
///   involved has actually been released.
public struct HotkeyRecordingSession {
    /// The modifier key codes currently held down, toggled one at a time by ``observe(_:)``.
    private var currentlyDown: Set<UInt16> = []

    /// Every modifier key code that has been down at any point since `currentlyDown` was last
    /// empty. Kept apart from `currentlyDown` because the chord-vs-tap decision below needs "how
    /// many DISTINCT keys were held concurrently during THIS hold", not "how many are down right
    /// now" -- reset the moment `currentlyDown` empties, so a later, separate hold starts counting
    /// again from zero (the type's own note on ⌘-then-⇧ as two taps, not one refusal).
    private var everSeen: Set<UInt16> = []

    public init() {}

    /// Feeds one captured event and returns what the recording should do next.
    public mutating func observe(_ event: CapturedKeyEvent) -> HotkeyRecordingOutcome {
        switch event {
        case .keyDown:
            // A keyDown always ends the interaction -- see the type's own note -- so whatever was
            // being tracked about a modifier-only attempt no longer applies to what comes next.
            currentlyDown.removeAll()
            everSeen.removeAll()
            return HotkeyRecording.evaluate(event)

        case .flagsChanged(let keyCode, _):
            if currentlyDown.contains(keyCode) {
                currentlyDown.remove(keyCode)
            } else {
                currentlyDown.insert(keyCode)
                everSeen.insert(keyCode)
            }

            // Still held -- more modifiers may yet join, or a key may yet come down. Nothing to
            // decide until the physical keys are all back up.
            guard currentlyDown.isEmpty else { return .stillPressing }

            defer { everSeen.removeAll() }
            if everSeen.count == 1, let onlyKey = everSeen.first {
                // Caps Lock (57) reports `.flagsChanged` like a modifier, but it is a TOGGLE, not
                // a momentary press -- what this session just saw as "held then released" was
                // physically one press that latched the light on, not a tap Murmure can bind the
                // same way it binds ⌘ or ⌥. Named here rather than left to fall into the generic
                // refusal below, which talks about "holding", a description Caps Lock does not fit.
                if onlyKey == 57 {
                    return .refused(
                        "Caps Lock can't be the shortcut -- it toggles instead of being held down.")
                }
                if KeyCombo.modifierKeyCodes.contains(UInt32(onlyKey)) {
                    return .accepted(KeyCombo(keyCode: UInt32(onlyKey), carbonModifiers: 0))
                }
            }
            return .refused(
                "Hold one modifier alone, or add a key to the ones you are holding.")
        }
    }
}
