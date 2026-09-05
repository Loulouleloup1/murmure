import XCTest
@testable import MurmureCore

/// A new file rather than an addition to `HotkeyConflictsTests.swift` -- that file belongs to the
/// lot that shipped `HotkeyAssignments.resolve` and is left untouched; ``HotkeyAssignments
/// .substituting(_:in:previousKey:)`` is a separate, self-contained function this lot adds.
final class HotkeyAssignmentsSubstitutingTests: XCTestCase {
    private let rightOption = KeyCombo(keyCode: 61, carbonModifiers: 0)
    private let optionP = KeyCombo(keyCode: 35, carbonModifiers: 2048)

    private func hotkey(_ key: String, _ name: String, _ combo: KeyCombo?) -> HotkeyAssignments.ModeHotkey {
        HotkeyAssignments.ModeHotkey(key: key, name: name, hotkey: combo)
    }

    /// The branch that matters most: a mode mid-rename, where `previousKey` (the file name) still
    /// finds the entry to replace even though `name` (the display string) no longer matches it.
    /// Matching by `name` instead -- the mutation this pins -- would miss the entry entirely and
    /// append a duplicate rather than replace it, so `result.count` would read 2, not 1.
    func testReplacesTheEntryNamedByPreviousKeyEvenWhenTheDisplayNameChanged() {
        // Given a mode being edited, mid-rename, with a new combo just typed
        let existing = [hotkey("prompt", "Prompt", nil)]
        let draft = hotkey("prompt", "Prompt (renamed)", rightOption)

        // When substituting it in by its previous key
        let result = HotkeyAssignments.substituting(draft, in: existing, previousKey: "prompt")

        // Then the one entry is replaced, not duplicated
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Prompt (renamed)")
        XCTAssertEqual(result.first?.hotkey, rightOption)
    }

    /// A mode with no file yet has no `previousKey` and therefore nothing to replace.
    func testAppendsWhenThereIsNoPreviousKeyAtAll() {
        // Given a brand new mode being created
        let existing = [hotkey("voice", "Voice", nil)]
        let draft = hotkey("custom", "Custom", optionP)

        // When substituting it in with no previous key
        let result = HotkeyAssignments.substituting(draft, in: existing, previousKey: nil)

        // Then it is appended, and the existing entry is untouched
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.key, "custom")
        XCTAssertEqual(result.first?.key, "voice")
    }

    /// A `previousKey` that names no entry in `modes` -- the key itself changed to something not
    /// yet in the list -- has nothing to replace either, the same as no `previousKey` at all.
    func testAppendsWhenThePreviousKeyIsNotInTheList() {
        // Given a mode whose key just changed, ahead of the list it will appear in after a save
        let existing = [hotkey("voice", "Voice", nil)]
        let draft = hotkey("prompt-2", "Prompt", rightOption)

        // When substituting it in by a previous key nothing in the list carries
        let result = HotkeyAssignments.substituting(draft, in: existing, previousKey: "prompt")

        // Then it is appended rather than dropped or matched to the wrong entry
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.key, "prompt-2")
    }
}
