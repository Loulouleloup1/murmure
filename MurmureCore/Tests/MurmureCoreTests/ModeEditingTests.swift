import XCTest
@testable import MurmureCore

/// The mode editor: which field an error belongs under, and what saving does to the folder.
///
/// Everything here writes into a fresh temporary directory, for the reason `ModeStoreTests` states
/// at the top of its own file: nothing may reach `~/Library/Application Support/Murmure/modes`,
/// which holds the modes of the running application.
final class ModeEditingTests: XCTestCase {
    private var directory: URL!
    private var store: ModeStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModeEditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ModeStore(directory: directory) { XCTFail("unexpected mode problem: \($0)") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// Opens a mode the way the pane does: read it, and read its file's date at the same moment.
    private func open(_ mode: Mode) -> ModeDraft {
        ModeDraft(editing: mode, modifiedAt: store.modificationDate(forKey: mode.key))
    }

    // MARK: - Where an error is shown

    /// One invalid mode per case of `ModeValidationError`, and the field the editor draws it
    /// under. The ten cases are listed here rather than derived, because the point of the test is
    /// that each one was *decided* — a mapping derived from the same switch would agree with
    /// itself whatever it said.
    func testEveryValidationCaseIsShownUnderTheFieldThatCausedIt() {
        let cases: [(Mode, ModeValidationError, ModeField)] = [
            (Mode.voice.with { $0.key = "  " }, .emptyKey, .key),
            (Mode.voice.with { $0.key = "my mode" }, .keyIsNotFilenameSafe("my mode"), .key),
            (Mode.voice.with { $0.name = "" }, .emptyName, .name),
            (Mode.voice.with { $0.stt.model = "" }, .emptySTTModel, .sttModel),
            (Mode.voice.with { $0.stt.language = "" }, .emptySTTLanguage, .sttLanguage),
            (Mode.prompt.with { $0.llm.endpoint = "ollama" },
             .invalidLLMEndpoint("ollama"), .llmEndpoint),
            (Mode.prompt.with { $0.llm.endpoint = "http://localhost:11434/v1" },
             .llmEndpointIsNotARoot(endpoint: "http://localhost:11434/v1",
                                    root: "http://localhost:11434"),
             .llmEndpoint),
            (Mode.prompt.with { $0.llm.model = "" }, .emptyLLMModel, .llmModel),
            (Mode.prompt.with { $0.instructions = "" }, .emptyInstructions, .instructions),
            (Mode.prompt.with { $0.instructions = "Keep it short." },
             .instructionsAreNotControlFields("Keep it short."), .instructions),
        ]
        XCTAssertEqual(cases.count, 10, "a validation case was added without a field to show it in")

        for (mode, expected, field) in cases {
            let draft = ModeDraft(editing: mode, modifiedAt: nil)
            XCTAssertEqual(draft.validationError, expected, mode.key)
            XCTAssertFalse(draft.canSave, "\(expected)")
            XCTAssertEqual(draft.message(for: field), expected.description, "\(expected)")
            // And nowhere else: a message under a field that is not the one to fix sends the
            // reader to the wrong input, which is the banner problem with extra steps.
            for other in ModeField.allCases where other != field {
                XCTAssertNil(draft.message(for: other), "\(expected) also showed under \(other)")
            }
        }
    }

    /// The five fields the basic editor draws and the two the advanced screen does, partitioned:
    /// a field on neither screen is a field whose error has nowhere to appear, and one on both is
    /// a value edited in two places.
    func testEveryFieldIsOnExactlyOneOfTheTwoScreens() {
        XCTAssertEqual(ModeField.allCases.filter { $0.screen == .basic },
                       [.name, .sttModel, .sttLanguage, .llmModel, .instructions])
        XCTAssertEqual(ModeField.allCases.filter { $0.screen == .advanced }, [.key, .llmEndpoint])
    }

    /// An empty key is fixed on a screen the reader is not looking at, so the basic editor points
    /// at the way there. The same message never appears twice: on the screen that owns the field,
    /// it is under the field.
    func testAnErrorOnTheOtherScreenIsAnnouncedBesideTheWayToIt() {
        let draft = ModeDraft(editing: Mode.voice.with { $0.key = "" }, modifiedAt: nil)

        XCTAssertEqual(draft.messageElsewhere(from: .basic),
                       ModeValidationError.emptyKey.description)
        XCTAssertNil(draft.messageElsewhere(from: .advanced))
        XCTAssertEqual(draft.message(for: .key), ModeValidationError.emptyKey.description)
    }

    func testAValidModeAnnouncesNothingOnEitherScreen() {
        for screen in ModeEditorScreen.allCases {
            XCTAssertNil(open(.prompt).messageElsewhere(from: screen), "\(screen)")
        }
    }

    func testAValidModeShowsNoMessageUnderAnyField() {
        let draft = open(.prompt)

        XCTAssertTrue(draft.canSave)
        for field in ModeField.allCases {
            XCTAssertNil(draft.message(for: field), "\(field)")
        }
    }

    /// The one the whole editor exists for. `Mode.validate()` already refuses prose on an `s1`
    /// mode, but at dictation time that costs the refinement and inserts the raw transcript --
    /// and the measured version of the failure it prevents is the model copying the instruction
    /// back into Louis's own text. Refused while it is being typed, and nothing reaches the disk.
    func testAnS1ModeRefusesProseInInstructionsBeforeItCanBeSaved() throws {
        var draft = ModeDraft(creating: Mode.prompt.with { $0.key = "cleanup" })
        draft.mode.instructions = "Correct the punctuation and keep the text in French."

        XCTAssertFalse(draft.canSave)
        XCTAssertNotNil(draft.message(for: .instructions))
        XCTAssertThrowsError(try store.save(draft))
        XCTAssertEqual(try fileNames(), [], "an unusable mode reached the disk")

        // The same field with a control line saves, so the refusal is about the prose and not
        // about the mode.
        draft.mode.instructions = "[Context: general]"
        XCTAssertTrue(draft.canSave)
        XCTAssertNoThrow(try store.save(draft))
        XCTAssertEqual(try fileNames(), ["cleanup.json"])
    }

    // MARK: - The round trip

    /// The contract of the whole pane: what the editor writes, `loadAll()` reads back as the same
    /// object. Every field is set to something other than its default, because a field lost in the
    /// round trip is only visible if it had a value to lose.
    func testAModeSavedFromTheEditorReadsBackAsTheSameObject() throws {
        // A full reference, not the legacy display alias: `ModeStore` migrates that alias on
        // load (its own test coverage lives in `ModeStoreTests`), which would make this round-trip
        // test about migration rather than about the editor -- two different claims.
        let edited = Mode(
            key: "review", name: "Review",
            hotkey: KeyCombo(keyCode: 15, carbonModifiers: 2304),
            stt: .init(model: "argmaxinc/whisperkit-coreml/openai_whisper-tiny", language: "en"),
            llm: .init(enabled: true, endpoint: "http://localhost:11434",
                       model: "gemma4:12b-it-qat", api: .chat),
            instructions: "Rewrite the transcript as a review comment.",
            context: .init(selectedText: true, clipboard: true, appContext: true),
            autoActivate: ["com.microsoft.VSCode", "com.googlecode.iterm2"],
            simulateKeypresses: true)

        try store.save(ModeDraft(creating: edited))

        XCTAssertEqual(store.loadAll().first { $0.key == "review" }, edited)
    }

    /// Byte for byte, not merely field for field. The same files are opened in a text editor, so
    /// a save that reordered the keys or dropped `"hotkey": null` would turn every edit made in
    /// the window into a diff of the whole file.
    func testOpeningAModeAndSavingItUnchangedRewritesTheSameBytes() throws {
        try store.save(Mode.prompt)
        let before = try Data(contentsOf: directory.appendingPathComponent("prompt.json"))

        try store.save(open(.prompt))

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("prompt.json")),
                       before)
    }

    // MARK: - The name, the key, and the file

    /// The name is a field like any other. `voice.json` is a path Louis refers to, and renaming
    /// the mode in the window may not move it.
    func testRenamingTheNameLeavesTheFileWhereItWas() throws {
        try store.save(Mode.voice)
        var draft = open(.voice)
        draft.mode.name = "Dictée"

        XCTAssertFalse(draft.movesItsFile)
        try store.save(draft)

        XCTAssertEqual(try fileNames(), ["voice.json"])
        XCTAssertEqual(store.loadAll().first?.name, "Dictée")
    }

    /// The key is the file name, so renaming it is a move -- and the old file may not survive it:
    /// `loadAll()` would read the mode twice, once under each key, and `ModePreference` would go
    /// on pointing at the one that no longer exists.
    func testRenamingTheKeyMovesTheFileAndLeavesNoOrphan() throws {
        try store.save(Mode.prompt)
        var draft = open(.prompt)
        draft.mode.key = "claude"

        XCTAssertTrue(draft.movesItsFile)
        try store.save(draft)

        XCTAssertEqual(try fileNames(), ["claude.json"])
        XCTAssertEqual(store.loadAll().map(\.key), ["claude", "voice"])
    }

    /// `loadAll()` stands `Voice` in when its file is absent, which is why the list above ends in
    /// `voice` -- and why a renamed `voice` leaves the built-in behind rather than nothing.
    func testRenamingVoiceLeavesTheBuiltInStandingIn() throws {
        try store.save(Mode.voice)
        var draft = open(.voice)
        draft.mode.key = "dictation"
        try store.save(draft)

        XCTAssertEqual(try fileNames(), ["dictation.json"])
        XCTAssertEqual(store.loadAll().map(\.key), ["dictation", "voice"])
    }

    func testRenamingAKeyOntoAnotherModesFileIsRefusedRatherThanOverwritingIt() throws {
        try store.save(Mode.voice)
        try store.save(Mode.prompt)
        var draft = open(.prompt)
        draft.mode.key = "voice"

        XCTAssertThrowsError(try store.save(draft)) { error in
            XCTAssertEqual(error as? ModeWriteProblem, .keyAlreadyInUse(key: "voice"))
        }
        XCTAssertEqual(store.loadAll(), [Mode.prompt, Mode.voice].sorted { $0.key < $1.key })
    }

    /// A new mode whose key is already taken is the same collision by another route -- the key can
    /// be typed by hand on the advanced screen, so `availableKey` is not the only way one is made.
    func testANewModeCannotBeCreatedOverAnExistingFile() throws {
        try store.save(Mode.voice)

        let draft = ModeDraft(creating: Mode.prompt.with { $0.key = "voice" })

        XCTAssertThrowsError(try store.save(draft))
        XCTAssertEqual(store.loadAll(), [Mode.voice])
    }

    func testDeletingAModeRemovesItsFile() throws {
        try store.save(Mode.voice)
        try store.save(Mode.prompt)

        try store.delete(open(.prompt))

        XCTAssertEqual(try fileNames(), ["voice.json"])
    }

    /// The asymmetry that must not exist: `save` refuses to overwrite a file edited underneath the
    /// editor, so `delete` has to refuse to destroy one. Guarding only the reversible path is the
    /// wrong way round -- pressing Delete would silently take a correction that pressing Save
    /// would have been refused for.
    func testDeletingRefusesAModeWhoseFileChangedSinceTheEditorOpenedIt() throws {
        try store.save(Mode.prompt)
        let draft = open(.prompt)

        let handEdited = Mode.prompt.with { $0.instructions = "[Context: email]" }
        try store.save(handEdited)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: directory.appendingPathComponent("prompt.json").path)

        XCTAssertThrowsError(try store.delete(draft)) { error in
            XCTAssertEqual(error as? ModeWriteProblem, .fileChangedOnDisk(key: "prompt"))
        }
        XCTAssertEqual(store.loadAll().first { $0.key == "prompt" }, handEdited)
    }

    /// A file already gone is the outcome that was asked for, not a failure to report.
    func testDeletingAModeWhoseFileIsAlreadyGoneIsNotAnError() throws {
        try store.save(Mode.prompt)
        let draft = open(.prompt)
        try store.delete(draft)

        XCTAssertNoThrow(try store.delete(draft))
    }

    // MARK: - Deleting a built-in is a reset

    /// A built-in cannot be deleted: `createBuiltInsIfMissing()` runs at **every** launch, so both
    /// files are written again whatever happens to them. The button says what actually happens
    /// rather than a word the app then contradicts.
    func testRemovingABuiltInIsAResetAndRemovingAnyOtherModeIsADeletion() {
        for mode in Mode.builtIns {
            XCTAssertEqual(mode.removal, .reset, mode.key)
        }
        XCTAssertEqual(Mode.voice.with { $0.key = "dictation" }.removal, .deletion)
    }

    /// By key, not by identity: a mode renamed onto `voice` **is** the one that comes back.
    func testAModeRenamedOntoABuiltInsKeyIsTheOneThatComesBack() {
        XCTAssertTrue(Mode.prompt.with { $0.key = "voice" }.isBuiltIn)
        XCTAssertFalse(Mode.voice.with { $0.key = "voice-2" }.isBuiltIn)
    }

    /// The dialog exists for its message, so the message is what is checked: the file it removes,
    /// and whether the mode is back at once or only after a relaunch -- which is visible, since a
    /// reset `Prompt` is missing from the list until then and `Voice` never is.
    func testTheResetDialogSaysTheModeComesBackAndTheEditsDoNot() {
        let voice = Mode.voice.removalConfirmation
        XCTAssertTrue(voice.message.contains("modes/voice.json"), voice.message)
        XCTAssertTrue(voice.message.contains("straight away"), voice.message)

        let prompt = Mode.prompt.removalConfirmation
        XCTAssertTrue(prompt.message.contains("at the next launch"), prompt.message)
        XCTAssertTrue(prompt.message.contains("every change made to it"), prompt.message)
    }

    /// A deletion promises nothing comes back, and says the archive is untouched -- the one thing
    /// someone about to remove a mode they have dictated with would want to know.
    func testTheDeleteDialogNamesTheFileAndWhatSurvivesIt() {
        let prompt = Mode.voice.with { $0.key = "review"; $0.name = "Review" }
            .removalConfirmation

        XCTAssertTrue(prompt.title.contains("Review"), prompt.title)
        XCTAssertTrue(prompt.message.contains("modes/review.json"), prompt.message)
        XCTAssertTrue(prompt.message.contains("nothing brings it back"), prompt.message)
    }

    /// Both stop to ask, so both wear the ellipsis -- `HistoryClearing.buttonTitle`'s rule, where
    /// a trailing `…` is macOS spelling "this opens something before it acts". A destructive
    /// button that acts immediately must not wear one, and neither of these acts immediately.
    func testBothRemovalsAnnounceThatTheyWillAsk() {
        for removal in [ModeRemoval.deletion, .reset] {
            XCTAssertTrue(removal.buttonTitle.hasSuffix("\u{2026}"), removal.buttonTitle)
        }
        XCTAssertNotEqual(ModeRemoval.deletion.buttonTitle, ModeRemoval.reset.buttonTitle)
    }

    // MARK: - The file edited underneath the window

    /// The one loss in this pane that cannot be undone: a prompt rewritten by hand while the
    /// window sat open on a copy read minutes ago. Refused, and nothing is written -- the reader
    /// is told to reopen rather than asked to choose between two versions they can only see one of.
    func testSavingRefusesAModeWhoseFileChangedSinceTheEditorOpenedIt() throws {
        try store.save(Mode.prompt)
        var draft = open(.prompt)
        draft.mode.name = "Claude"

        let handEdited = Mode.prompt.with { $0.instructions = "[Context: email]" }
        try store.save(handEdited)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: directory.appendingPathComponent("prompt.json").path)

        XCTAssertThrowsError(try store.save(draft)) { error in
            XCTAssertEqual(error as? ModeWriteProblem, .fileChangedOnDisk(key: "prompt"))
        }
        XCTAssertEqual(store.loadAll().first { $0.key == "prompt" }, handEdited)
    }

    func testSavingProceedsWhenTheFileHasNotMoved() throws {
        try store.save(Mode.prompt)
        var draft = open(.prompt)
        draft.mode.name = "Claude"

        XCTAssertNoThrow(try store.save(draft))
        XCTAssertEqual(store.loadAll().first { $0.key == "prompt" }?.name, "Claude")
    }

    /// A mode whose file was deleted by hand is not a conflict: there is nothing left to
    /// overwrite, and refusing would strand the copy in the editor with nowhere to put it.
    func testAModeWhoseFileWasDeletedUnderneathIsWrittenAgain() throws {
        try store.save(Mode.prompt)
        let draft = open(.prompt)
        try store.delete(draft)

        XCTAssertNoThrow(try store.save(draft))
        XCTAssertEqual(try fileNames(), ["prompt.json"])
    }

    // MARK: - Losing what is in the editor

    /// The whole-object comparison is what stops the guard asking about work nobody did: a field
    /// typed and typed back reads as unchanged.
    func testAnEditorWithNothingTypedInItHasNothingToLose() {
        var draft = open(.prompt)
        XCTAssertFalse(draft.hasUnsavedChanges)

        draft.mode.name = "Claude"
        XCTAssertTrue(draft.hasUnsavedChanges)

        draft.mode.name = Mode.prompt.name
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    /// A mode being created has everything to lose: nothing about it is on disk yet, so the two
    /// dialogs say different things about what survives.
    func testTheDiscardDialogSaysWhatIsStillOnDiskAndWhatIsNot() {
        var creation = ModeDraft(creating: ModePreset.custom.mode(avoiding: []))
        creation.mode.instructions = "[Context: general]"
        XCTAssertTrue(creation.discardConfirmation.message
            .contains("Nothing has been written to the modes folder yet"),
            creation.discardConfirmation.message)

        var edit = open(.prompt)
        edit.mode.name = "Claude"
        // Named by the mode as it was OPENED, not as it has been retyped: the file to go and look
        // at is the one under the old name.
        XCTAssertTrue(edit.discardConfirmation.message.contains("modes/prompt.json"),
                      edit.discardConfirmation.message)
        XCTAssertTrue(edit.discardConfirmation.title.contains(Mode.prompt.name),
                      edit.discardConfirmation.title)
    }

    // MARK: - The selection after a rename

    /// Renaming a key leaves the stored selection pointing at nothing. Nothing breaks —
    /// `ModeSelection.resolve` falls through and reports it — but Louis would watch his active
    /// mode change on its own, so the selection follows the rename it was named by.
    func testTheSelectedModeFollowsARenameOfItsOwnKey() {
        XCTAssertEqual(
            ModePreference.selection("prompt", following: (from: "prompt", to: "claude")),
            "claude")
    }

    /// And only that one. Renaming another mode's key, or renaming while nothing is selected,
    /// must not make a choice on Louis's behalf -- "automatic" is one of the choices.
    func testEveryOtherSelectionIsLeftExactlyWhereItWas() {
        XCTAssertEqual(
            ModePreference.selection("voice", following: (from: "prompt", to: "claude")), "voice")
        XCTAssertNil(ModePreference.selection(nil, following: (from: "prompt", to: "claude")))
    }

    // MARK: - Creating from a preset

    /// The picker offers what ships, which is two modes and Custom. The plan's own line says
    /// "Murmure's four built-ins plus Custom" and is out of date: `Message` and `Email` were
    /// removed for pointing at a model `scripts/bootstrap.sh` does not pull. Derived from
    /// `builtIns` rather than listed, so the picker cannot offer a mode the app does not have.
    func testThePickerOffersEveryBuiltInPlusCustom() {
        XCTAssertEqual(ModePreset.all.map(\.name), Mode.builtIns.map(\.name) + ["New mode"])
    }

    func testEveryPresetProducesAModeThatCanBeSaved() throws {
        for preset in ModePreset.all {
            let mode = preset.mode(avoiding: [])
            XCTAssertNoThrow(try mode.validate(), preset.name)
            XCTAssertNoThrow(try store.save(ModeDraft(creating: mode)), preset.name)
        }
        XCTAssertEqual(try fileNames(), ["new-mode.json", "prompt.json", "voice.json"])
    }

    /// The failure that cost `Message` and `Email` their place in `builtIns`: a mode arriving with
    /// a refiner pointed at a 7.2 GB model nobody pulled refines nothing and says nothing about
    /// it. A blank mode transcribes.
    func testTheCustomPresetArrivesWithTheRefinerOff() {
        XCTAssertFalse(ModePreset.custom.mode(avoiding: []).llm.enabled)
    }

    /// Picking `Voice` a second time may not overwrite the first: the key is the file name, and
    /// the picker is the one place a duplicate is created deliberately.
    func testAPresetPickedTwiceGetsItsOwnFile() throws {
        try store.save(Mode.voice)
        let preset = try XCTUnwrap(ModePreset.all.first { $0.name == "Voice" })

        let second = preset.mode(avoiding: store.loadAll().map(\.key))
        try store.save(ModeDraft(creating: second))

        XCTAssertEqual(second.key, "voice-2")
        XCTAssertEqual(try fileNames(), ["voice-2.json", "voice.json"])
        // `loadAll()` orders by *file name*, so `voice-2.json` precedes `voice.json`: `-` sorts
        // before `.`. Written out rather than assumed, because it is the order the pane lists the
        // modes in and it is not the order the keys would give.
        XCTAssertEqual(store.loadAll().map(\.key), ["voice-2", "voice"])
    }

    /// The key is a file name, so a name that is not one has to become one -- and the result has
    /// to pass the validation that refuses a key it cannot write.
    func testAKeyDerivedFromANameIsAlwaysOneThatCanBeWritten() {
        let derived = [
            "Voice": "voice",
            "Claude Code": "claude-code",
            "Réponse à Slack": "r-ponse-slack",
            "  spaced  out  ": "spaced-out",
            "notes/2026": "notes-2026",
            "…": "mode",
        ]
        for (name, key) in derived {
            XCTAssertEqual(Mode.availableKey(basedOn: name, avoiding: []), key, name)
            XCTAssertNil(Mode.voice.with { $0.key = key }.validationError, name)
        }
    }

    // MARK: - The auto-activation field

    /// One line of comma-separated bundle ids, out and back unchanged -- including the case, which
    /// is left as typed because `ModeSelection` compares without it and rewriting what someone
    /// entered is how a field stops being theirs.
    func testTheAutoActivationFieldRoundTripsTheListItWasGiven() {
        let ids = ["com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode"]

        XCTAssertEqual(Mode.autoActivateList(from: Mode.autoActivateText(ids)), ids)
    }

    /// The normal way to leave this field is mid-edit: a trailing comma, a stray space, an empty
    /// line. None of them may reach the file -- `""` in `autoActivate` is a claim on no
    /// application that a reader of the JSON has to work out is inert.
    func testTheAutoActivationFieldWritesNoEmptyClaim() {
        XCTAssertEqual(Mode.autoActivateList(from: " com.apple.Terminal ,, "),
                       ["com.apple.Terminal"])
        XCTAssertEqual(Mode.autoActivateList(from: "   "), [])
        XCTAssertEqual(Mode.autoActivateText([]), "")
    }

    /// Counts from 2 and skips what is taken, so a third `Voice` does not land back on the second.
    func testTheSuffixSkipsEveryKeyAlreadyThere() {
        XCTAssertEqual(Mode.availableKey(basedOn: "Voice", avoiding: ["voice"]), "voice-2")
        XCTAssertEqual(Mode.availableKey(basedOn: "Voice", avoiding: ["voice", "voice-2"]),
                       "voice-3")
    }
}

extension Mode {
    fileprivate func with(_ mutate: (inout Mode) -> Void) -> Mode {
        var copy = self
        mutate(&copy)
        return copy
    }
}
