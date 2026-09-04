import Foundation

/// A global hotkey: Carbon virtual key code + Carbon modifier mask.
///
/// The raw values are Carbon's, not AppKit's: `keyCode` is a `kVK_*` virtual key code and
/// `carbonModifiers` is an `optionKey` / `cmdKey` / `shiftKey` / `controlKey` mask, which is
/// what `RegisterEventHotKey` expects. They are stored as plain numbers so this type stays
/// free of the Carbon import and can be persisted in settings verbatim (spec §5).
public struct KeyCombo: Codable, Equatable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Option+Space -- Murmure's default dictation toggle.
    public static let defaultToggle = KeyCombo(keyCode: 49, carbonModifiers: 2048)

    /// Escape, bare. Abandons the recording in progress, and is registered only for as long as
    /// one is running (`CancelHotkey`).
    public static let cancelRecording = KeyCombo(keyCode: 53, carbonModifiers: 0)

    /// Converts AppKit's `NSEvent.modifierFlags.rawValue` into the Carbon mask ``carbonModifiers``
    /// stores, so a captured keypress (`HotkeyRecording`) can become a `KeyCombo` without this
    /// package importing AppKit -- the same reason `keyCode` and `carbonModifiers` are plain
    /// numbers rather than Carbon types.
    ///
    /// **The two bit layouts do not correspond directly, and converting them by hand is exactly
    /// where a rebind feature binds the wrong shortcut.** Every AppKit literal below is
    /// `NSEvent.ModifierFlags`' own raw value, spelled out because this package has no AppKit
    /// import to name them from -- the same choice `Keycap` already made for the Carbon side.
    ///
    /// **Masked first against the device-independent bits (`0xFFFF0000`).** `NSEvent.modifierFlags`
    /// also carries device-dependent left/right bits in the low half of the word (there to tell
    /// e.g. left Shift from right Shift) and `.capsLock` / `.numericPad` / `.help` / `.function`
    /// in the high half alongside the four this cares about -- none of which `RegisterEventHotKey`
    /// has any notion of. Passing one of those through unmasked would still read as "no modifier"
    /// here, which is what makes a stray bit silent rather than a compile error or a crash.
    public static func carbonModifierMask(fromAppKitModifierFlags rawValue: UInt) -> UInt32 {
        let deviceIndependent = rawValue & 0xFFFF_0000

        var carbon: UInt32 = 0
        if deviceIndependent & 0x0004_0000 != 0 { carbon |= 4096 } // .control -> controlKey
        if deviceIndependent & 0x0008_0000 != 0 { carbon |= 2048 } // .option -> optionKey
        if deviceIndependent & 0x0002_0000 != 0 { carbon |= 512 } // .shift -> shiftKey
        if deviceIndependent & 0x0010_0000 != 0 { carbon |= 256 } // .command -> cmdKey
        return carbon
    }
}
