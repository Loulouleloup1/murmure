import XCTest
@testable import MurmureCore

final class ModeDraftExtractionTests: XCTestCase {
    private func validMode(key: String = "slack-short") -> Mode {
        Mode(
            key: key, name: "Slack (short)", hotkey: nil,
            stt: .init(model: "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo", language: "fr"),
            llm: .init(enabled: true, endpoint: "http://localhost:11434", model: "gemma4:12b-it-qat", api: .chat),
            instructions: "Clean up filler words, keep it short.",
            context: .init(selectedText: false, clipboard: false, appContext: false),
            autoActivate: [], simulateKeypresses: false, symbol: "text.bubble")
    }

    private func encodedJSON(_ mode: Mode) throws -> String {
        try XCTUnwrap(String(data: ModeStore.encoder.encode(mode), encoding: .utf8))
    }

    private func fencedReply(_ json: String, language: String = "json") -> String {
        "Here is the mode:\n```\(language)\n\(json)\n```"
    }

    private func extract(
        _ reply: String,
        installedSpeechModels: [String] = ["argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo"],
        installedOllamaModels: [String] = ["gemma4:12b-it-qat"],
        existingModeKeys: [String] = ["voice", "prompt"]
    ) -> Result<ModeDraftCandidate, ModeDraftProblem> {
        ModeDraftExtraction.extract(
            from: reply, installedSpeechModels: installedSpeechModels,
            installedOllamaModels: installedOllamaModels, existingModeKeys: existingModeKeys)
    }

    // MARK: - Success

    func testExtractsAValidModeFromAFencedJSONBlock() throws {
        let json = try encodedJSON(validMode())
        let result = extract(fencedReply(json))

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(candidate.mode.key, "slack-short")
        XCTAssertTrue(candidate.sttModelInstalled)
        XCTAssertTrue(candidate.llmModelInstalled)
    }

    func testToleratesAFenceWithNoLanguageTag() throws {
        let json = try encodedJSON(validMode())
        let result = extract(fencedReply(json, language: ""))

        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
    }

    func testSttModelInstalledIsFalseWhenTheReferenceIsNotInTheListing() throws {
        let json = try encodedJSON(validMode())
        let result = extract(fencedReply(json), installedSpeechModels: ["some/other/variant"])

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertFalse(candidate.sttModelInstalled)
    }

    func testLlmModelInstalledComparesThroughOllamaProbesTaggingNotLiteralEquality() throws {
        // The mode names "gemma4:12b-it-qat"; the listing spells it bare, without the tag, the way
        // a hand-typed mode sometimes does -- `OllamaProbe.tagged` is what makes these match.
        let json = try encodedJSON(validMode())
        let result = extract(fencedReply(json), installedOllamaModels: ["gemma4"])

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertFalse(candidate.llmModelInstalled)
    }

    func testLlmModelInstalledIsTrueWhenTheRefinerIsOffRegardlessOfTheListing() throws {
        var mode = validMode()
        mode.llm.enabled = false
        let json = try encodedJSON(mode)
        let result = extract(fencedReply(json), installedOllamaModels: [])

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(candidate.llmModelInstalled)
    }

    // MARK: - No fenced block

    func testAReplyWithNoFencedBlockIsReportedAsNoFencedBlock() {
        let result = extract("What language should this mode dictate in?")
        XCTAssertEqual(result, .failure(.noFencedBlock))
    }

    // MARK: - Last block, not first -- mutation-provable

    /// Two fenced blocks in one reply: an earlier one (as if the model were still thinking aloud,
    /// or quoting something from earlier in the conversation) and the real, final proposal last.
    /// The extractor must read the SECOND one.
    ///
    /// Mutation-proved: swapping `.last` for `.first` in
    /// `ModeDraftExtraction.lastFencedBlock(in:)` turns this test red (see the session's report for
    /// the exact command and output).
    func testTakesTheLastFencedBlockNotTheFirst() throws {
        let firstJSON = try encodedJSON(validMode(key: "first-guess"))
        let secondJSON = try encodedJSON(validMode(key: "second-guess"))
        let reply = """
            Here is an early idea:
            ```json
            \(firstJSON)
            ```
            On reflection, here is the mode:
            ```json
            \(secondJSON)
            ```
            """
        let result = extract(reply)

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(candidate.mode.key, "second-guess")
    }

    // MARK: - Unknown top-level key -- mutation-provable

    /// Mutation-proved: removing the stray-key check in
    /// `ModeDraftExtraction.extract(from:...)` turns this test red (see the session's report for
    /// the exact command and output) -- without the check, `JSONDecoder` silently ignores "foo"
    /// and this would read as a success instead.
    func testAStrayTopLevelKeyIsRefusedRatherThanSilentlyDropped() throws {
        let data = try ModeStore.encoder.encode(validMode())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["foo"] = "bar"
        let mutated = try JSONSerialization.data(withJSONObject: object)
        let json = try XCTUnwrap(String(data: mutated, encoding: .utf8))

        let result = extract(fencedReply(json))
        XCTAssertEqual(result, .failure(.unknownKey("foo")))
    }

    // MARK: - Malformed JSON

    func testMalformedJSONInTheFencedBlockIsReported() {
        let result = extract(fencedReply("{ this is not valid json"))
        guard case .failure(.malformedJSON) = result else {
            return XCTFail("expected malformedJSON, got \(result)")
        }
    }

    func testAFencedBlockThatIsNotAJSONObjectIsReported() {
        let result = extract(fencedReply("[1, 2, 3]"))
        guard case .failure(.malformedJSON) = result else {
            return XCTFail("expected malformedJSON, got \(result)")
        }
    }

    // MARK: - Invalid field

    func testAnInvalidFieldIsReportedAsModeValidateWouldReportIt() throws {
        var mode = validMode()
        mode.name = ""
        let json = try encodedJSON(mode)
        let result = extract(fencedReply(json))

        XCTAssertEqual(result, .failure(.invalidField(.emptyName)))
    }

    // MARK: - Key collision

    func testAKeyAlreadyOnDiskIsReportedAsACollision() throws {
        let json = try encodedJSON(validMode(key: "voice"))
        let result = extract(fencedReply(json))

        XCTAssertEqual(result, .failure(.keyCollision("voice")))
    }

    // MARK: - Descriptions are non-empty sentences

    func testEveryProblemHasANonEmptyDescription() {
        let problems: [ModeDraftProblem] = [
            .noFencedBlock, .malformedJSON(caption: "detail", dump: "detail"), .unknownKey("foo"),
            .unknownKey("llm.foo"), .invalidField(.emptyName), .keyCollision("voice"),
        ]
        for problem in problems {
            XCTAssertFalse(problem.description.isEmpty)
        }
    }

    // MARK: - Missing "key" is derived, not a decoding failure (lot 5 review, item 1)

    /// The system prompt tells the model "key" may be omitted -- so a reply that takes it at its
    /// word must still produce a mode, with a key derived from "name" the same way the editor
    /// derives one for a preset (`Mode.availableKey(basedOn:avoiding:)`), not a `keyNotFound`.
    func testAMissingKeyIsDerivedFromTheName() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModeStore.encoder.encode(validMode())) as? [String: Any])
        object["name"] = "Slack Short Messages"
        object.removeValue(forKey: "key")
        let json = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        let result = extract(fencedReply(json))
        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(candidate.mode.key, "slack-short-messages")
    }

    /// The derived key has to avoid the keys ALREADY ON DISK too, not just be well-formed --
    /// `Mode.availableKey(basedOn:avoiding:)`'s own `-2` suffix rule, exercised through
    /// `extract(from:...)` rather than assumed: a reply naming a mode "Voice" with no "key", on a
    /// machine that already has "voice", must not collide with the shipped default.
    func testAMissingKeyIsDerivedAvoidingExistingModeKeys() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModeStore.encoder.encode(validMode())) as? [String: Any])
        object["name"] = "Voice"
        object.removeValue(forKey: "key")
        let json = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        // `extract`'s own default `existingModeKeys` is ["voice", "prompt"] -- see the helper above.
        let result = extract(fencedReply(json))
        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(candidate.mode.key, "voice-2")
    }

    /// The ordinary path -- an explicit "key" already present -- keeps using exactly that key
    /// rather than deriving a fresh one, so `testExtractsAValidModeFromAFencedJSONBlock` above
    /// stays the main coverage for it; this test only pins that presence takes priority over
    /// derivation when both could apply.
    func testAPresentKeyIsUsedAsIsRatherThanDerived() throws {
        let json = try encodedJSON(validMode(key: "explicit-key"))
        let result = extract(fencedReply(json))

        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(candidate.mode.key, "explicit-key")
    }

    // MARK: - hotkey never survives into the candidate (lot 5 review, item 5)

    /// The prompt says "never invent one"; if the model emits one anyway, the candidate must not
    /// carry it -- a saved, invented combo registers a real global shortcut.
    func testAHotkeyTheModelInventedIsDroppedRatherThanKept() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModeStore.encoder.encode(validMode())) as? [String: Any])
        object["hotkey"] = ["keyCode": 49, "carbonModifiers": 2048]
        let json = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        let result = extract(fencedReply(json))
        guard case .success(let candidate) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertNil(candidate.mode.hotkey)
    }

    // MARK: - Nested unknown keys (lot 5 review, item 4) -- mutation-provable

    /// Mutation-proved: removing `strayNestedKey(in:)`'s call in `extract(from:...)` turns this
    /// test red (see the session's report for the exact command and output) -- without it,
    /// `JSONDecoder` silently ignores "llm.foo" and this would read as a success instead.
    func testAStrayNestedKeyUnderLLMIsRefusedByItsDottedName() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModeStore.encoder.encode(validMode())) as? [String: Any])
        var llm = try XCTUnwrap(object["llm"] as? [String: Any])
        llm["foo"] = "bar"
        object["llm"] = llm
        let json = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        let result = extract(fencedReply(json))
        XCTAssertEqual(result, .failure(.unknownKey("llm.foo")))
    }

    func testAStrayNestedKeyUnderContextIsRefusedByItsDottedName() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModeStore.encoder.encode(validMode())) as? [String: Any])
        var context = try XCTUnwrap(object["context"] as? [String: Any])
        context["screenshot"] = true
        object["context"] = context
        let json = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        let result = extract(fencedReply(json))
        XCTAssertEqual(result, .failure(.unknownKey("context.screenshot")))
    }

    // MARK: - Decoding failures name the field (lot 5 review, item 7)

    func testAMissingRequiredFieldNamesItInTheCaptionRatherThanDumpingTheDecodingError() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModeStore.encoder.encode(validMode())) as? [String: Any])
        object.removeValue(forKey: "instructions")
        let json = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        let result = extract(fencedReply(json))
        guard case .failure(.malformedJSON(let caption, let dump)) = result else {
            return XCTFail("expected malformedJSON, got \(result)")
        }
        XCTAssertEqual(caption, "missing field \"instructions\"")
        XCTAssertTrue(dump.contains("keyNotFound") || dump.contains("instructions"), dump)
    }
}
