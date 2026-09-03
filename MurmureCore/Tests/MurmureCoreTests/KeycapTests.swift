import XCTest
@testable import MurmureCore

/// A shortcut comes out as one chip per key, in the order macOS writes them.
final class KeycapTests: XCTestCase {
    // MARK: - The default toggle

    /// The shortcut Louis actually presses, and the shape the whole type exists for: ⌥Space is
    /// TWO objects, one square and one wide, not the string `"⌥Space"`.
    func testTheDefaultToggleIsTwoChipsAGlyphThenAWord() {
        // When
        let chips = KeyCombo.defaultToggle.keycaps

        // Then
        XCTAssertEqual(chips.count, 2)
        XCTAssertEqual(chips[0], Keycap("⌥"))
        XCTAssertEqual(chips[0].shape, .glyph)
        XCTAssertEqual(chips[1], Keycap("Space"))
        XCTAssertEqual(chips[1].shape, .word)
    }

    /// Escape, bare -- `CancelHotkey`'s binding. A combination with no modifiers is one chip, not
    /// one chip and an empty one.
    func testABareKeyIsOneChip() {
        XCTAssertEqual(KeyCombo.cancelRecording.keycaps, [Keycap("Escape")])
    }

    // MARK: - Modifier order

    /// ⌃⌥⇧⌘, which is what every menu and every shortcut pane on the system draws. The bit values
    /// run the other way -- `cmdKey` is 256 and `controlKey` is 4096 -- so a renderer that walked
    /// the mask would produce ⌘⇧⌥⌃ and a shortcut Louis has to read twice to recognise.
    func testModifiersComeOutInTheOrderMacOSDrawsThem() {
        // Given -- all four set, and the key last
        let combo = KeyCombo(keyCode: 40, carbonModifiers: 256 + 512 + 2048 + 4096)

        // When
        let labels = combo.keycaps.map(\.label)

        // Then
        XCTAssertEqual(labels, ["⌃", "⌥", "⇧", "⌘", "K"])
    }

    /// The same four modifiers, built up in the opposite order to the one they are drawn in. The
    /// mask is a set of bits and carries no order of its own, so this is the assertion that the
    /// order above comes from the display rule and not from how the number was assembled.
    func testTheOrderIsNotTheOrderTheBitsWereSetIn() {
        let combo = KeyCombo(keyCode: 40, carbonModifiers: 4096 | 2048 | 512 | 256)
        XCTAssertEqual(combo.keycaps.map(\.label), ["⌃", "⌥", "⇧", "⌘", "K"])
    }

    /// Superwhisper's own mode switcher (design notes §4), as a shortcut Murmure could be asked
    /// to draw tomorrow: only the modifiers that are actually held get a chip.
    func testOnlyTheModifiersThatAreSetGetAChip() {
        // Given -- ⌥⇧K
        let combo = KeyCombo(keyCode: 40, carbonModifiers: 2048 + 512)

        // Then
        XCTAssertEqual(combo.keycaps.map(\.label), ["⌥", "⇧", "K"])
    }

    // MARK: - The two widths

    /// The invariant the whole layout rests on: a chip is a glyph if and only if what is written
    /// on it is one character. A word marked as a glyph is a word squeezed into an 18 pt square.
    func testAChipIsAGlyphExactlyWhenItsLabelIsOneCharacter() {
        let combos = [
            KeyCombo.defaultToggle,
            KeyCombo.cancelRecording,
            KeyCombo(keyCode: 122, carbonModifiers: 256),  // ⌘F1
            KeyCombo(keyCode: 123, carbonModifiers: 4096),  // ⌃←
            KeyCombo(keyCode: 116, carbonModifiers: 2048),  // ⌥Page Up
        ]

        for chip in combos.flatMap(\.keycaps) {
            switch chip.shape {
            case .glyph: XCTAssertEqual(chip.label.count, 1, "\(chip.label) is not one character")
            case .word: XCTAssertGreaterThan(chip.label.count, 1, "\(chip.label) is one character")
            }
        }
    }

    /// An arrow is a glyph and not the word `Left`: it is one character, so it belongs in the
    /// square chip beside ⌘ rather than in a wide one.
    func testTheArrowsAreGlyphs() {
        for keyCode in [UInt32(123), 124, 125, 126] {
            let chip = KeyCombo(keyCode: keyCode, carbonModifiers: 0).keycaps[0]
            XCTAssertEqual(chip.shape, .glyph, "key \(keyCode)")
        }
        let labels = [123, 124, 125, 126].map {
            KeyCombo(keyCode: UInt32($0), carbonModifiers: 0).keycaps[0].label
        }
        XCTAssertEqual(labels, ["←", "→", "↓", "↑"])
    }

    /// A function key needs the wide chip even though it is short. This is why the shape is read
    /// off the label rather than off "is it a letter".
    func testAFunctionKeyIsAWordChip() {
        XCTAssertEqual(KeyCombo(keyCode: 111, carbonModifiers: 0).keycaps, [Keycap("F12")])
    }

    /// Measured off the installed app: a glyph chip is square, and every chip shares one height
    /// so a row of them has one baseline.
    func testAGlyphChipIsSquare() {
        XCTAssertEqual(Keycap.glyphWidth, Keycap.height)
    }

    // MARK: - Keys with no name

    /// A key code the table does not know still produces a visible chip. A shortcut that rendered
    /// as its modifiers alone would read as a modifier-only binding -- which is a real feature on
    /// the app next door -- so the failure has to look like a failure, with the number in it.
    func testAnUnknownKeyStillGetsAChipWithItsCodeInIt() {
        // Given -- 10 is ISO_Section, absent from the table
        let combo = KeyCombo(keyCode: 10, carbonModifiers: 2048)

        // When
        let chips = combo.keycaps

        // Then
        XCTAssertEqual(chips.count, 2)
        XCTAssertEqual(chips[1].shape, .word)
        XCTAssertTrue(chips[1].label.contains("10"), chips[1].label)
    }

    // MARK: - The table itself

    /// Two keys wearing one label is the bug that cannot be seen: the chip is right, the shortcut
    /// it names is not. Letters and digits are what a hotkey recorder will produce most of.
    func testNoTwoKeysWearTheSameLabel() {
        // Given -- every code a `RegisterEventHotKey` binding can plausibly carry
        let labels = (UInt32(0)...126)
            .map { KeyCombo(keyCode: $0, carbonModifiers: 0).keycaps[0].label }
            .filter { !$0.hasPrefix("Key ") }

        // Then
        XCTAssertEqual(Set(labels).count, labels.count)
    }
}
