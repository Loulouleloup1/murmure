import XCTest
@testable import MurmureCore

/// `ModifierTapDetector` is the pure logic behind `HotkeyManager`'s modifier-only firing path --
/// see its own note on why it exists apart from `HotkeyRecordingSession`. These tests drive it
/// exactly the way `HotkeyManager.observeModifierOnlyEvent` does: one `observe(_:elapsedSinceDown:ceiling:)`
/// call per event, in sequence, with an explicit elapsed duration rather than a real clock.
///
/// **`appKitModifierFlags` is not a spare parameter here.** The detector now derives down/up from
/// the target's modifier-CLASS bit on that value (the type's own note explains why), so every
/// event below carries the flag a real `NSEvent` would actually report at that point in the
/// sequence -- `cmdBit` set for as long as ⌘ is physically held, clear the instant it is not --
/// rather than the `0` every event used under the old toggle-based version.
final class ModifierTapDetectorTests: XCTestCase {
    private let target = KeyCombo(keyCode: 55, carbonModifiers: 0) // kVK_Command, left

    private let ceiling: TimeInterval = 0.35

    /// `NSEvent.ModifierFlags.command.rawValue` -- the device-independent bit set in
    /// `appKitModifierFlags` for as long as EITHER physical ⌘ key is held.
    private let cmdBit: UInt = 0x0010_0000

    /// `NSEvent.ModifierFlags.shift.rawValue`, for a second, unrelated modifier.
    private let shiftBit: UInt = 0x0002_0000

    // MARK: - A clean tap

    func testACleanTapFires() {
        var detector = ModifierTapDetector(target: target)
        XCTAssertEqual(
            detector.observe(
                .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
                ceiling: ceiling),
            .notYet) // down
        XCTAssertEqual(
            detector.observe(
                .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.1,
                ceiling: ceiling),
            .fire) // up, 100 ms later
    }

    // MARK: - The bug this exists to fix

    /// ⌘ down at t=0, C down at ~60 ms (a chord, not a tap), ⌘ up at ~200 ms. 200 ms is comfortably
    /// under the 350 ms ceiling -- a ceiling-only detector fires here, which is the exact defect
    /// reported against an earlier version of this file. The keyDown must be what suppresses it.
    func testCommandCTypedQuicklyDoesNotFireEvenWellUnderTheCeiling() {
        var detector = ModifierTapDetector(target: target)
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling
        ) // ⌘ down, t=0
        XCTAssertEqual(
            detector.observe(
                .keyDown(keyCode: 8, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
                ceiling: ceiling
            ), // C down, t=60ms -- kVK_ANSI_C
            .notYet)
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.2,
            ceiling: ceiling) // ⌘ up, t=200ms -- well under the 350ms ceiling
        XCTAssertEqual(outcome, .suppressed)
    }

    // MARK: - Another modifier joining

    /// ⌘ held, ⇧ also held, both released -- two modifiers, no key. The same interruption that
    /// catches a keyDown catches this too: any OTHER key changing while the target is down.
    func testAnotherModifierJoiningAlsoSuppressesTheTap() {
        var detector = ModifierTapDetector(target: target)
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling
        ) // ⌘ down
        _ = detector.observe(
            .flagsChanged(keyCode: 56, appKitModifierFlags: cmdBit | shiftBit),
            elapsedSinceDown: 0, ceiling: ceiling
        ) // ⇧ down too (some other key)
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: shiftBit), elapsedSinceDown: 0.05,
            ceiling: ceiling) // ⌘ up, ⇧ still held
        XCTAssertEqual(outcome, .suppressed)
    }

    // MARK: - The ceiling as a second guard

    /// Nothing at all intervenes, but the hold itself runs past the ceiling -- still suppressed,
    /// because the ceiling is a real second guard, not dead code.
    func testAHoldPastTheCeilingWithNoInterruptionIsStillSuppressed() {
        var detector = ModifierTapDetector(target: target)
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling)
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 2.0,
            ceiling: ceiling) // held two full seconds, nothing else happened
        XCTAssertEqual(outcome, .suppressed)
    }

    // MARK: - Recovery

    /// A suppressed attempt does not poison the next one -- state resets cleanly on every release.
    func testASuppressedTapDoesNotAffectTheNextOne() {
        var detector = ModifierTapDetector(target: target)
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling)
        _ = detector.observe(
            .keyDown(keyCode: 8, appKitModifierFlags: cmdBit), elapsedSinceDown: 0, ceiling: ceiling)
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.1,
            ceiling: ceiling) // suppressed release

        // A fresh, clean tap right after.
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling)
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.1,
            ceiling: ceiling)
        XCTAssertEqual(outcome, .fire)
    }

    /// The dropped-event case MAJOR-1 exists to fix: ⌘ down, then the matching ⌘-up event is lost
    /// entirely (secure input, a hold spanning `register()`, monitor-ordering) -- nothing observes
    /// it. The NEXT event this detector sees for the target key is another physical press, its
    /// `appKitModifierFlags` correctly reporting ⌘ as still down (nothing released it). A
    /// toggle-based detector would read this second `.flagsChanged` as "the up" -- the class bit
    /// itself is enough to recognise it is not: the class bit was already set, and stays set, so
    /// there is no transition to report, and the detector waits for the real release instead of
    /// firing on a key going down.
    func testARecognisedFlagRecoversAfterADroppedEvent() {
        var detector = ModifierTapDetector(target: target)
        XCTAssertEqual(
            detector.observe(
                .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
                ceiling: ceiling),
            .notYet) // ⌘ down -- recorded

        // The matching up event is never delivered. The next thing observed is another down --
        // the class bit is STILL set, so this must not read as a release.
        XCTAssertEqual(
            detector.observe(
                .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0.05,
                ceiling: ceiling),
            .notYet, "a duplicate down must not be read as the up and must not fire")

        // The real release, finally: the class bit clears, and only now does the detector decide.
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.1,
            ceiling: ceiling)
        XCTAssertEqual(outcome, .fire)
    }

    // MARK: - Not our concern

    /// Events for an entirely different key, with the target never held, leave no trace.
    func testEventsForOtherKeysWhileIdleDoNotAffectAFutureTap() {
        var detector = ModifierTapDetector(target: target)
        _ = detector.observe(
            .flagsChanged(keyCode: 56, appKitModifierFlags: shiftBit), elapsedSinceDown: 0,
            ceiling: ceiling
        ) // some other modifier, target never touched
        _ = detector.observe(
            .keyDown(keyCode: 8, appKitModifierFlags: shiftBit), elapsedSinceDown: 0,
            ceiling: ceiling)

        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling
        ) // target down
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.1,
            ceiling: ceiling) // target up, clean
        XCTAssertEqual(outcome, .fire)
    }

    // MARK: - Mouse-down interruption (MINOR-7)

    /// A mouse click held down while the target is pressed is exactly as disqualifying as a
    /// character key going down -- an ⌥-click must not start a dictation.
    func testAMouseDownWhileHeldSuppressesTheTap() {
        var detector = ModifierTapDetector(target: target)
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling) // ⌘ down
        XCTAssertEqual(detector.observeMouseDown(), .notYet)
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.05,
            ceiling: ceiling) // ⌘ up
        XCTAssertEqual(outcome, .suppressed)
    }

    /// A mouse click with the target NOT held is none of this detector's business, and does not
    /// poison a clean tap that follows.
    func testAMouseDownWhileIdleDoesNotAffectAFutureTap() {
        var detector = ModifierTapDetector(target: target)
        XCTAssertEqual(detector.observeMouseDown(), .notYet)
        _ = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: cmdBit), elapsedSinceDown: 0,
            ceiling: ceiling)
        let outcome = detector.observe(
            .flagsChanged(keyCode: 55, appKitModifierFlags: 0), elapsedSinceDown: 0.1,
            ceiling: ceiling)
        XCTAssertEqual(outcome, .fire)
    }
}
