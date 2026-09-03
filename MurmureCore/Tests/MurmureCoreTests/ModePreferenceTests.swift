import XCTest
@testable import MurmureCore

final class ModePreferenceTests: XCTestCase {
    /// In memory, never a `UserDefaults(suiteName:)`. The suite-per-test pattern this file used
    /// to carry could not be cleaned up: `cfprefsd` owns the domain and flushes an empty plist
    /// back into `~/Library/Preferences` after the `tearDown` has deleted it, which is why 31 of
    /// them were found in Louis's home directory. `EphemeralDefaults` removes the domain from the
    /// picture rather than racing it, so there is nothing to tear down.
    private var defaults: EphemeralDefaults!
    private var directory: URL!

    /// The defaults need no tearing down -- `EphemeralDefaults` registers no domain. The modes
    /// folder still does: it is a real directory, in `NSTemporaryDirectory()`.
    override func setUpWithError() throws {
        defaults = EphemeralDefaults()

        // Same rule for the modes folder as `ModeStoreTests`: a temporary directory, never
        // `~/Library/Application Support/Murmure/modes`.
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModePreferenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The choice itself

    /// The state Murmure ships in: no choice made, so `resolve` is handed nil and the auto-activate
    /// and `Voice` rules decide -- byte for byte what lot 2 did with its hard-coded nil.
    func testNoChoiceYetIsAutomatic() {
        XCTAssertNil(ModePreference(defaults: defaults).selectedKey)
    }

    /// What "remembered across launches" is testable as, in one process: a preference built from
    /// scratch over the same domain reads the choice back. An actual relaunch is not reproducible
    /// here -- what this pins is that the choice lives in the defaults domain and not in the
    /// instance that wrote it.
    func testTheChosenModeIsReadBackByAFreshPreference() throws {
        ModePreference(defaults: defaults).selectedKey = "prompt"

        let reopened = defaults.reopened()
        XCTAssertEqual(ModePreference(defaults: reopened).selectedKey, "prompt")
    }

    /// Going back to automatic is a choice too, not the absence of one, so it has to stick the
    /// same way. A preference that could only ever be set would trap Louis in the last mode he
    /// tried.
    func testGoingBackToAutomaticIsRememberedToo() throws {
        let preference = ModePreference(defaults: defaults)
        preference.selectedKey = "prompt"

        preference.selectedKey = nil

        let reopened = defaults.reopened()
        XCTAssertNil(ModePreference(defaults: reopened).selectedKey)
        // Automatic is the absence of an entry, not an entry holding "". Without this line, a
        // version that stored "" would pass anyway -- the getter reads "" back as nil -- and the
        // two representations would quietly both exist.
        XCTAssertNil(defaults.object(forKey: "selectedModeKey"), "no stale entry left behind")
    }

    /// The literal key is written out here rather than read off the constant, and it is written
    /// with a REAL value: it is the name the choice is filed under, and renaming it forgets the
    /// choice of everyone who had made one. A test that only ever expected nil under this name
    /// would agree with any rename.
    func testTheChoiceIsFiledUnderTheNameItAlreadyHas() {
        defaults.set("prompt", forKey: "selectedModeKey")

        XCTAssertEqual(ModePreference(defaults: defaults).selectedKey, "prompt")
    }

    /// Only reachable through a hand-run `defaults write`; the menu writes a mode key or nothing.
    /// It reads as automatic rather than as a mode, because `ModeSelection` would otherwise report
    /// a mode that does not exist and the menu would warn about a file nobody ever named.
    func testAnEmptyStoredKeyIsReadAsAutomatic() {
        defaults.set("", forKey: "selectedModeKey")

        XCTAssertNil(ModePreference(defaults: defaults).selectedKey)
    }

    // MARK: - The chain the menu drives, minus the menu

    /// The three pieces the app wires together -- what was chosen, what is on disk, which mode
    /// wins. `DictationController` adds only the frontmost application and the hop to `AppState`,
    /// neither of which exists in a test bundle.
    private func resolveAsADictationWould() -> (mode: Mode, problems: [String]) {
        var problems: [String] = []
        let modes = ModeStore(directory: directory) { problems.append($0.description) }.loadAll()
        let mode = ModeSelection.resolve(
            among: modes, manualKey: ModePreference(defaults: defaults).selectedKey,
            frontmostBundleID: nil
        ) { problems.append($0.description) }
        return (mode, problems)
    }

    func testTheChosenModeIsTheOneADictationRunsUnder() throws {
        try ModeStore(directory: directory) { _ in }.createBuiltInsIfMissing()
        ModePreference(defaults: defaults).selectedKey = "prompt"

        let resolved = resolveAsADictationWould()

        XCTAssertEqual(resolved.mode.key, "prompt")
        // The whole point of the choice: this mode is the one that sends the transcript to Ollama.
        XCTAssertTrue(resolved.mode.llm.enabled)
        XCTAssertEqual(resolved.problems, [])
    }

    /// The failure the menu made reachable for the first time: a mode chosen, then its file
    /// deleted or renamed. Voice runs -- Louis can still dictate -- and the menu says why, because
    /// a menu ticking "Prompt" while raw transcripts come out explains itself to nobody.
    func testAChosenModeWhoseFileIsGoneRunsVoiceAndSaysWhy() throws {
        try ModeStore(directory: directory) { _ in }.createBuiltInsIfMissing()
        ModePreference(defaults: defaults).selectedKey = "prompt"
        try FileManager.default.removeItem(at: directory.appendingPathComponent("prompt.json"))

        let resolved = resolveAsADictationWould()

        XCTAssertEqual(resolved.mode.key, "voice")
        XCTAssertFalse(resolved.mode.llm.enabled, "Voice never refines")
        XCTAssertEqual(resolved.problems,
                       [ModeSelectionProblem.unknownManualSelection(key: "prompt").description])
    }
}
