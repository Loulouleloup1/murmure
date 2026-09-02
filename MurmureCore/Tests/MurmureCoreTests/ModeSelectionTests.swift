import XCTest
@testable import MurmureCore

final class ModeSelectionTests: XCTestCase {
    private var problems: [ModeSelectionProblem] = []

    override func setUp() {
        problems = []
    }

    /// A mode is only ever distinguished here by its key and what it claims, so the rest is
    /// borrowed from `Voice` rather than spelled out.
    private func mode(_ key: String, claiming autoActivate: [String] = []) -> Mode {
        var mode = Mode.voice
        mode.key = key
        mode.name = key.capitalized
        mode.autoActivate = autoActivate
        return mode
    }

    private func resolve(
        among modes: [Mode], manualKey: String? = nil, frontmostBundleID: String? = nil
    ) -> Mode {
        ModeSelection.resolve(
            among: modes, manualKey: manualKey, frontmostBundleID: frontmostBundleID,
            report: { self.problems.append($0) })
    }

    // MARK: - The three rules, in order

    func testAModeChosenByHandWinsOverTheOneTheFrontmostAppClaims() {
        let modes = [mode("voice"), mode("prompt", claiming: ["com.apple.Terminal"])]

        let selected = resolve(among: modes, manualKey: "voice",
                               frontmostBundleID: "com.apple.Terminal")

        XCTAssertEqual(selected.key, "voice")
    }

    func testTheModeClaimingTheFrontmostAppWinsOverTheDefault() {
        let modes = [mode("voice"), mode("prompt", claiming: ["com.apple.Terminal"])]

        let selected = resolve(among: modes, frontmostBundleID: "com.apple.Terminal")

        XCTAssertEqual(selected.key, "prompt")
        XCTAssertEqual(problems, [], "one claimant is not a conflict")
    }

    func testAnAppNoModeClaimsFallsBackToVoice() {
        let modes = [mode("voice"), mode("prompt", claiming: ["com.apple.Terminal"])]

        XCTAssertEqual(resolve(among: modes, frontmostBundleID: "com.tinyspeck.slackmacgap").key,
                       "voice")
    }

    /// There is not always a frontmost application -- between two app activations, or with the
    /// Finder's desktop in front, `NSWorkspace` hands back nil. A dictation started then must
    /// still run.
    func testNoFrontmostApplicationFallsBackToVoice() {
        let modes = [mode("voice"), mode("prompt", claiming: ["com.apple.Terminal"])]

        XCTAssertEqual(resolve(among: modes, frontmostBundleID: nil).key, "voice")
    }

    /// The path every dictation takes today: both built-ins ship with an empty `autoActivate`,
    /// because which app should auto-select which mode is a question that has not been answered
    /// yet (spec §5 makes `Voice` the daily driver for Claude Code *and* auto-activates `Prompt`
    /// on the terminal -- both cannot hold).
    func testTheShippedBuiltInsClaimNothingSoEveryAppGetsVoice() {
        for bundleID in ["com.apple.Terminal", "com.googlecode.iterm2", "com.tinyspeck.slackmacgap"] {
            XCTAssertEqual(resolve(among: Mode.builtIns, frontmostBundleID: bundleID).key, "voice",
                           "for \(bundleID)")
        }
        XCTAssertEqual(problems, [])
    }

    // MARK: - Two modes claiming one app

    /// The tie-break exists to be predictable, so it is tested against every order the modes can
    /// arrive in: `loadAll()` orders them by file name today, and nothing should depend on that.
    func testTwoModesClaimingOneAppAlwaysSelectTheSameOne() {
        let modes = [mode("voice"), mode("prompt", claiming: ["com.apple.Terminal"]),
                     mode("custom", claiming: ["com.apple.Terminal"])]

        for order in modes.permutations() {
            XCTAssertEqual(resolve(among: order, frontmostBundleID: "com.apple.Terminal").key,
                           "custom", "for order \(order.map(\.key))")
        }
    }

    func testTwoModesClaimingOneAppIsReportedWithBothKeysAndTheWinner() {
        let modes = [mode("prompt", claiming: ["com.apple.Terminal"]),
                     mode("custom", claiming: ["com.apple.Terminal"]), mode("voice")]

        _ = resolve(among: modes, frontmostBundleID: "com.apple.Terminal")

        XCTAssertEqual(problems, [.autoActivateConflict(bundleID: "com.apple.Terminal",
                                                        claimedBy: ["custom", "prompt"],
                                                        selected: "custom")])
    }

    /// A conflict that never got consulted is not a conflict to raise: the manual selection ended
    /// the resolution before auto-activation was reached.
    func testAConflictIsNotReportedWhenAManualSelectionDecidedIt() {
        let modes = [mode("voice"), mode("prompt", claiming: ["com.apple.Terminal"]),
                     mode("custom", claiming: ["com.apple.Terminal"])]

        _ = resolve(among: modes, manualKey: "voice", frontmostBundleID: "com.apple.Terminal")

        XCTAssertEqual(problems, [])
    }

    // MARK: - Hand-edited files

    /// Selecting `prompt` in the menu and then renaming `prompt.json` leaves a selection pointing
    /// at nothing. Silently running `Voice` under a menu that reads "Prompt" is the one outcome
    /// with no explanation, so it is reported -- and the remaining rules still apply.
    func testAManualSelectionThatNoLongerExistsIsReportedAndTheOtherRulesStillApply() {
        let modes = [mode("voice"), mode("custom", claiming: ["com.apple.Terminal"])]

        let selected = resolve(among: modes, manualKey: "prompt",
                               frontmostBundleID: "com.apple.Terminal")

        XCTAssertEqual(selected.key, "custom")
        XCTAssertEqual(problems, [.unknownManualSelection(key: "prompt")])
    }

    /// The upgrade path off `Message` and `Email`, which this commit stopped shipping.
    ///
    /// A machine with one of them ticked in the menu has a stored preference naming a mode that
    /// is gone. **No code was written for this**: rule 1 already falls through to the remaining
    /// rules and reports the stale key, which is the behaviour the test above pins in general.
    /// This pins it against the two keys that now actually occur, so the upgrade is covered by a
    /// test and not by an argument.
    func testAPreferenceNamingARemovedModeStillLandsOnAShippedMode() {
        for removed in ["message", "email"] {
            problems = []

            let selected = resolve(among: Mode.builtIns, manualKey: removed,
                                   frontmostBundleID: "com.tinyspeck.slackmacgap")

            XCTAssertEqual(selected.key, "voice", removed)
            XCTAssertEqual(problems, [.unknownManualSelection(key: removed)], removed)
        }
    }

    /// `autoActivate` is typed by hand and a bundle id's capitalisation is invisible: an exact
    /// match would turn `com.apple.terminal` into a mode that simply never activates, with
    /// nothing to see.
    func testABundleIdWhoseCaseWasTypedWrongStillMatches() {
        let modes = [mode("voice"), mode("prompt", claiming: ["com.apple.terminal"])]

        XCTAssertEqual(resolve(among: modes, frontmostBundleID: "com.apple.Terminal").key, "prompt")
    }
}

extension Array {
    /// Every ordering of the array, so a test can assert that none of them changes the outcome.
    fileprivate func permutations() -> [[Element]] {
        guard count > 1 else { return [self] }
        return indices.flatMap { index -> [[Element]] in
            var rest = self
            let element = rest.remove(at: index)
            return rest.permutations().map { [element] + $0 }
        }
    }
}
