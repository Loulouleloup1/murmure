import XCTest
@testable import MurmureCore

final class KeyComboTests: XCTestCase {
    func testDefaultToggleIsOptionSpace() {
        XCTAssertEqual(KeyCombo.defaultToggle.keyCode, 49) // kVK_Space
        XCTAssertEqual(KeyCombo.defaultToggle.carbonModifiers, 2048) // optionKey
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(KeyCombo.defaultToggle)
        let back = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(back, KeyCombo.defaultToggle)
    }

    // MARK: - Modifier-only bindings

    /// A JSON blob shaped exactly like one `AppSettings.toggleHotkey` would have written before
    /// this feature existed -- the format did not change (no third field, no `kind` case), so a
    /// domain untouched by a rebind must still decode into the combo it always meant.
    func testOldFormatJSONStillDecodes() throws {
        let oldFormatJSON = Data(#"{"keyCode":49,"carbonModifiers":2048}"#.utf8)
        let combo = try JSONDecoder().decode(KeyCombo.self, from: oldFormatJSON)
        XCTAssertEqual(combo, KeyCombo.defaultToggle)
    }

    /// The new shape -- carbonModifiers 0, a modifier key code -- round-trips through the exact
    /// same Codable conformance as the old one, because it is the same two fields.
    func testModifierOnlyComboRoundTripsThroughJSON() throws {
        let rightOption = KeyCombo(keyCode: 61, carbonModifiers: 0) // kVK_RightOption
        let data = try JSONEncoder().encode(rightOption)
        let back = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(back, rightOption)
        XCTAssertTrue(back.isModifierOnly)
    }

    /// `carbonModifiers == 0` alone is not enough -- a bare function key is also stored that way,
    /// and the two must not be confused.
    func testIsModifierOnlyDistinguishesFromABareFunctionKey() {
        XCTAssertTrue(KeyCombo(keyCode: 61, carbonModifiers: 0).isModifierOnly) // right-⌥
        XCTAssertFalse(KeyCombo(keyCode: 122, carbonModifiers: 0).isModifierOnly) // bare F1
        XCTAssertFalse(KeyCombo.defaultToggle.isModifierOnly) // ⌥Space, a real chord
    }

    // MARK: - Left-hand modifiers

    /// The four keys General warns about, and only those four.
    func testIsLeftHandModifierOnlyIsTrueForExactlyTheLeftHandFour() {
        let leftHand: [UInt32] = [55, 56, 58, 59] // ⌘ ⇧ ⌥ ⌃, left
        let notLeftHand: [UInt32] = [54, 60, 61, 62, 63] // ⌘ ⇧ ⌥ ⌃ right, and fn

        for code in leftHand {
            XCTAssertTrue(
                KeyCombo(keyCode: code, carbonModifiers: 0).isLeftHandModifierOnly,
                "key \(code) should read as left-hand")
        }
        for code in notLeftHand {
            XCTAssertFalse(
                KeyCombo(keyCode: code, carbonModifiers: 0).isLeftHandModifierOnly,
                "key \(code) should not read as left-hand")
        }
    }

    /// A chord that happens to use the left ⌘'s key code as its non-modifier key is not a
    /// modifier-only binding at all, so it must not read as left-hand either.
    func testIsLeftHandModifierOnlyIsFalseForAChord() {
        XCTAssertFalse(KeyCombo.defaultToggle.isLeftHandModifierOnly) // ⌥Space
    }

    // MARK: - carbonModifierMask(fromAppKitModifierFlags:)

    /// `NSEvent.ModifierFlags`' own raw values, spelled out rather than imported -- this package
    /// has no AppKit import, and the point of this file is to prove the conversion against the
    /// real numbers rather than against a second copy of them.
    private enum AppKitModifierFlag {
        static let capsLock: UInt = 0x0001_0000 // NSEvent.ModifierFlags.capsLock, 1 << 16
        static let shift: UInt = 0x0002_0000 // NSEvent.ModifierFlags.shift, 1 << 17
        static let control: UInt = 0x0004_0000 // NSEvent.ModifierFlags.control, 1 << 18
        static let option: UInt = 0x0008_0000 // NSEvent.ModifierFlags.option, 1 << 19
        static let command: UInt = 0x0010_0000 // NSEvent.ModifierFlags.command, 1 << 20
        static let numericPad: UInt = 0x0020_0000 // NSEvent.ModifierFlags.numericPad, 1 << 21
        static let help: UInt = 0x0040_0000 // NSEvent.ModifierFlags.help, 1 << 22
        static let function: UInt = 0x0080_0000 // NSEvent.ModifierFlags.function, 1 << 23
        // A device-dependent left/right bit, e.g. NX_DEVICELSHIFTKEYMASK -- lives in the low
        // half of the word, which `deviceIndependentFlagsMask` (0xFFFF0000) masks off.
        static let deviceLeftShift: UInt = 0x0000_0002
    }

    func testEachAppKitModifierMapsToItsOwnCarbonBit() {
        XCTAssertEqual(
            KeyCombo.carbonModifierMask(fromAppKitModifierFlags: AppKitModifierFlag.control), 4096
        ) // controlKey
        XCTAssertEqual(
            KeyCombo.carbonModifierMask(fromAppKitModifierFlags: AppKitModifierFlag.option), 2048
        ) // optionKey
        XCTAssertEqual(
            KeyCombo.carbonModifierMask(fromAppKitModifierFlags: AppKitModifierFlag.shift), 512
        ) // shiftKey
        XCTAssertEqual(
            KeyCombo.carbonModifierMask(fromAppKitModifierFlags: AppKitModifierFlag.command), 256
        ) // cmdKey
    }

    func testCombinedModifiersCombineTheirCarbonBits() {
        let rawValue = AppKitModifierFlag.option | AppKitModifierFlag.shift
        XCTAssertEqual(KeyCombo.carbonModifierMask(fromAppKitModifierFlags: rawValue), 2048 | 512)
    }

    /// The bug this guards against: one of these bits set alongside real modifiers must not
    /// silently disappear, and none of them alone must read as a Carbon modifier.
    func testCapsLockNumericPadHelpAndFunctionContributeNoCarbonBit() {
        let rawValue = AppKitModifierFlag.capsLock | AppKitModifierFlag.numericPad
            | AppKitModifierFlag.help | AppKitModifierFlag.function
        XCTAssertEqual(KeyCombo.carbonModifierMask(fromAppKitModifierFlags: rawValue), 0)
    }

    /// The failure this exists for: a left/right device bit read as though it were a real
    /// modifier would make a combo that looks bound but that `RegisterEventHotKey` never sees.
    func testDeviceDependentBitsAreMaskedOff() {
        let rawValue = AppKitModifierFlag.deviceLeftShift
        XCTAssertEqual(KeyCombo.carbonModifierMask(fromAppKitModifierFlags: rawValue), 0)
    }

    func testNoModifiersProducesNoCarbonBits() {
        XCTAssertEqual(KeyCombo.carbonModifierMask(fromAppKitModifierFlags: 0), 0)
    }
}
