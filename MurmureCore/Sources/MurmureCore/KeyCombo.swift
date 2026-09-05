import Foundation

/// A global hotkey: Carbon virtual key code + Carbon modifier mask.
///
/// The raw values are Carbon's, not AppKit's: `keyCode` is a `kVK_*` virtual key code and
/// `carbonModifiers` is an `optionKey` / `cmdKey` / `shiftKey` / `controlKey` mask, which is
/// what `RegisterEventHotKey` expects. They are stored as plain numbers so this type stays
/// free of the Carbon import and can be persisted in settings verbatim (spec §5).
public struct KeyCombo: Codable, Equatable, Sendable {
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

    /// The nine physical modifier keys a modifier-only binding can name -- left and right kept
    /// distinct because the gesture this exists for is a SPECIFIC physical key (Superwhisper's
    /// own choice is right-⌥, not either ⌥).
    ///
    /// Read straight from `Events.h` (`Carbon.HIToolbox`) rather than trusted from memory, since
    /// getting one of these wrong silently binds the wrong physical key: `kVK_RightCommand` =
    /// 0x36 (54), `kVK_Command` = 0x37 (55, left), `kVK_Shift` = 0x38 (56, left), `kVK_Option` =
    /// 0x3A (58, left), `kVK_Control` = 0x3B (59, left), `kVK_RightShift` = 0x3C (60),
    /// `kVK_RightOption` = 0x3D (61), `kVK_RightControl` = 0x3E (62), `kVK_Function` = 0x3F (63).
    ///
    /// `kVK_CapsLock` (0x39, 57) is deliberately absent. Every other key here goes down and back
    /// up on its own, which is the whole gesture a modifier-only binding fires on; Caps Lock is a
    /// hardware TOGGLE -- physically down for as long as it is lit, not for as long as it is held
    /// -- so "tap Caps Lock alone" is not a press-and-release anyone's finger ever performs.
    public static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    /// Whether this combo is a modifier-only binding -- one physical modifier key, tapped alone,
    /// with nothing else held.
    ///
    /// **No new stored field, and that is the design.** A modifier-only binding already fits the
    /// two fields this type has always had: `carbonModifiers == 0` (nothing was held down
    /// ALONGSIDE it -- there is no chord) and `keyCode` naming the modifier key itself, which
    /// `RegisterEventHotKey` never sees a code for because Carbon has no way to register one. The
    /// alternative -- an explicit `kind` enum case, or a third stored field -- would be a second
    /// source of truth for something these two already say, and would need its own `Codable`
    /// migration; this needs none, because a JSON blob written by a version of Murmure that
    /// predates this feature decodes exactly as it always did (same two fields, same shape), and
    /// simply never happens to describe a modifier-only combo. The only thing that has to hold
    /// for that to stay unambiguous is that ``modifierKeyCodes`` and ``functionKeyCodes``
    /// (`Keycap`'s bare-key exception) never overlap -- they do not, by construction.
    public var isModifierOnly: Bool {
        carbonModifiers == 0 && Self.modifierKeyCodes.contains(keyCode)
    }

    /// The four LEFT-hand modifier keys, out of ``modifierKeyCodes`` -- `kVK_Command` (55),
    /// `kVK_Shift` (56), `kVK_Option` (58), `kVK_Control` (59). Right-hand ones (54, 60, 61, 62)
    /// and `kVK_Function` (63, no side of its own) are deliberately excluded.
    public static let leftHandModifierKeyCodes: Set<UInt32> = [55, 56, 58, 59]

    /// Whether this is a modifier-only binding on a LEFT-hand key specifically -- the one General
    /// warns about (`GeneralPaneModel.hotkeyNote`).
    ///
    /// **Why the warning exists at all, and why only for these four.** A left-hand modifier is
    /// pressed and released alone constantly during ordinary typing -- ⌘ before every ⌘C, ⇧ before
    /// every capital letter, ⌥ and ⌃ in any number of system chords -- so binding one of them bare
    /// turns Murmure's toggle into something that fires by accident, often. The right-hand pair of
    /// each (and `fn`, which has no pair) is comparatively rare in ordinary two-handed typing --
    /// Superwhisper's own choice of right-⌥ is exactly this reasoning applied once already -- so
    /// there is nothing safer to say about them here.
    public var isLeftHandModifierOnly: Bool {
        isModifierOnly && Self.leftHandModifierKeyCodes.contains(keyCode)
    }

    /// The one sentence to append to a hotkey note when ``isLeftHandModifierOnly`` is true --
    /// shared so `GeneralPaneModel` (the toggle) and `ModesPaneModel` (a mode's own shortcut) show
    /// the identical warning rather than each keeping its own copy of it, which is exactly how the
    /// two could drift to two different wordings for the same rule.
    public static let leftHandModifierWarning =
        "Left-hand modifiers are pressed and released on their own all day; the right-hand key "
            + "is the safer choice."
}
