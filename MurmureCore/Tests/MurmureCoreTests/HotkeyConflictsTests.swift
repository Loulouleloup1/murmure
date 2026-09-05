import XCTest
@testable import MurmureCore

final class HotkeyConflictsTests: XCTestCase {
    private let toggle = KeyCombo.defaultToggle // ⌥Space
    private let optionP = KeyCombo(keyCode: 35, carbonModifiers: 2048) // ⌥P
    private let optionR = KeyCombo(keyCode: 15, carbonModifiers: 2048) // ⌥R
    private let rightOption = KeyCombo(keyCode: 61, carbonModifiers: 0) // modifier-only tap

    private func hotkey(_ key: String, _ name: String, _ combo: KeyCombo) -> HotkeyAssignments.ModeHotkey {
        HotkeyAssignments.ModeHotkey(key: key, name: name, hotkey: combo)
    }

    // MARK: - No clash

    func testNoClashesRegistersEveryBindingAndReportsNothing() {
        let modes = [hotkey("prompt", "Prompt", optionP), hotkey("voice", "Voice", rightOption)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.bindings.count, 3)
        XCTAssertTrue(result.bindings.contains(HotkeyAssignment(id: .toggle, combo: toggle)))
        XCTAssertTrue(result.bindings.contains(HotkeyAssignment(id: .mode("prompt"), combo: optionP)))
        XCTAssertTrue(result.bindings.contains(HotkeyAssignment(id: .mode("voice"), combo: rightOption)))
        XCTAssertEqual(result.conflicts, [])
    }

    // MARK: - Mode vs mode

    /// The literal example from the spec: two modes sharing ⌥P, resolved deterministically and
    /// worded exactly this way.
    func testTwoModesOnTheSameComboTheAlphabeticallyLastKeyWinsAndIsNamed() {
        let modes = [hotkey("prompt", "Prompt", optionP), hotkey("voice", "Voice", optionP)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.bindings, [
            HotkeyAssignment(id: .toggle, combo: toggle),
            HotkeyAssignment(id: .mode("voice"), combo: optionP),
        ])
        XCTAssertEqual(result.conflicts, [
            HotkeyConflict(
                winner: .mode("voice"), loser: .mode("prompt"),
                message: "Prompt and Voice both use ⌥P — only one can win; Voice keeps it."),
        ])
    }

    /// The tie-break does not depend on input order -- the same two modes, listed the other way
    /// round, resolve to the same winner.
    func testTieBreakIsOrderIndependent() {
        let forwards = HotkeyAssignments.resolve(
            toggle: toggle, modes: [hotkey("prompt", "Prompt", optionP), hotkey("voice", "Voice", optionP)])
        let backwards = HotkeyAssignments.resolve(
            toggle: toggle, modes: [hotkey("voice", "Voice", optionP), hotkey("prompt", "Prompt", optionP)])

        XCTAssertEqual(forwards.bindings, backwards.bindings)
        XCTAssertEqual(forwards.conflicts, backwards.conflicts)
    }

    /// Three modes on one combo: one winner, and one conflict per loser -- not one conflict for
    /// the whole group.
    func testThreeWayTieProducesOneConflictPerLoser() {
        let modes = [
            hotkey("prompt", "Prompt", optionP),
            hotkey("voice", "Voice", optionP),
            hotkey("email", "Email", optionP),
        ]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.bindings.filter { $0.id != .toggle }, [
            HotkeyAssignment(id: .mode("voice"), combo: optionP),
        ])
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertEqual(Set(result.conflicts.map(\.loser)), Set([.mode("prompt"), .mode("email")]))
        XCTAssertTrue(result.conflicts.allSatisfy { $0.winner == .mode("voice") })
    }

    // MARK: - Mode vs toggle

    func testAModeCombinationEqualToTheToggleLosesToTheToggle() {
        let modes = [hotkey("prompt", "Prompt", toggle)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.bindings, [HotkeyAssignment(id: .toggle, combo: toggle)])
        XCTAssertEqual(result.conflicts, [
            HotkeyConflict(
                winner: .toggle, loser: .mode("prompt"),
                message: "Prompt and the dictation shortcut both use ⌥Space "
                    + "— only one can win; the dictation shortcut keeps it."),
        ])
    }

    /// The toggle wins even against the mode that would otherwise win a mode-only tie -- proves
    /// the two rules are checked in order, not just that the toggle happens to appear first.
    func testToggleWinsEvenOverTheModeThatWouldWinAMovesOnlyTie() {
        let modes = [hotkey("prompt", "Prompt", toggle), hotkey("zulu", "Zulu", toggle)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.bindings, [HotkeyAssignment(id: .toggle, combo: toggle)])
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertTrue(result.conflicts.allSatisfy { $0.winner == .toggle })
    }

    // MARK: - A mode hotkey `HotkeyRecording` would refuse

    /// The only way to set a mode's `hotkey` today is hand-editing its JSON file -- there is no
    /// recorder in front of it yet -- so a bare Escape written there must be refused HERE, or it
    /// reaches `HotkeyManager` as a permanent global chord fighting `CancelHotkey` for the same key
    /// on every recording.
    func testAModeHotkeyThatIsEscapeIsRefusedNotRegistered() {
        let modes = [hotkey("prompt", "Prompt", KeyCombo.cancelRecording)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertFalse(result.bindings.contains { $0.id == .mode("prompt") })
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.refusals, [
            HotkeyRefusal(
                id: .mode("prompt"),
                message: "Prompt: Escape can't be the shortcut -- it already cancels a recording "
                    + "in progress."),
        ])
    }

    /// A refused mode hotkey never enters the contest at all -- it must not shadow, or be shadowed
    /// by, another binding that happens to want the exact same (illegal) combo.
    func testARefusedModeHotkeyDoesNotParticipateInAnyConflict() {
        let modes = [
            hotkey("prompt", "Prompt", KeyCombo.cancelRecording),
            hotkey("voice", "Voice", KeyCombo.cancelRecording),
        ]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.refusals.count, 2)
        XCTAssertEqual(Set(result.refusals.map(\.id)), Set([.mode("prompt"), .mode("voice")]))
    }

    /// A bare, non-function, non-modifier-only key is refused the same way -- not only Escape.
    func testABareOrdinaryKeyIsAlsoRefused() {
        let bareA = KeyCombo(keyCode: 0, carbonModifiers: 0) // 'A', no modifier
        let modes = [hotkey("prompt", "Prompt", bareA)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertFalse(result.bindings.contains { $0.id == .mode("prompt") })
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertTrue(result.refusals[0].message.hasPrefix("Prompt:"))
    }

    /// A modifier-only combo is legal, unlike a bare ordinary key -- `wouldRefuse` must not confuse
    /// the two just because both have `carbonModifiers == 0`.
    func testAModifierOnlyModeHotkeyIsNotRefused() {
        let modes = [hotkey("prompt", "Prompt", rightOption)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.refusals, [])
        XCTAssertTrue(result.bindings.contains(HotkeyAssignment(id: .mode("prompt"), combo: rightOption)))
    }

    // MARK: - No modes, or a mode with no hotkey

    func testNoModesResolvesToOnlyTheToggle() {
        let result = HotkeyAssignments.resolve(toggle: toggle, modes: [])

        XCTAssertEqual(result.bindings, [HotkeyAssignment(id: .toggle, combo: toggle)])
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.refusals, [])
    }

    /// A mode with no `hotkey` at all is silence, not a refusal: nothing was ever attempted.
    func testAModeWithNoHotkeyIsSkippedRatherThanRefused() {
        let modes = [HotkeyAssignments.ModeHotkey(key: "prompt", name: "Prompt", hotkey: nil)]

        let result = HotkeyAssignments.resolve(toggle: toggle, modes: modes)

        XCTAssertEqual(result.bindings, [HotkeyAssignment(id: .toggle, combo: toggle)])
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.refusals, [])
    }
}
