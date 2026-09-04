import XCTest
@testable import MurmureCore

final class HotkeyRecordingTests: XCTestCase {
    /// AppKit's own raw value for a single modifier, spelled out for the reason `KeyComboTests`
    /// spells the same numbers out: this package has no AppKit import to name them from.
    private enum AppKitModifierFlag {
        static let shift: UInt = 0x0002_0000
        static let control: UInt = 0x0004_0000
        static let option: UInt = 0x0008_0000
        static let command: UInt = 0x0010_0000
    }

    // MARK: - Modifier-only presses

    func testAFlagsChangedEventIsStillPressing() {
        let outcome = HotkeyRecording.evaluate(
            .flagsChanged(appKitModifierFlags: AppKitModifierFlag.option))
        XCTAssertEqual(outcome, .stillPressing)
    }

    func testAFlagsChangedEventWithNoModifierHeldIsStillStillPressing() {
        // A modifier released back to nothing is still "no key yet", not a refusal.
        let outcome = HotkeyRecording.evaluate(.flagsChanged(appKitModifierFlags: 0))
        XCTAssertEqual(outcome, .stillPressing)
    }

    // MARK: - Escape

    func testBareEscapeIsRefused() {
        let outcome = HotkeyRecording.evaluate(
            .keyDown(keyCode: 53, appKitModifierFlags: 0)) // kVK_Escape
        guard case .refused = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
    }

    func testModifiedEscapeIsAlsoRefused() {
        let outcome = HotkeyRecording.evaluate(
            .keyDown(keyCode: 53, appKitModifierFlags: AppKitModifierFlag.command))
        guard case .refused = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
    }

    // MARK: - Bare keys

    func testABareOrdinaryKeyIsRefused() {
        // kVK_ANSI_A, no modifier: binding this would steal the letter from every application.
        let outcome = HotkeyRecording.evaluate(.keyDown(keyCode: 0, appKitModifierFlags: 0))
        guard case .refused = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
    }

    func testABareFunctionKeyIsAccepted() {
        // kVK_F1
        let outcome = HotkeyRecording.evaluate(.keyDown(keyCode: 122, appKitModifierFlags: 0))
        XCTAssertEqual(outcome, .accepted(KeyCombo(keyCode: 122, carbonModifiers: 0)))
    }

    func testEveryNamedFunctionKeyIsBindableBare() {
        // kVK_F1...kVK_F12, Keycap's own table.
        let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for code in functionKeyCodes {
            let outcome = HotkeyRecording.evaluate(.keyDown(keyCode: code, appKitModifierFlags: 0))
            guard case .accepted = outcome else {
                return XCTFail("F-key \(code) was refused bare: \(outcome)")
            }
        }
    }

    // MARK: - Modified keys

    func testAModifiedOrdinaryKeyIsAccepted() {
        // ⌥Space -- KeyCombo.defaultToggle itself.
        let outcome = HotkeyRecording.evaluate(
            .keyDown(keyCode: 49, appKitModifierFlags: AppKitModifierFlag.option))
        XCTAssertEqual(outcome, .accepted(.defaultToggle))
    }

    func testMultipleModifiersAreCombinedIntoOneCombo() {
        let rawValue = AppKitModifierFlag.control | AppKitModifierFlag.shift
        let outcome = HotkeyRecording.evaluate(.keyDown(keyCode: 0, appKitModifierFlags: rawValue))
        XCTAssertEqual(outcome, .accepted(KeyCombo(keyCode: 0, carbonModifiers: 4096 | 512)))
    }

    func testAModifiedFunctionKeyIsAlsoAccepted() {
        let outcome = HotkeyRecording.evaluate(
            .keyDown(keyCode: 122, appKitModifierFlags: AppKitModifierFlag.command))
        XCTAssertEqual(outcome, .accepted(KeyCombo(keyCode: 122, carbonModifiers: 256)))
    }
}
