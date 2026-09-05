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

    /// A mode nobody shipped. `ModeStore` treats a hand-written file exactly like a built-in, and
    /// since only two modes ship this is the only way to get a third file into the folder -- which
    /// makes it the honest fixture for "one broken file must not cost the others" anyway. `Voice`
    /// supplies the fields these tests never look at.
    private func handWritten(_ key: String) -> Mode {
        var mode = Mode.voice
        mode.key = key
        mode.name = key.capitalized
        return mode
    }

    // MARK: - First launch

    func testFirstLaunchWritesTheTwoBuiltInsAndReadsThemBack() throws {
        try store.createBuiltInsIfMissing()

        XCTAssertEqual(try fileNames(), ["prompt.json", "voice.json"])
        XCTAssertEqual(store.loadAll().sorted { $0.key < $1.key },
                       Mode.builtIns.sorted { $0.key < $1.key })
        XCTAssertEqual(problems, [])
    }

    /// The file names are derived from `builtIns` rather than typed again, so this cannot drift
    /// into agreeing with whatever the code happens to write -- and `message.json` / `email.json`
    /// are named explicitly, because a first launch that recreated them would put back the two
    /// modes that refined nothing.
    func testFirstLaunchWritesNoFileForAModeThatNoLongerShips() throws {
        try store.createBuiltInsIfMissing()

        XCTAssertEqual(try fileNames(), Mode.builtIns.map { "\($0.key).json" }.sorted())
        for gone in ["message.json", "email.json"] {
            XCTAssertFalse(try fileNames().contains(gone), "\(gone) was recreated")
        }
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

    /// **`createBuiltInsIfMissing` writes; it never removes.** The case that made this worth a
    /// test of its own: `message.json` and `email.json` are on disk on machines that ran an
    /// earlier build, and this commit stopped shipping those modes. An upgrade that tidied them
    /// away would use the same code path to delete a mode somebody wrote by hand -- the folder
    /// cannot tell the two apart, because after this commit they *are* the same thing.
    ///
    /// So the stale file stays, and keeps working as a hand-written mode until its owner removes
    /// it. Removing it is a person's decision, with a backup, once.
    func testAFileForAModeThatNoLongerShipsIsLeftAloneAndStillLoads() throws {
        try store.createBuiltInsIfMissing()
        var stale = handWritten("message")
        stale.name = "Message"
        try store.save(stale)

        try store.createBuiltInsIfMissing()

        let names = try fileNames()
        XCTAssertTrue(names.contains("message.json"), "\(names)")
        XCTAssertEqual(store.loadAll().first { $0.key == "message" }, stale)
        XCTAssertEqual(problems, [])
    }

    // MARK: - A hand-edited file that is broken

    /// The reason this store exists: these files are edited by hand in a text editor, so a missing
    /// brace and a quoted boolean are going to happen. Neither may cost the other three modes.
    func testAMalformedFileIsReportedAndSkippedWhileEveryOtherModeStillLoads() throws {
        try store.createBuiltInsIfMissing()
        try store.save(handWritten("custom"))
        try store.save(handWritten("notes"))
        try write("""
        {
          "key": "prompt",
          "name": "Prompt",
          "stt": {"model": "large-v3-turbo",
        """, as: "prompt.json")
        try write(String(decoding: try ModeStore.encoder.encode(handWritten("notes")), as: UTF8.self)
            .replacingOccurrences(of: "\"simulateKeypresses\" : false",
                                  with: "\"simulateKeypresses\" : \"false\""),
            as: "notes.json")

        let modes = store.loadAll()

        // `custom` is the survivor that matters: a hand-written mode, loaded from its own file,
        // with a broken built-in and a broken hand-written file on either side of it.
        XCTAssertEqual(modes.map(\.key), ["custom", "voice"])
        XCTAssertEqual(problems.count, 2, "\(problems)")
        for name in ["prompt.json", "notes.json"] {
            XCTAssertTrue(
                problems.contains { if case .malformedJSON(name, _) = $0 { return true } else { return false } },
                "no malformedJSON reported for \(name): \(problems)")
        }
    }

    func testAFileThatParsesButIsNotAUsableModeIsReportedWithTheFieldThatIsWrong() throws {
        try store.createBuiltInsIfMissing()
        try write(String(decoding: try ModeStore.encoder.encode(handWritten("custom")), as: UTF8.self)
            .replacingOccurrences(of: "\"name\" : \"Custom\"", with: "\"name\" : \"\""),
            as: "custom.json")

        let modes = store.loadAll()

        XCTAssertFalse(modes.contains { $0.key == "custom" })
        XCTAssertEqual(problems, [.invalidField(name: "custom.json", error: .emptyName)])
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

        // The keys, not a count: "2 modes loaded" would also be satisfied by `notes.txt` coming
        // in as a mode and a built-in silently dropping out.
        XCTAssertEqual(store.loadAll().map(\.key).sorted(), Mode.builtIns.map(\.key).sorted())
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
        // A hand-written mode sorting ahead of both built-ins, so the assertion distinguishes
        // "ordered by file name" from "the order `builtIns` declares" -- which is the claim.
        try store.save(handWritten("custom"))

        XCTAssertEqual(store.loadAll().map(\.key), store.loadAll().map(\.key))
        XCTAssertEqual(store.loadAll().map(\.key), ["custom", "prompt", "voice"])
    }

    // MARK: - Speech-model migration

    /// Writes a mode whose `stt.model` is exactly `raw`, bypassing `save()` so an otherwise-blank
    /// field is not refused by `Mode.validate()` before `loadAll()` ever sees it -- the shape a
    /// hand-cleared real mode file is in.
    private func writeMode(key: String, sttModel raw: String) throws {
        var mode = handWritten(key)
        mode.stt.model = raw
        let encoded = try String(decoding: ModeStore.encoder.encode(mode), as: UTF8.self)
        try write(encoded, as: "\(key).json")
    }

    private func readSTTModel(_ key: String) throws -> String {
        try JSONDecoder().decode(Mode.self, from: Data(contentsOf: directory.appendingPathComponent("\(key).json")))
            .stt.model
    }

    /// The alias every mode shipped with before `SpeechModelReference` existed. Loading it once
    /// rewrites both the in-memory mode AND the file on disk to the full reference.
    func testTheShippedAliasIsMigratedInMemoryAndOnDisk() throws {
        try writeMode(key: "legacy", sttModel: "large-v3-turbo")

        let modes = store.loadAll()

        XCTAssertEqual(modes.first { $0.key == "legacy" }?.stt.model, SpeechModelReference.shippedDefault.string)
        XCTAssertEqual(try readSTTModel("legacy"), SpeechModelReference.shippedDefault.string)
        XCTAssertEqual(problems, [])
    }

    /// A hand-cleared field means the same thing as the alias, and `Mode.validate()` would
    /// otherwise refuse it outright (`.emptySTTModel`) -- migration has to run BEFORE validation
    /// or a blank field is reported as broken instead of repaired.
    func testABlankSTTModelIsMigratedRatherThanRejectedAsInvalid() throws {
        try writeMode(key: "blank", sttModel: "   ")

        let modes = store.loadAll()

        XCTAssertEqual(modes.first { $0.key == "blank" }?.stt.model, SpeechModelReference.shippedDefault.string)
        XCTAssertEqual(problems, [])
    }

    /// A bare variant folder with no repository -- the shape every mode file carried before this
    /// migration, for a variant that is not the shipped default -- is assumed to live in
    /// `argmaxinc/whisperkit-coreml`, the same assumption `SpeechModelResolution` makes for an
    /// unmigrated caller.
    func testABareVariantIsMigratedAssumingTheDefaultRepository() throws {
        try writeMode(key: "custom", sttModel: "openai_whisper-tiny")

        let modes = store.loadAll()

        XCTAssertEqual(
            modes.first { $0.key == "custom" }?.stt.model,
            "argmaxinc/whisperkit-coreml/openai_whisper-tiny")
        XCTAssertEqual(try readSTTModel("custom"), "argmaxinc/whisperkit-coreml/openai_whisper-tiny")
    }

    /// A mode already carrying a full reference is left untouched -- both the in-memory value AND
    /// the file on disk, which is the idempotence a migration run on every launch depends on.
    ///
    /// **Proven by the file's modification date, not by its bytes.** `writeMode` encodes with the
    /// same `ModeStore.encoder` a rewrite would use, so a rewrite that reproduces byte-identical
    /// content is invisible to a before/after `Data` comparison -- that comparison would pass
    /// whether or not `loadAll()` actually skipped the write. The mtime does not have that blind
    /// spot: it is set to a known, far-past date right before the second `loadAll()`, so ANY write
    /// -- rewriting the same bytes included -- moves it forward and is caught.
    func testAFullReferenceIsNotRewritten() throws {
        try writeMode(key: "already", sttModel: "someowner/somerepo/some-variant")
        _ = store.loadAll()

        let path = directory.appendingPathComponent("already.json").path
        let past = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)

        let modes = store.loadAll()

        XCTAssertEqual(modes.first { $0.key == "already" }?.stt.model, "someowner/somerepo/some-variant")
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeAfter, past, "an already-migrated file must not be rewritten")
    }

    /// The shape `classifySTTModel` must never complete by guessing a third segment: a
    /// two-component `"owner/name"` with no variant. Rewriting it into
    /// `argmaxinc/whisperkit-coreml/owner/name` (treating the whole string as if it were shape 3's
    /// single bare variant) would silently turn a hand-typed value like `openai/whisper-large-v3`
    /// into a reference for a DIFFERENT model in a repository it never named. Left untouched, in
    /// memory and on disk, and reported instead.
    func testATwoComponentStoredValueIsLeftUntouchedAndReported() throws {
        try writeMode(key: "twopart", sttModel: "openai/whisper-large-v3")

        let modes = store.loadAll()

        XCTAssertEqual(modes.first { $0.key == "twopart" }?.stt.model, "openai/whisper-large-v3")
        XCTAssertEqual(try readSTTModel("twopart"), "openai/whisper-large-v3")
        XCTAssertEqual(
            problems,
            [.sttModelNotAReference(name: "twopart.json", stored: "openai/whisper-large-v3")])
    }

    /// A modes folder that has gone read-only still dictates correctly for THIS launch -- the
    /// migrated value stands in memory regardless of whether the write below succeeds -- but the
    /// failed write is reported through `report`, once, rather than swallowed by a bare `try?`.
    func testAnUnwritableDirectoryStillMigratesInMemoryAndReportsTheFailedWrite() throws {
        try XCTSkipIf(getuid() == 0, "chmod is not enforced for root")
        try writeMode(key: "legacy", sttModel: "large-v3-turbo")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let modes = store.loadAll()

        XCTAssertEqual(
            modes.first { $0.key == "legacy" }?.stt.model, SpeechModelReference.shippedDefault.string,
            "dictation must keep working on the migrated value even though the file could not be updated")
        XCTAssertEqual(problems.count, 1, "the failed write must be reported exactly once, not swallowed")
        guard case .sttModelMigrationNotSaved(let name, _) = problems.first else {
            return XCTFail("expected sttModelMigrationNotSaved, got \(problems)")
        }
        XCTAssertEqual(name, "legacy.json")
    }

    /// A mode whose `stt.model` would migrate but which is invalid for an unrelated reason
    /// (`llm.model` blank while `llm.enabled` is true) must be reported and skipped exactly as any
    /// other invalid mode -- and its file must NOT have been rewritten first: the migration write
    /// happens only after `validationError` has already passed.
    func testAnInvalidModeIsNotRewrittenEvenThoughSTTModelWouldMigrate() throws {
        var mode = handWritten("broken")
        mode.stt.model = "large-v3-turbo"
        mode.llm.enabled = true
        mode.llm.model = ""
        try write(String(decoding: ModeStore.encoder.encode(mode), as: UTF8.self), as: "broken.json")

        let modes = store.loadAll()

        XCTAssertNil(modes.first { $0.key == "broken" }, "an invalid mode must be skipped, not returned")
        XCTAssertEqual(try readSTTModel("broken"), "large-v3-turbo", "the file must not have been rewritten")
        XCTAssertEqual(problems, [.invalidField(name: "broken.json", error: .emptyLLMModel)])
    }
}
