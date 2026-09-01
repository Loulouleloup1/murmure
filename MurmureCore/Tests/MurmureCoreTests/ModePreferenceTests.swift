import XCTest
@testable import MurmureCore

final class ModePreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    /// A suite of its own per test, removed afterwards. Nothing here may reach `.standard`, which
    /// is the real application's own preferences domain.
    override func setUpWithError() throws {
        suiteName = "ModePreferenceTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        // Same rule for the modes folder as `ModeStoreTests`: a temporary directory, never
        // `~/Library/Application Support/Murmure/modes`.
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModePreferenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Emptying the domain is not enough: `cfprefsd` leaves the suite's (now empty) plist behind
    /// in `~/Library/Preferences`, one per test per run, in Louis's own home directory. The file
    /// goes too. Only ever this test's own UUID-named file.
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        // `synchronize()` is the barrier that makes the deletion below stick: without it
        // `cfprefsd` flushes the emptied domain back to disk AFTER the file is gone, and recreates
        // it. Measured -- 6 files survived two runs before this line.
        defaults.synchronize()
        defaults.removeSuite(named: suiteName)
        let plist = try FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Preferences/\(suiteName!).plist")
        try? FileManager.default.removeItem(at: plist)

        try? FileManager.default.removeItem(at: directory)
    }

    /// The safety net for the same litter. `cfprefsd` writes asynchronously, so a flush can still
    /// land after the deletion above and recreate the file; measured, it does under load. This
    /// sweeps whatever is left once the class is done, and it only ever matches this class's own
    /// prefix.
    override class func tearDown() {
        guard let preferences = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Preferences"),
            let leftovers = try? FileManager.default.contentsOfDirectory(
                atPath: preferences.path)
        else { return }

        for name in leftovers
        where name.hasPrefix("ModePreferenceTests-") && name.hasSuffix(".plist") {
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(name))
        }
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

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(ModePreference(defaults: reopened).selectedKey, "prompt")
    }

    /// Going back to automatic is a choice too, not the absence of one, so it has to stick the
    /// same way. A preference that could only ever be set would trap Louis in the last mode he
    /// tried.
    func testGoingBackToAutomaticIsRememberedToo() throws {
        let preference = ModePreference(defaults: defaults)
        preference.selectedKey = "prompt"

        preference.selectedKey = nil

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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
