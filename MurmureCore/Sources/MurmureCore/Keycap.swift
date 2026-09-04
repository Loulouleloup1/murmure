import CoreGraphics
import Foundation

/// One key of a shortcut, drawn as its own chip.
///
/// **One chip per key, never a concatenated string** -- design notes §2, and the reason this type
/// exists at all. `"⌥Space"` is one label that happens to contain two keys; `[⌥, Space]` is two
/// objects that can be laid out, spaced and sized as what they are. The distinction is not
/// cosmetic: the notes measure **18 × 18 pt for a single glyph and 30 × 18 pt for `esc`**, so a
/// renderer that cannot tell the two apart either squeezes a word into a square or draws every
/// modifier in a box three times too wide.
///
/// The shape is **derived from the label** rather than stored beside it. A stored one is a second
/// source of truth for something the label already says, and the only way for the two to differ
/// is a mistake -- a one-character label marked as a word draws a wide chip around a ⌘ and
/// nothing tells anybody.
public struct Keycap: Equatable, Sendable {
    /// Which of the two widths the chip is drawn at.
    public enum Shape: Equatable, Sendable {
        /// A single character in a square: the four modifiers, a letter, a digit, an arrow.
        case glyph
        /// A named key -- `Space`, `Return`, `F1`. The chip grows to fit the word.
        case word
    }

    /// What is written on the chip.
    public let label: String

    public var shape: Shape {
        label.count == 1 ? .glyph : .word
    }

    public init(_ label: String) {
        self.label = label
    }

    /// Measured off the installed app (design notes §2): every chip is 18 pt tall, whatever it
    /// says, so a row of them has one baseline.
    public static let height: CGFloat = 18

    /// A glyph chip is square. This is the number that makes ⌃⌥⇧⌘ read as four keys rather than
    /// as a word broken into pieces.
    public static let glyphWidth: CGFloat = 18

    /// What a word chip adds on each side of its text. Derived, not measured directly: `esc` was
    /// measured at 30 pt wide, and `esc` at the caption size the notes report is close to 20 pt
    /// of text, so a word chip is its text plus about 5 pt a side. Word chips size to their
    /// content -- there is no fixed width here, because `Page Down` and `F1` are both word keys.
    public static let wordHorizontalPadding: CGFloat = 5
}

extension KeyCombo {
    /// The shortcut as an ordered row of chips: modifiers first, then the key.
    ///
    /// **The order is the one macOS displays -- ⌃⌥⇧⌘ -- and not the order of the bits.** Every
    /// menu, every key-equivalent and every keyboard shortcut pane on the system draws them that
    /// way, so a settings window that draws ⌘⇧⌥ is a shortcut Louis has to read twice to
    /// recognise as the one he already knows. The bit values happen to run the other way
    /// (`cmdKey` 256 … `controlKey` 4096), which is exactly why iterating the mask would get it
    /// backwards.
    ///
    /// A key code with no name in the table below still produces a chip -- `Key 42` -- rather
    /// than nothing. A hotkey that renders as its modifiers alone looks like a modifier-only
    /// binding, which is a real Superwhisper feature (design notes §4) and would therefore read
    /// as correct; a visibly odd chip is a bug report with the number already in it.
    public var keycaps: [Keycap] {
        Self.modifierGlyphsInDisplayOrder
            .filter { carbonModifiers & $0.mask != 0 }
            .map { Keycap($0.glyph) }
            + [Keycap(Self.label(forKeyCode: keyCode))]
    }

    /// The four modifiers `RegisterEventHotKey` understands, in display order.
    ///
    /// Carbon's own constants, spelled out rather than imported: `KeyCombo` is deliberately free
    /// of the Carbon import (see its own note) and these four numbers have not moved since
    /// `Events.h` was written.
    private static let modifierGlyphsInDisplayOrder: [(mask: UInt32, glyph: String)] = [
        (4096, "⌃"),  // controlKey
        (2048, "⌥"),  // optionKey
        (512, "⇧"),  // shiftKey
        (256, "⌘"),  // cmdKey
    ]

    /// What a key code is called on a chip.
    ///
    /// **Word keys are written as capitalised English words** -- `Space`, `Return`, `Escape` --
    /// and not as the lowercase legend silkscreened on the keyboard, which is what Superwhisper
    /// shows (`esc`, design notes §4). That is their house style, not a measurement of anything
    /// Murmure has to match, and this app already settled the question elsewhere: `WindowSection`
    /// and `StatusPanelText` write English words with a capital. One casing rule everywhere beats
    /// a per-key argument about what Apple engraved.
    ///
    /// The arrows are the exception that proves it: they are named ← ↑ → ↓ because that IS their
    /// name, and one character means one square chip rather than the word `Left`.
    private static func label(forKeyCode keyCode: UInt32) -> String {
        if let named = namedKeys[keyCode] { return named }
        return "Key \(keyCode)"
    }

    /// `kVK_*` virtual key codes -- key POSITIONS, not characters.
    ///
    /// The distinction matters on Louis's keyboard and is not theoretical: the layout is French
    /// AZERTY, so position 12 is engraved `A` there and `Q` on a US board. These labels are the
    /// ANSI legends, which is what every application on macOS shows for a shortcut, and getting
    /// the layout's own characters instead would need `UCKeyTranslate` against the live input
    /// source -- an AppKit call this package cannot make. Named here so the day it matters, it is
    /// a known simplification and not a discovery. (`PasteInserter` did that translation once, by
    /// hand, to prove ⌘V is still Paste on AZERTY.)
    ///
    /// The table stops where a global hotkey stops being plausible: no keypad, because a
    /// `RegisterEventHotKey` binding on the numeric pad is not a thing anybody has asked for, and
    /// an unlisted code renders as `Key <n>` rather than as nothing.
    private static let namedKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
        47: ".", 50: "`",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        // The keypad's Enter, which is a different key from Return and is bindable on its own.
        76: "Enter",
        114: "Help",
        115: "Home",
        116: "Page Up",
        117: "⌦",
        119: "End",
        121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    .merging(functionKeyLabels) { _, new in new }

    /// `kVK_F1` ... `kVK_F12`, split out of ``namedKeys`` rather than inlined there, so
    /// ``functionKeyCodes`` below and ``HotkeyRecording``'s "bindable bare" rule can both be
    /// derived from this ONE table instead of each keeping its own copy of the same twelve
    /// numbers -- the exact drift `ModelInventory.requiredBundles`'s own header describes and was
    /// made public to end.
    private static let functionKeyLabels: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The key codes `HotkeyRecording.evaluate` accepts without a modifier held -- public and no
    /// wider than that: exposing the code/label pairing itself is unneeded outside this file, only
    /// the set of codes is.
    public static let functionKeyCodes: Set<UInt32> = Set(functionKeyLabels.keys)
}
