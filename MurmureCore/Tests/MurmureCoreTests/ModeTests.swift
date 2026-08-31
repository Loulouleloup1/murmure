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

    func testTheFourBuiltInsAreValidAndOnlyVoiceSkipsTheLLM() throws {
        XCTAssertEqual(Mode.builtIns.map(\.key), ["voice", "prompt", "message", "email"])
        for mode in Mode.builtIns {
            XCTAssertNoThrow(try mode.validate(), mode.key)
        }

        XCTAssertFalse(Mode.voice.llm.enabled)
        XCTAssertTrue(Mode.voice.instructions.isEmpty)
        for mode in [Mode.prompt, .message, .email] {
            XCTAssertTrue(mode.llm.enabled, mode.key)
            XCTAssertFalse(mode.instructions.isEmpty, mode.key)
        }
    }

    /// Measured on the whole 1 449-dictation corpus (lot 2 plan): `detectLanguage` re-evaluates per
    /// window and produced non-Latin transcripts. The default must not reintroduce it.
    func testEveryBuiltInPinsTheDecoderToFrench() {
        for mode in Mode.builtIns {
            XCTAssertEqual(mode.stt.language, "fr", mode.key)
        }
    }
}

extension Mode {
    fileprivate func with(_ mutate: (inout Mode) -> Void) -> Mode {
        var copy = self
        mutate(&copy)
        return copy
    }
}
