import XCTest
@testable import MurmureCore

final class ModeStoreTests: XCTestCase {
    private var directory: URL!
    private var problems: [ModeLoadProblem] = []
    private var store: ModeStore!

    /// Every test writes into a fresh temporary directory. Nothing here may reach
    /// `~/Library/Application Support/Murmure/modes`, which holds the real modes of the app in use.
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModeStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        problems = []
        store = ModeStore(directory: directory) { [weak self] in self?.problems.append($0) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, as name: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - First launch

    func testFirstLaunchWritesTheFourBuiltInsAndReadsThemBack() throws {
        try store.createBuiltInsIfMissing()

        XCTAssertEqual(try fileNames(), ["email.json", "message.json", "prompt.json", "voice.json"])
        XCTAssertEqual(store.loadAll().sorted { $0.key < $1.key },
                       Mode.builtIns.sorted { $0.key < $1.key })
        XCTAssertEqual(problems, [])
    }

    func testASecondLaunchLeavesAHandEditedBuiltInAlone() throws {
        try store.createBuiltInsIfMissing()
        var edited = Mode.prompt
        edited.instructions = "Ne corrige que la ponctuation."
        edited.llm.model = "gemma4:e2b-it-qat"
        // Written instructions and a chat model are one decision, not two: `Prompt` ships on the
        // `s1` protocol, where prose is not an instruction but text the model copies into its
        // answer. Sending this mode back to a general model means saying so on the same edit --
        // which is the whole reason `api` is a field of the file rather than a guess about the
        // model's name.
        edited.llm.api = .chat
        try store.save(edited)

        try store.createBuiltInsIfMissing()

        let reloaded = try XCTUnwrap(store.loadAll().first { $0.key == "prompt" })
        XCTAssertEqual(reloaded, edited)
    }

    // MARK: - A hand-edited file that is broken

    /// The reason this store exists: these files are edited by hand in a text editor, so a missing
    /// brace and a quoted boolean are going to happen. Neither may cost the other three modes.
    func testAMalformedFileIsReportedAndSkippedWhileEveryOtherModeStillLoads() throws {
        try store.createBuiltInsIfMissing()
        try write("""
        {
          "key": "prompt",
          "name": "Prompt",
          "stt": {"model": "large-v3-turbo",
        """, as: "prompt.json")
        try write(String(decoding: try ModeStore.encoder.encode(Mode.message), as: UTF8.self)
            .replacingOccurrences(of: "\"simulateKeypresses\" : false",
                                  with: "\"simulateKeypresses\" : \"false\""),
            as: "message.json")

        let modes = store.loadAll()

        XCTAssertEqual(modes.map(\.key), ["email", "voice"])
        XCTAssertEqual(problems.count, 2, "\(problems)")
        for name in ["prompt.json", "message.json"] {
            XCTAssertTrue(
                problems.contains { if case .malformedJSON(name, _) = $0 { return true } else { return false } },
                "no malformedJSON reported for \(name): \(problems)")
        }
    }

    func testAFileThatParsesButIsNotAUsableModeIsReportedWithTheFieldThatIsWrong() throws {
        try store.createBuiltInsIfMissing()
        try write(String(decoding: try ModeStore.encoder.encode(Mode.email), as: UTF8.self)
            .replacingOccurrences(of: "\"name\" : \"Email\"", with: "\"name\" : \"\""),
            as: "email.json")

        let modes = store.loadAll()

        XCTAssertFalse(modes.contains { $0.key == "email" })
        XCTAssertEqual(problems, [.invalidField(name: "email.json", error: .emptyName)])
    }

    /// Copying `prompt.json` to `perso.json` and forgetting the `key` inside gives two files
    /// claiming one mode, and one of them silently wins. Refuse the ambiguity instead.
    func testAFileWhoseKeyDoesNotMatchItsFilenameIsReportedAndSkipped() throws {
        try store.createBuiltInsIfMissing()
        try write(String(decoding: try ModeStore.encoder.encode(Mode.prompt), as: UTF8.self),
                  as: "perso.json")

        let modes = store.loadAll()

        XCTAssertEqual(modes.filter { $0.key == "prompt" }.count, 1)
        XCTAssertEqual(problems, [.keyDoesNotMatchFilename(name: "perso.json", key: "prompt")])
    }

    /// Spec §5 makes `Voice` the default mode and lot 2 keeps it byte-identical to today's
    /// dictation. A typo in `voice.json` must cost its edits, not the ability to dictate.
    func testABrokenVoiceFileStillLeavesAWorkingDefaultMode() throws {
        try store.createBuiltInsIfMissing()
        try write("{ not json at all", as: "voice.json")

        let modes = store.loadAll()

        XCTAssertEqual(modes.first { $0.key == "voice" }, Mode.voice)
        XCTAssertEqual(problems.count, 1, "\(problems)")
    }

    func testAnAbsentDirectoryIsReportedAndStillYieldsTheDefaultMode() {
        let missing = directory.appendingPathComponent("gone")
        var seen: [ModeLoadProblem] = []
        let store = ModeStore(directory: missing) { seen.append($0) }

        XCTAssertEqual(store.loadAll(), [Mode.voice])
        XCTAssertEqual(seen.count, 1, "\(seen)")
        if case .directoryUnreadable = seen.first {} else { XCTFail("\(seen)") }
    }

    /// A file whose bytes cannot be read at all is a different fix from a file whose JSON is
    /// wrong, and it must not be reported as a syntax error the user will hunt for in vain.
    func testAFileThatCannotBeReadIsReportedAsUnreadableAndNotAsBadJSON() throws {
        try store.createBuiltInsIfMissing()
        let locked = directory.appendingPathComponent("prompt.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: locked.path) }

        let modes = store.loadAll()

        try XCTSkipIf(modes.contains { $0.key == "prompt" }, "running as root -- permissions do not apply")
        XCTAssertEqual(problems.count, 1, "\(problems)")
        if case .unreadableFile = problems.first {} else { XCTFail("\(problems)") }
    }

    func testFilesThatAreNotModesAreIgnoredWithoutReport() throws {
        try store.createBuiltInsIfMissing()
        try write("", as: ".DS_Store")
        try write("scratch", as: "notes.txt")

        XCTAssertEqual(store.loadAll().count, 4)
        XCTAssertEqual(problems, [])
    }

    // MARK: - Saving

    func testSavingRefusesAnInvalidModeRatherThanWritingIt() throws {
        var broken = Mode.prompt
        broken.stt.model = ""

        XCTAssertThrowsError(try store.save(broken)) { error in
            XCTAssertEqual(error as? ModeValidationError, .emptySTTModel)
        }
        XCTAssertEqual(try fileNames(), [])
    }

    func testLoadingIsOrderedTheSameWayTwice() throws {
        try store.createBuiltInsIfMissing()
        XCTAssertEqual(store.loadAll().map(\.key), store.loadAll().map(\.key))
        XCTAssertEqual(store.loadAll().map(\.key), ["email", "message", "prompt", "voice"])
    }
}
