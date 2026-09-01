import XCTest
@testable import MurmureCore

/// A `RefinementClient` that answers whatever the test tells it to, and records what it was
/// asked. No network, no Ollama, no server: every behaviour below is reachable with this.
private final class StubClient: RefinementClient {
    struct Call: Equatable {
        let transcript: String
        let instructions: String
        let model: String
        let endpoint: URL
    }

    var outcome: OllamaOutcome
    private(set) var calls: [Call] = []
    /// Recorded beside `calls` rather than inside it, so the claims already pinned on `Call`
    /// keep saying exactly what they said before `api` existed.
    private(set) var apis: [Mode.LLM.API] = []

    init(_ outcome: OllamaOutcome) {
        self.outcome = outcome
    }

    func refine(
        transcript: String, instructions: String, model: String, endpoint: URL,
        api: Mode.LLM.API
    ) async -> OllamaOutcome {
        calls.append(Call(
            transcript: transcript, instructions: instructions, model: model, endpoint: endpoint))
        apis.append(api)
        return outcome
    }
}

/// A client that fails the test if it is ever reached. Used for the passthrough mode, where the
/// behaviour under test is that no call happens at all.
private final class UnreachableClient: RefinementClient {
    func refine(
        transcript: String, instructions: String, model: String, endpoint: URL,
        api: Mode.LLM.API
    ) async -> OllamaOutcome {
        XCTFail("a mode with llm.enabled == false must not reach the client")
        return .refined("this must never be inserted")
    }
}

private func mode(
    llm enabled: Bool, model: String = "gemma4:12b-it-qat",
    instructions: String = "Clean this up.", endpoint: String = "http://localhost:11434",
    api: Mode.LLM.API = .chat
) -> Mode {
    Mode(
        key: "test", name: "Test",
        stt: .init(model: "large-v3-turbo", language: "fr"),
        llm: .init(enabled: enabled, endpoint: endpoint, model: model, api: api),
        instructions: instructions,
        context: .init(selectedText: false, clipboard: false, appContext: false),
        autoActivate: [], simulateKeypresses: false)
}

final class TranscriptRefinerTests: XCTestCase {
    // MARK: - No LLM: passthrough

    /// `Voice` is the default mode and the daily driver, and lot 1's dictation works today. The
    /// text must come out of this layer as the same bytes that went in -- not "equal after
    /// trimming", not "equal after normalising". Compared as UTF-8 because that is what the
    /// claim says, and because `==` on `String` compares canonical equivalence, which would let
    /// a decomposed "é" pass as an unchanged "é".
    func testAModeWithoutLlmReturnsTheTranscriptByteForByte() async {
        let raw = "  euh donc\u{00E9}\u{0301} voil\u{00E0} — «\u{00A0}slash\u{00A0}» 🙂\n\n\ttab\t "
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: UnreachableClient()) { notices.append($0) }

        let result = await refiner.refine(raw, with: mode(llm: false))

        XCTAssertEqual(Array(result.utf8), Array(raw.utf8))
        // Nothing happened, so there is nothing to tell anyone. A notice on every `Voice`
        // dictation would be noise, and noise is how a real notice gets ignored.
        XCTAssertEqual(notices, [])
    }

    // MARK: - LLM: the call and the answer

    func testTheModeSuppliesTheInstructionsModelAndEndpointOfTheCall() async {
        let client = StubClient(.refined("Donc voilà."))
        let refiner = TranscriptRefiner(client: client) { _ in }

        let result = await refiner.refine(
            "euh donc voilà",
            with: mode(llm: true, model: "gemma3:4b", instructions: "Be terse.",
                       endpoint: "http://127.0.0.1:11434"))

        XCTAssertEqual(result, "Donc voilà.")
        XCTAssertEqual(client.calls, [StubClient.Call(
            transcript: "euh donc voilà", instructions: "Be terse.", model: "gemma3:4b",
            endpoint: URL(string: "http://127.0.0.1:11434")!)])
    }

    /// The fifth thing the mode supplies, and the one that decides which of Ollama's two APIs the
    /// call goes to. It travels per call and not per client: one client serves every mode, and
    /// two modes on the same server speak different protocols.
    func testTheModeAlsoSuppliesTheProtocolTheModelSpeaks() async {
        let client = StubClient(.refined("Donc voilà."))
        let refiner = TranscriptRefiner(client: client) { _ in }

        _ = await refiner.refine("euh donc voilà",
                                 with: mode(llm: true, instructions: "[Context: general]", api: .s1))
        _ = await refiner.refine("euh donc voilà", with: mode(llm: true, api: .chat))

        XCTAssertEqual(client.apis, [.s1, .chat])
    }

    func testASuccessfulRefinementIsSilent() async {
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: StubClient(.refined("Donc voilà."))) {
            notices.append($0)
        }

        _ = await refiner.refine("euh donc voilà", with: mode(llm: true))

        XCTAssertEqual(notices, [])
    }

    // MARK: - A failed refinement never costs the dictation

    /// Spec §9. Louis has just spoken; that text exists nowhere else. Whatever went wrong, what
    /// comes out of this layer is what he said.
    func testAFailedRefinementReturnsTheRawTranscript() async {
        let refiner = TranscriptRefiner(client: StubClient(.failed(.notRunning(detail: "-1004")))) {
            _ in
        }

        let result = await refiner.refine("euh donc voilà", with: mode(llm: true))

        XCTAssertEqual(result, "euh donc voilà")
    }

    /// The fallback has to be *visible*: given raw text with no word about it, Louis concludes
    /// the refiner does nothing rather than that Ollama is down.
    func testAFailedRefinementIsReported() async {
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: StubClient(.failed(.modelNotPulled(model: "g")))) {
            notices.append($0)
        }

        _ = await refiner.refine("euh donc voilà", with: mode(llm: true))

        XCTAssertEqual(notices, [.fellBackToTranscript(.modelNotPulled(model: "g"))])
    }

    /// The six failures were distinguished because they have six different remedies. Crossing
    /// this layer must not flatten them into "refinement failed" -- which is the shape that is
    /// easy to reach for when adding a notice type.
    func testTheSixFailuresCrossThisLayerWithoutLosingTheirIdentity() async {
        let failures: [OllamaFailure] = [
            .notRunning(detail: "-1004 Could not connect to the server."),
            .modelNotPulled(model: "gemma4:12b-it-qat"),
            .timedOut(after: 7.8),
            .malformedResponse(detail: "HTTP 500: boom"),
            .truncated(kept: "Donc en fait, il faut qu'on"),
            .refused(reply: "Je ne peux pas vous aider."),
        ]

        var messages: Set<String> = []
        for failure in failures {
            var notices: [RefinementNotice] = []
            let refiner = TranscriptRefiner(client: StubClient(.failed(failure))) {
                notices.append($0)
            }

            let result = await refiner.refine("euh donc voilà", with: mode(llm: true))

            XCTAssertEqual(result, "euh donc voilà")
            XCTAssertEqual(notices, [.fellBackToTranscript(failure)])
            messages.formUnion(notices.map(\.message))
        }

        // Six failures in, six different sentences out. A notice case with no payload, or one
        // that only says "the refinement failed", collapses this to 1.
        XCTAssertEqual(messages.count, 6)
    }

    /// `truncated` is the one failure that arrives holding plausible-looking text: a grammatical
    /// fragment that reads like a finished refinement. Inserting it is the invisible corruption
    /// the pinned `num_predict` exists to prevent, so the fragment must lose to the transcript.
    func testATruncatedAnswerIsNotInsertedInsteadOfTheTranscript() async {
        let fragment = "Donc en fait, il faut qu'on"
        let refiner = TranscriptRefiner(client: StubClient(.failed(.truncated(kept: fragment)))) {
            _ in
        }

        let result = await refiner.refine("euh donc en fait il faut qu'on avance", with: mode(llm: true))

        XCTAssertEqual(result, "euh donc en fait il faut qu'on avance")
        XCTAssertNotEqual(result, fragment)
    }

    /// An `llm.endpoint` that is not a URL never reaches this layer through `ModeStore`, which
    /// validates. It reaches it from a `Mode` built in code -- and the answer is the same as any
    /// other failure: the transcript, plus the field to fix.
    func testAnEndpointThatIsNotAUrlFallsBackAndNamesTheField() async {
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: StubClient(.refined("never"))) {
            notices.append($0)
        }

        let result = await refiner.refine(
            "euh donc voilà", with: mode(llm: true, endpoint: "not a url"))

        XCTAssertEqual(result, "euh donc voilà")
        XCTAssertEqual(notices, [.modeIsUnusable(.invalidLLMEndpoint("not a url"))])
    }

    /// The invalid field that actually matters, and the reason this layer validates instead of
    /// letting the client find out. An empty `instructions` is a well-formed request Ollama
    /// answers happily -- with a plausible answer to nothing, which would then be pasted as what
    /// Louis said. The bad value is invisible in the output, so it has to be caught before the
    /// call rather than recognised after it.
    func testAModeWhoseInstructionsAreEmptyNeverReachesTheModel() async {
        let client = StubClient(.refined("Bien sûr ! Voici le texte corrigé :"))
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: client) { notices.append($0) }

        let result = await refiner.refine(
            "euh donc voilà", with: mode(llm: true, instructions: "   "))

        XCTAssertEqual(client.calls, [])
        XCTAssertEqual(result, "euh donc voilà")
        XCTAssertEqual(notices, [.modeIsUnusable(.emptyInstructions)])
    }

    // MARK: - The no-op guard

    /// The documented failure of a too-small model: it returns its input, politely. Measured
    /// here -- `gemma3:4b` returned a benchmark fixture identical to the character.
    func testAnAnswerIdenticalToTheTranscriptIsFlagged() async {
        let raw = "Donc voilà, c'est fait."
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: StubClient(.refined(raw))) { notices.append($0) }

        let result = await refiner.refine(raw, with: mode(llm: true, model: "gemma3:4b"))

        XCTAssertEqual(notices, [.modelChangedNothing(model: "gemma3:4b")])
        // Signalled, not rejected: the text is still the model's answer, and the caller still
        // gets something to insert. The literature's remedy is caller-side detection, not a
        // retry and not a refusal.
        XCTAssertEqual(result, raw)
    }

    /// An echo with a stray newline is still an echo. The shipped client trims before it hands
    /// the answer over, so in production this is already gone -- the guard must not be
    /// defeatable by an invisible character it happens not to see today.
    func testAnEchoDifferingOnlyInSurroundingWhitespaceIsStillFlagged() async {
        let raw = "Donc voilà, c'est fait."
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: StubClient(.refined("\n  \(raw)  \n"))) {
            notices.append($0)
        }

        let result = await refiner.refine(raw, with: mode(llm: true, model: "gemma3:4b"))

        XCTAssertEqual(notices, [.modelChangedNothing(model: "gemma3:4b")])
        // Handed back exactly as the model sent it. Flagging is not rejecting: the guard does
        // not substitute the transcript, does not trim, and does not retry.
        XCTAssertEqual(result, "\n  \(raw)  \n")
    }

    /// The other half of the guard, and the half that decides where the line sits. Adding a
    /// capital and a full stop is operation 2 of the shipped `Prompt` instructions -- it is the
    /// job being done, not the absence of it. A guard that normalised case and punctuation
    /// before comparing would call this "the model did nothing", and a notice that fires on
    /// correct work is a notice Louis stops reading.
    func testAnAnswerDifferingOnlyByCapitalisationAndAFullStopIsNotFlagged() async {
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: StubClient(.refined("Donc voilà."))) {
            notices.append($0)
        }

        let result = await refiner.refine("donc voilà", with: mode(llm: true))

        XCTAssertEqual(notices, [])
        XCTAssertEqual(result, "Donc voilà.")
    }

    /// Whisper already produces clean, punctuated French, so a transcript that comes back nearly
    /// unchanged is the normal case and not a defect -- the anti-over-correction finding is that
    /// changing nothing must stay a valid answer. One deleted filler is enough to be silent.
    func testAnAlreadyCleanTranscriptComingBackNearlyUnchangedIsNotFlagged() async {
        let raw = "Il faut qu'on regarde le fichier euh DictationSession.swift avant de merger."
        let refined = "Il faut qu'on regarde le fichier DictationSession.swift avant de merger."
        var notices: [RefinementNotice] = []
        let refiner = TranscriptRefiner(client: StubClient(.refined(refined))) {
            notices.append($0)
        }

        let result = await refiner.refine(raw, with: mode(llm: true))

        XCTAssertEqual(notices, [])
        XCTAssertEqual(result, refined)
    }
}
