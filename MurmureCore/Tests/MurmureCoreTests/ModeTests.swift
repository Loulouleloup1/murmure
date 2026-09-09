import XCTest
@testable import MurmureCore

/// The JSON of spec §5, copied character for character except for its `"<benchmark winner>"`
/// placeholder, which is replaced by the model the v2 benchmark actually picked. These files are
/// hand-edited, so the on-disk shape is a contract, and this literal is the test's copy of it.
private let specExampleJSON = """
{
  "key": "prompt", "name": "Prompt", "hotkey": null,
  "stt": {"model": "large-v3-turbo", "language": "auto"},
  "llm": {"enabled": true, "endpoint": "http://localhost:11434/v1", "model": "gemma4:12b-it-qat"},
  "instructions": "…",
  "context": {"selectedText": false, "clipboard": false, "appContext": false},
  "autoActivate": ["com.googlecode.iterm2", "com.anthropic.claudefordesktop"],
  "simulateKeypresses": false
}
"""

final class ModeTests: XCTestCase {
    /// Decoding only. The example is deliberately not validated here: its `"/v1"` endpoint is the
    /// very mistake `testTheEndpointTheSpecItselfSuggestsIsRefused...` exists to catch.
    func testTheSpecExampleDecodesFieldForField() throws {
        let mode = try JSONDecoder().decode(Mode.self, from: Data(specExampleJSON.utf8))

        XCTAssertEqual(mode.key, "prompt")
        XCTAssertEqual(mode.name, "Prompt")
        XCTAssertNil(mode.hotkey)
        XCTAssertEqual(mode.stt.model, "large-v3-turbo")
        XCTAssertEqual(mode.stt.language, "auto")
        XCTAssertTrue(mode.llm.enabled)
        XCTAssertEqual(mode.llm.endpoint, "http://localhost:11434/v1")
        XCTAssertEqual(mode.llm.model, "gemma4:12b-it-qat")
        XCTAssertEqual(mode.instructions, "…")
        XCTAssertFalse(mode.context.selectedText)
        XCTAssertFalse(mode.context.clipboard)
        XCTAssertFalse(mode.context.appContext)
        XCTAssertEqual(mode.autoActivate, ["com.googlecode.iterm2", "com.anthropic.claudefordesktop"])
        XCTAssertFalse(mode.simulateKeypresses)
    }

    /// A written mode file is meant to be opened in a text editor. A `hotkey` that disappears when
    /// it is null, or a `\\/` in every URL, makes the file harder to edit than the spec's example.
    func testAWrittenModeKeepsTheHandEditableShapeOfTheSpec() throws {
        let json = String(decoding: try ModeStore.encoder.encode(Mode.prompt), as: UTF8.self)

        XCTAssertTrue(json.contains("\"hotkey\" : null"), json)
        XCTAssertTrue(json.contains("http://localhost"), json)
        XCTAssertFalse(json.contains("\\/"), json)

        // Foundation writes an unsorted dictionary in hash order -- measured while writing this
        // test, the fields came out in neither the order of spec §5 nor any other. Sorted is the
        // only order it will hold, and a stable order is what makes re-saving an untouched mode a
        // no-op in a diff instead of a full reshuffle.
        let positions = try ["autoActivate", "context", "hotkey", "instructions", "key", "llm",
                             "name", "simulateKeypresses", "stt"].map { field -> String.Index in
            try XCTUnwrap(json.range(of: "\"\(field)\" :"), "\(field) missing from \(json)").lowerBound
        }
        XCTAssertEqual(positions, positions.sorted(), "top-level fields are not in a stable order")
    }

    /// The spec example predates `symbol` -- absent from the JSON, it must decode to nil rather
    /// than fail, the same tolerance `api` already has for the field that came before it.
    func testAModeFileWrittenBeforeSymbolExistedStillDecodesWithANilSymbol() throws {
        let mode = try JSONDecoder().decode(Mode.self, from: Data(specExampleJSON.utf8))

        XCTAssertNil(mode.symbol)
    }

    /// A written mode always carries the key, even when there is nothing to write into it -- the
    /// same rule `hotkey` already follows (`testAWrittenModeKeepsTheHandEditableShapeOfTheSpec`),
    /// and for the same reason: a field invisible when nil is a field nobody discovers exists.
    func testAWrittenModeAlwaysWritesTheSymbolKeyEvenWhenNil() throws {
        XCTAssertNil(Mode.voice.symbol)
        let json = String(decoding: try ModeStore.encoder.encode(Mode.voice), as: UTF8.self)

        XCTAssertTrue(json.contains("\"symbol\" : null"), json)

        let withSymbol = Mode.voice.with { $0.symbol = "terminal" }
        let jsonWithSymbol = String(decoding: try ModeStore.encoder.encode(withSymbol), as: UTF8.self)
        XCTAssertTrue(jsonWithSymbol.contains("\"symbol\" : \"terminal\""), jsonWithSymbol)
    }

    func testARoundTripThroughJSONChangesNothing() throws {
        for mode in Mode.builtIns {
            let data = try ModeStore.encoder.encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(Mode.self, from: data), mode, mode.key)
        }
    }

    func testEveryInvalidFieldHasItsOwnNamedError() {
        let cases: [(String, Mode, ModeValidationError)] = [
            ("key", Mode.prompt.with { $0.key = "  " }, .emptyKey),
            ("key", Mode.prompt.with { $0.key = "../evil" }, .keyIsNotFilenameSafe("../evil")),
            ("name", Mode.prompt.with { $0.name = "" }, .emptyName),
            ("stt.model", Mode.prompt.with { $0.stt.model = "" }, .emptySTTModel),
            ("stt.language", Mode.prompt.with { $0.stt.language = "" }, .emptySTTLanguage),
            ("llm.endpoint", Mode.prompt.with { $0.llm.endpoint = "localhost:11434" },
             .invalidLLMEndpoint("localhost:11434")),
            ("llm.model", Mode.prompt.with { $0.llm.model = "" }, .emptyLLMModel),
            ("instructions", Mode.prompt.with { $0.instructions = "" }, .emptyInstructions),
        ]

        for (field, mode, expected) in cases {
            XCTAssertThrowsError(try mode.validate(), field) { error in
                XCTAssertEqual(error as? ModeValidationError, expected, field)
            }
        }
    }

    /// `http://localhost:11434/v1` is spec §5's own example, so of every wrong endpoint it is the
    /// one Louis is most likely to have. The client appends `api/chat` to whatever is here, gets
    /// `/v1/api/chat` and a 404, and can only report it as a response it could not read -- which
    /// sends him hunting a bug for a typo. Caught here, with the value to write instead.
    func testTheEndpointTheSpecItselfSuggestsIsRefusedWithTheRootToWriteInstead() {
        let mode = Mode.prompt.with { $0.llm.endpoint = "http://localhost:11434/v1" }
        let expected = ModeValidationError.llmEndpointIsNotARoot(
            endpoint: "http://localhost:11434/v1", root: "http://localhost:11434")

        XCTAssertThrowsError(try mode.validate()) { error in
            XCTAssertEqual(error as? ModeValidationError, expected)
        }
        XCTAssertTrue("\(expected)".contains("\"http://localhost:11434\""),
                      "the message does not say what to write: \(expected)")
    }

    /// A trailing slash addresses the same root and is what a copy-paste from a browser gives.
    /// Refusing it would be a validation error with nothing behind it: measured on the client as
    /// shipped, `URL.appending(path:)` turns both forms into the same `.../api/chat`.
    func testARootWithATrailingSlashIsAccepted() {
        XCTAssertNoThrow(
            try Mode.prompt.with { $0.llm.endpoint = "http://localhost:11434/" }.validate())
    }

    /// The three LLM fields only exist to be sent to Ollama. Requiring them on `Voice`, which has
    /// no refiner, would make the shipped default mode invalid.
    func testTheLLMFieldsAreOnlyRequiredWhenTheLLMIsOn() throws {
        var mode = Mode.voice
        mode.llm.model = ""
        mode.llm.endpoint = "not a url"
        mode.instructions = ""
        XCTAssertNoThrow(try mode.validate())

        mode.llm.enabled = true
        XCTAssertThrowsError(try mode.validate())
    }

    /// Two modes ship: `Voice` is la dictée, `Prompt` is la reformulation. `Message` and `Email`
    /// were removed rather than repointed -- see ``Mode/builtIns``.
    ///
    /// The partition is asserted over `builtIns` rather than over a hand-written pair, so a third
    /// built-in added later cannot slip past it: exactly one mode skips the refiner, it is
    /// `Voice`, and every mode that keeps one carries the instructions to drive it.
    func testTheTwoBuiltInsAreValidAndOnlyVoiceSkipsTheLLM() throws {
        XCTAssertEqual(Mode.builtIns.map(\.key), ["voice", "prompt"])
        XCTAssertEqual(Set(Mode.builtIns.map(\.key)).count, Mode.builtIns.count, "duplicate key")
        for mode in Mode.builtIns {
            XCTAssertNoThrow(try mode.validate(), mode.key)
        }

        XCTAssertEqual(Mode.builtIns.filter { !$0.llm.enabled }.map(\.key), ["voice"])
        XCTAssertTrue(Mode.voice.instructions.isEmpty)
        for mode in Mode.builtIns where mode.llm.enabled {
            XCTAssertFalse(mode.instructions.isEmpty, mode.key)
        }
    }

    /// The defect that shipped, pinned so it cannot ship twice.
    ///
    /// `Message` and `Email` were declared with `gemma4:12b-it-qat` while `scripts/bootstrap.sh`
    /// pulls exactly one refiner. On every machine set up the documented way, two of the four
    /// built-ins named a model that was not on disk -- and a mode whose refiner cannot answer
    /// falls back to inserting the raw transcript, silently, by design. Nothing reported it,
    /// because a mode pointing at an absent model looks exactly like one pointing at a present
    /// model until Ollama answers.
    ///
    /// The model is read out of the script rather than written here as a literal: two constants
    /// agreeing inside a test say nothing about the file a fresh install actually runs.
    func testEveryBuiltInRefinerNamesTheModelBootstrapPulls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MurmureCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MurmureCore
            .deletingLastPathComponent()  // the repository
        let script = root.appendingPathComponent("scripts/bootstrap.sh")
        let source = try String(contentsOf: script, encoding: .utf8)

        // The single `ollama pull` the script runs. Not found is a failure, never a skip: a test
        // that quietly passes when it cannot find its subject is a test that never goes red.
        let assignment = try XCTUnwrap(
            source.split(separator: "\n").first { $0.hasPrefix("REFINER_MODEL=") },
            "no REFINER_MODEL assignment in \(script.path)")
        let pulled = assignment.dropFirst("REFINER_MODEL=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        XCTAssertFalse(pulled.isEmpty, "REFINER_MODEL is empty in \(script.path)")

        for mode in Mode.builtIns where mode.llm.enabled {
            XCTAssertEqual(
                mode.llm.model, pulled,
                "built-in \(mode.key.debugDescription) names a refiner bootstrap.sh never pulls")
        }
    }

    // MARK: - Which protocol a model speaks

    /// Louis's four mode files were written before `api` existed and every one of them names a
    /// model that speaks `/api/chat`. They have to keep working untouched, which is why the
    /// absent field means `.chat` -- the value that changes nothing -- and never the new one.
    func testAModeFileWrittenBeforeTheFieldExistedStillDecodesAndStillSpeaksChat() throws {
        let mode = try JSONDecoder().decode(Mode.self, from: Data(specExampleJSON.utf8))

        XCTAssertEqual(mode.llm.api, .chat)
    }

    /// The other half of the same claim: a file Murmure writes always carries the field, spelt
    /// the way it is written by hand. A default that stayed invisible would leave Louis guessing
    /// what a mode is doing.
    func testAWrittenModeSaysWhichProtocolItSpeaks() throws {
        let json = String(decoding: try ModeStore.encoder.encode(Mode.prompt), as: UTF8.self)

        XCTAssertTrue(json.contains("\"api\" : \"s1\""), json)
        // No built-in speaks `chat` any more, so the chat side is written from a mode built here.
        // The claim is about the encoder -- `chat` is the value that would be invisible if it
        // were left to the decoder's default -- not about which modes ship.
        let chat = Mode.prompt.with {
            $0.llm.api = .chat
            $0.instructions = "Rewrite the transcript as a short message."
        }
        XCTAssertTrue(
            String(decoding: try ModeStore.encoder.encode(chat), as: UTF8.self)
                .contains("\"api\" : \"chat\""))
    }

    /// The switch this lot is for, stated where a reader can see all three parts of it at once:
    /// the model, the protocol it is talked to in, and the control line that replaces prose.
    func testTheCleanupModeShipsOnTheModelTheBenchmarkPicked() {
        XCTAssertEqual(Mode.prompt.llm.model, "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M")
        XCTAssertEqual(Mode.prompt.llm.api, .s1)
        // `[Context: general]` alone. `[Styling: ...]` drops capitalisation from 96 % to 29 %.
        XCTAssertEqual(Mode.prompt.instructions, "[Context: general]")

        // The claim the two removed rewriting modes used to carry, turned around: what ships is
        // ONE refiner, and every built-in that refines is that one on that one protocol. This is
        // what stops a rewriting mode being reintroduced pointing at a model nobody pulled.
        for mode in Mode.builtIns where mode.llm.enabled {
            XCTAssertEqual(mode.llm.model, Mode.prompt.llm.model, mode.key)
            XCTAssertEqual(mode.llm.api, .s1, mode.key)
        }
    }

    /// Removing `Message` and `Email` removed two modes, not the dialect they spoke. The README
    /// documents pointing a mode back at `gemma4:12b-it-qat` with `--api chat`,
    /// `scripts/set-refiner.sh` writes that combination, and ``Mode/prompt`` offers it as the
    /// escape hatch when merged sentences are unaffordable -- all three are a lie if a chat mode
    /// no longer validates.
    func testAChatModePointedAtTheRewritingModelIsStillAValidMode() throws {
        let rewriting = Mode.prompt.with {
            $0.key = "message"
            $0.name = "Message"
            $0.llm.api = .chat
            $0.llm.model = "gemma4:12b-it-qat"
            $0.instructions = "You turn dictated text into a short Slack message."
        }

        XCTAssertNoThrow(try rewriting.validate())
        // Prose is refused on `s1` and accepted on `chat`: the dialect is what decides, which is
        // the whole reason `api` is a field of the file.
        XCTAssertThrowsError(try rewriting.with { $0.llm.api = .s1 }.validate())
    }

    /// Prose on an `s1` mode is not ignored, it is *copied into the answer*: measured on the v3
    /// probe, an instruction appended to the control line came back verbatim at the top of the
    /// cleaned text on 1 fixture in 4. That is Louis's dictation with someone else's sentence
    /// pasted in, and nothing downstream can tell it apart from a refinement -- so it is refused
    /// here, and the raw transcript is inserted instead.
    func testWrittenInstructionsOnAnS1ModeAreRefusedBecauseTheModelCopiesThemIntoTheText() {
        let prose = "Capitalise every sentence and keep the text in French."
        let mode = Mode.prompt.with { $0.instructions = prose }

        XCTAssertThrowsError(try mode.validate()) { error in
            XCTAssertEqual(error as? ModeValidationError, .instructionsAreNotControlFields(prose))
        }
        XCTAssertTrue("\(ModeValidationError.instructionsAreNotControlFields(prose))"
            .contains("[Context: general]"), "the message does not show what to write instead")

        // The same sentence on a chat mode is exactly what that dialect is for.
        XCTAssertNoThrow(
            try Mode.prompt.with { $0.instructions = prose; $0.llm.api = .chat }.validate())
    }

    /// The rule is "bracketed fields and whitespace, nothing else", which is the whole interface
    /// the model has. Several fields are fine; a field with prose hanging off it is not, because
    /// that is the exact shape the probe measured coming back inside the text.
    func testAControlLineMayCarrySeveralFieldsButNothingOutsideTheBrackets() {
        let accepted = ["[Context: general]", "  [Structure: prose] [Context: email]  ",
                        "[Context: general]\n[Structure: lists]"]
        let refused = ["[Context: general] and keep it in French", "Context: general",
                       "[Context: general", "[]", "[Context: [general]]",
                       // A closing bracket alone does not open a field...
                       "Context: general]",
                       // ...and neither does one nested inside another, even when what follows
                       // it would parse on its own.
                       "[a[b] [Context: general]"]

        for instructions in accepted {
            XCTAssertNoThrow(
                try Mode.prompt.with { $0.instructions = instructions }.validate(), instructions)
        }
        for instructions in refused {
            XCTAssertThrowsError(
                try Mode.prompt.with { $0.instructions = instructions }.validate(), instructions)
        }
    }

    /// Measured on the whole 1 449-dictation corpus (lot 2 plan): `detectLanguage` re-evaluates per
    /// window and produced non-Latin transcripts. The default must not reintroduce it.
    func testEveryBuiltInPinsTheDecoderToFrench() {
        for mode in Mode.builtIns {
            XCTAssertEqual(mode.stt.language, "fr", mode.key)
        }
    }

    // MARK: - Protected Voice and mandatory refiner

    func testVoiceIsTheOnlyProtectedMode() {
        XCTAssertTrue(Mode.voice.isProtected)
        XCTAssertFalse(Mode.prompt.isProtected)
        var custom = Mode.prompt; custom.key = "meeting"
        XCTAssertFalse(custom.isProtected)
    }

    func testEditingAProtectedModesNameOrSymbolIsRefused() {
        var renamed = Mode.voice; renamed.name = "Dictée"
        XCTAssertEqual(renamed.editorValidationError(original: .voice), .protectedField("name"))
        var reglyphed = Mode.voice; reglyphed.symbol = "brain"
        XCTAssertEqual(reglyphed.editorValidationError(original: .voice), .protectedField("symbol"))
    }

    func testAProtectedModeStillAcceptsLanguageShortcutAndSpeechModel() {
        var edited = Mode.voice
        edited.stt.language = "en"
        edited.stt.model = "openai_whisper-small"
        edited.hotkey = KeyCombo(keyCode: 49, carbonModifiers: 2560) // option + shift
        XCTAssertNil(edited.editorValidationError(original: .voice))
    }

    // MARK: - Refiner kinds (task 4)

    func testEachRefinerKindHasItsOwnDefaultsAndModelFilter() {
        XCTAssertEqual(Mode.LLM.API.s1.defaultModel, Mode.cleanupModel)
        XCTAssertEqual(Mode.LLM.API.chat.defaultModel, Mode.rewriteModel)
        XCTAssertTrue(Mode.LLM.API.s1.accepts(modelName: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
        XCTAssertFalse(Mode.LLM.API.s1.accepts(modelName: "gemma4:12b-it-qat"))
        XCTAssertTrue(Mode.LLM.API.chat.accepts(modelName: "gemma4:12b-it-qat"))
        XCTAssertFalse(Mode.LLM.API.chat.accepts(modelName: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
        XCTAssertFalse(Mode.LLM.API.chat.accepts(modelName: "nomic-embed-text:latest"))
    }

    func testSwitchingKindResetsModelAndInstructionsOnly() {
        var mode = Mode.prompt
        mode.name = "Meeting"; mode.llm.api = .chat; mode.llm.model = "gemma4:12b-it-qat"
        mode.instructions = "Rewrite as bullet points."
        let switched = mode.switching(to: .s1)
        XCTAssertEqual(switched.llm.api, .s1)
        XCTAssertEqual(switched.llm.model, Mode.cleanupModel)
        XCTAssertEqual(switched.instructions, Mode.LLM.API.s1.defaultInstructions)
        XCTAssertEqual(switched.name, "Meeting")
        XCTAssertEqual(switched.stt, mode.stt)
    }

    func testANonProtectedModeNeedsARefinerInTheEditor() {
        var off = Mode.prompt; off.llm.enabled = false
        XCTAssertEqual(off.editorValidationError(original: .prompt), .refinerRequired)
        XCTAssertNil(off.validationError, "files with the refiner off must still load")
        XCTAssertNil(Mode.voice.editorValidationError(original: .voice), "Voice is the exception")
    }

    /// S1's dialect accepts only its control line -- `Mode.validate()` refuses prose on `.s1` --
    /// so its default has to be one, or a freshly-switched S1 mode would refuse to save.
    func testTheS1DefaultInstructionsAreControlFieldsOnly() {
        XCTAssertTrue(Mode.containsOnlyControlFields(Mode.LLM.API.s1.defaultInstructions))
    }

    /// A general model reads its instructions as a system prompt, not a control line: the default
    /// has to be actual prose to edit from, distinct from S1's, or switching to `.chat` would
    /// leave `[Context: general]` sitting in the prompt editor as if it were literal text.
    func testTheChatDefaultInstructionsAreProse() {
        let chatDefault = Mode.LLM.API.chat.defaultInstructions
        XCTAssertFalse(chatDefault.isEmpty)
        XCTAssertFalse(Mode.containsOnlyControlFields(chatDefault))
        XCTAssertNotEqual(chatDefault, Mode.LLM.API.s1.defaultInstructions)
    }
}

extension Mode {
    fileprivate func with(_ mutate: (inout Mode) -> Void) -> Mode {
        var copy = self
        mutate(&copy)
        return copy
    }
}
