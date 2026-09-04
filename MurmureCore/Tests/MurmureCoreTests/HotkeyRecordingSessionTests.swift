import XCTest
@testable import MurmureCore

/// `HotkeyRecordingSession` tells a modifier tapped alone apart from a chord attempt across more
/// than one event -- the state `HotkeyRecording.evaluate` itself cannot hold, by design (its own
/// note). These tests drive it the way `GeneralPaneModel` and `HotkeyManager` actually do: one
/// `observe(_:)` call per captured event, in sequence.
final class HotkeyRecordingSessionTests: XCTestCase {
    /// AppKit's own raw value for a single modifier, spelled out for the reason `KeyComboTests`
    /// spells the same numbers out: this package has no AppKit import to name them from.
    private enum AppKitModifierFlag {
        static let shift: UInt = 0x0002_0000
        static let command: UInt = 0x0010_0000
    }

    // MARK: - A modifier-only tap

    /// Right-⌥, down then up, nothing else pressed -- Superwhisper's own signature gesture.
    func testRightOptionTapIsAccepted() {
        var session = HotkeyRecordingSession()
        // kVK_RightOption down.
        XCTAssertEqual(
            session.observe(.flagsChanged(keyCode: 61, appKitModifierFlags: 0)), .stillPressing)
        // kVK_RightOption up -- the held set empties, and only one key was ever involved.
        let outcome = session.observe(.flagsChanged(keyCode: 61, appKitModifierFlags: 0))
        XCTAssertEqual(outcome, .accepted(KeyCombo(keyCode: 61, carbonModifiers: 0)))
    }

    /// fn IS a real class in the AppKit mask (`.function`, tested in `KeyComboTests`), but this
    /// session still decides by key code alone, same as every other modifier here.
    func testFnTapIsAccepted() {
        var session = HotkeyRecordingSession()
        _ = session.observe(.flagsChanged(keyCode: 63, appKitModifierFlags: 0)) // kVK_Function down
        let outcome = session.observe(.flagsChanged(keyCode: 63, appKitModifierFlags: 0)) // up
        XCTAssertEqual(outcome, .accepted(KeyCombo(keyCode: 63, carbonModifiers: 0)))
    }

    // MARK: - A chord, not a tap

    /// ⌘ held, then C pressed: a keyDown always ends the interaction and hands to
    /// `HotkeyRecording.evaluate`'s existing chord rule -- this is ⌘C, not a tap.
    func testCommandThenCIsAChordNotATap() {
        var session = HotkeyRecordingSession()
        XCTAssertEqual(
            session.observe(
                .flagsChanged(keyCode: 55, appKitModifierFlags: AppKitModifierFlag.command)),
            .stillPressing) // kVK_Command down
        let outcome = session.observe(
            .keyDown(keyCode: 8, appKitModifierFlags: AppKitModifierFlag.command)) // kVK_ANSI_C
        XCTAssertEqual(outcome, .accepted(KeyCombo(keyCode: 8, carbonModifiers: 256)))
    }

    // MARK: - Two modifiers, no key

    /// ⌘ down, ⇧ down, both up, no key ever pressed: two distinct modifiers were involved, so
    /// this is a chord attempt that never finished, not a tap for either one.
    func testCommandThenShiftReleasedWithNoKeyIsRefused() {
        var session = HotkeyRecordingSession()
        _ = session.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: AppKitModifierFlag.command)) // ⌘ down
        _ = session.observe(
            .flagsChanged(
                keyCode: 56,
                appKitModifierFlags: AppKitModifierFlag.command | AppKitModifierFlag.shift)
        ) // ⇧ down, ⌘ still held
        _ = session.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: AppKitModifierFlag.shift)) // ⌘ up
        let outcome = session.observe(.flagsChanged(keyCode: 56, appKitModifierFlags: 0)) // ⇧ up

        XCTAssertEqual(
            outcome,
            .refused("Hold one modifier alone, or add a key to the ones you are holding."))
    }

    /// ⌘ tapped and released, THEN ⇧ tapped: the two are never held together, so ⌘'s own tap
    /// completes and resets the session before ⇧ is ever touched -- two SEPARATE taps, each
    /// judged on its own, not one chord attempt spanning both.
    func testTwoSequentialTapsWithNoOverlapAreEachJudgedOnTheirOwn() {
        var session = HotkeyRecordingSession()
        _ = session.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: AppKitModifierFlag.command)) // ⌘ down
        _ = session.observe(.flagsChanged(keyCode: 55, appKitModifierFlags: 0)) // ⌘ up
        _ = session.observe(
            .flagsChanged(keyCode: 56, appKitModifierFlags: AppKitModifierFlag.shift)) // ⇧ down

        // ⌘'s own down-then-up already completed and reset the session (only one key was
        // involved in THAT hold), so this second tap is judged on its own -- and accepted.
        let outcome = session.observe(.flagsChanged(keyCode: 56, appKitModifierFlags: 0)) // ⇧ up
        XCTAssertEqual(outcome, .accepted(KeyCombo(keyCode: 56, carbonModifiers: 0)))
    }

    // MARK: - Caps Lock

    /// Caps Lock (57) reports `.flagsChanged` like a modifier, but is a TOGGLE, not a momentary
    /// press -- refused with a sentence naming that, not the generic "hold one modifier" one.
    func testCapsLockAloneGetsItsOwnRefusal() {
        var session = HotkeyRecordingSession()
        _ = session.observe(.flagsChanged(keyCode: 57, appKitModifierFlags: 0)) // Caps Lock down
        let outcome = session.observe(.flagsChanged(keyCode: 57, appKitModifierFlags: 0)) // up
        XCTAssertEqual(
            outcome,
            .refused("Caps Lock can't be the shortcut -- it toggles instead of being held down."))
    }

    // MARK: - Escape

    /// Escape is refused whatever the session was doing -- a keyDown is always final and always
    /// goes through `HotkeyRecording.evaluate`'s own Escape rule.
    func testEscapeIsStillRefused() {
        var session = HotkeyRecordingSession()
        let outcome = session.observe(.keyDown(keyCode: 53, appKitModifierFlags: 0)) // kVK_Escape
        guard case .refused = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
    }
}
