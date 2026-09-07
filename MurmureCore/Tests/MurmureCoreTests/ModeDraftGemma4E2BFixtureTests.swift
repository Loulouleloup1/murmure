import XCTest
@testable import MurmureCore

/// Offline test over a REAL reply, saved verbatim from the one live conversation this lot's own
/// verification ran (`benchmark/modedraftconvo`, gated `MURMURE_NETWORK_TESTS=1`): the system
/// prompt this package builds (`ModeDraftSystemPrompt`), plus the French request "Un mode pour
/// dicter des messages Slack courts, en français, tutoiement, sans emoji", sent to
/// `gemma4:e2b-it-qat` (the small, 4.3 GB model) over `/api/chat`, non-streaming, one request.
///
/// The model answered on its FIRST turn -- a short explanation, a clarifying question about which
/// speech model to use, AND one fenced ```json block holding a complete mode, in the SAME turn --
/// so no prompt iteration was needed; this fixture is that reply, unedited. (Both runs of this
/// conversation did this: the clarifying-question-first instruction and the "answer with a block"
/// instruction are both honoured, just not in strictly separate turns the way the system prompt's
/// own wording implies -- observed, not what was asked for. See `docs/plans/2026-09-backlog.md`
/// §8.)
///
/// This is the SECOND live capture (lot 5 review, item 3): the first one had the schema example's
/// literal `autoActivate: ["com.apple.Terminal"]` copied verbatim into the answer. That example is
/// now `autoActivate: []`, and this fixture's own `autoActivate` came back empty on the re-run --
/// `testTheDraftDoesNotCopyTheSchemaExamplesAutoActivateEntry` below pins that.
final class ModeDraftGemma4E2BFixtureTests: XCTestCase {
    private func fixtureReply() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "mode-draft-reply-gemma4-e2b", withExtension: "txt", subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture mode-draft-reply-gemma4-e2b.txt")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheRealReplyExtractsToAValidMode() throws {
        let reply = try fixtureReply()
        XCTAssertFalse(reply.isEmpty)

        let result = ModeDraftExtraction.extract(
            from: reply,
            installedSpeechModels: [
                "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo",
            ],
            installedOllamaModels: [
                "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", "gemma4:e2b-it-qat", "gemma4:12b-it-qat",
                "nomic-embed-text:latest", "mxbai-embed-large:latest",
            ],
            existingModeKeys: ["voice", "prompt"])

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(candidate.mode.key, "slack_fr")
        XCTAssertEqual(candidate.mode.stt.language, "fr")
        XCTAssertEqual(candidate.mode.llm.api, .chat)
        XCTAssertTrue(candidate.sttModelInstalled)
        XCTAssertTrue(candidate.llmModelInstalled)
        XCTAssertNoThrow(try candidate.mode.validate())
    }

    /// The concrete regression item 3 was raised over: on the first live run this field came back
    /// `["com.apple.Terminal"]`, copied straight out of the schema example -- and `useDraftedMode`
    /// lands on the Basic screen, where Auto-activate is not shown, so a candidate carrying that
    /// would silently hijack dictation in Terminal the moment it was saved unreviewed.
    func testTheDraftDoesNotCopyTheSchemaExamplesAutoActivateEntry() throws {
        let result = ModeDraftExtraction.extract(
            from: try fixtureReply(), installedSpeechModels: [], installedOllamaModels: [],
            existingModeKeys: [])

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(candidate.mode.autoActivate, [])
    }

    /// A collision against a mode the real machine already has must still be caught on this real
    /// reply, exactly as it would be on any other.
    func testTheRealReplyCollidesWhenItsKeyIsAlreadyTaken() throws {
        let result = ModeDraftExtraction.extract(
            from: try fixtureReply(), installedSpeechModels: [], installedOllamaModels: [],
            existingModeKeys: ["slack_fr"])

        XCTAssertEqual(result, .failure(.keyCollision("slack_fr")))
    }
}
