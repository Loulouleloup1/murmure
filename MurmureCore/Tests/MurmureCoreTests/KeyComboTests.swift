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
