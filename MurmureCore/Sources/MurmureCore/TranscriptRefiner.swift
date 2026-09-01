import Foundation

/// The one thing this step needs from the outside world: a transcript goes out, an outcome comes
/// back. `Murmure.OllamaClient` is the implementation; the tests use stubs, so nothing here needs
/// a server running.
///
/// The return type is ``OllamaOutcome`` and not `String?` on purpose. A `nil` says only "there is
/// no refined text", and the six reasons that can be true have six different remedies for Louis;
/// carrying the failure **in the return value** is what lets this layer say *why* he got raw text.
/// A failure delivered out of band -- through a callback the client was built with -- reaches the
/// log but not the code that has to decide what to insert.
public protocol RefinementClient {
    func refine(
        transcript: String, instructions: String, model: String, endpoint: URL
    ) async -> OllamaOutcome
}

/// Something Louis has to be told about a dictation that still produced text.
///
/// Every case here means the text was inserted anyway. That is the point: the dictation is never
/// lost (spec §9), and what changes is only whether the text is the refinement he expected.
public enum RefinementNotice: Equatable, CustomStringConvertible {
    /// The refinement did not happen; the raw transcript was used instead.
    ///
    /// The failure travels whole rather than as a message, because the six of them are six
    /// different actions -- start Ollama, pull a model, pick a faster model, dictate in shorter
    /// pieces, file a bug, change the instructions -- and flattening them here would undo the
    /// only reason ``OllamaFailure`` has six cases.
    case fellBackToTranscript(OllamaFailure)

    /// The model returned its input. Nothing is wrong with the text; the refiner did nothing.
    ///
    /// The documented failure of a too-small model, and the only remedy the minimal-edit
    /// literature offers is this one: detect it on the caller's side. Measured on our own
    /// benchmark -- `ornith-9b` scored a median disfluency of 0.0 while keeping a respectable
    /// overall score, and `gemma3:4b` returned a fixture identical to the character. The model
    /// name travels with it because "some model did nothing" is not something anyone can act on.
    case modelChangedNothing(model: String)

    /// The mode says to refine but is not valid, so no call was made. `ModeStore` validates on
    /// load and on save, so a mode from disk never lands here; a mode built in code can.
    ///
    /// It carries the field, not a message, for the same reason as above: `ModeValidationError`
    /// exists so a report can name the line to fix rather than say "invalid mode".
    case modeIsUnusable(ModeValidationError)

    /// The sentence a caller shows. English, like ``OllamaFailure/remedy`` and the app's other
    /// two failure enums; `AppState` is where user-facing French is produced.
    public var message: String {
        switch self {
        case .fellBackToTranscript(let failure):
            "Raw transcript inserted -- it was not refined. \(failure.remedy)"
        case .modelChangedNothing(let model):
            """
            \(model) returned the transcript unchanged. If it keeps doing that, it is too small \
            for this mode's instructions -- pick a larger model.
            """
        case .modeIsUnusable(let error):
            "Raw transcript inserted -- this mode cannot refine: \(error)."
        }
    }

    /// The line that goes in the log.
    public var description: String {
        switch self {
        case .fellBackToTranscript(let failure):
            "fell back to the raw transcript -- \(failure.description)"
        case .modelChangedNothing(let model): "no-op refinement from \(model)"
        case .modeIsUnusable(let error): "mode unusable: \(error)"
        }
    }
}

/// Raw transcript + mode → the text to insert.
///
/// Returns `String`, never `String?` and never `throws`: there is no dictation this step can
/// answer with nothing. Louis has just spoken, and that text exists nowhere else -- so when the
/// refinement cannot happen, the raw transcript is the answer, not an error. The fallback is the
/// feature.
public struct TranscriptRefiner {
    private let client: any RefinementClient
    private let report: (RefinementNotice) -> Void

    /// `report` has no default value, the same shape `ModeStore` and `PasteInserter` use and for
    /// the same reason (ruling L7): ``refine(_:with:)`` returns usable text in every case, so a
    /// refiner built without a consumer would hand Louis the raw transcript, or an answer its
    /// own model did not touch, without a word. There would be no way to notice from the outside.
    public init(client: any RefinementClient, report: @escaping (RefinementNotice) -> Void) {
        self.client = client
        self.report = report
    }

    public func refine(_ transcript: String, with mode: Mode) async -> String {
        // `Voice`, the default mode and the daily driver. Returned untouched -- not trimmed, not
        // normalised -- because lot 1's behaviour has to survive this lot byte for byte.
        guard mode.llm.enabled else { return transcript }

        // Checked here and not left to the client, because two of the fields it validates are
        // fields a bad value in cannot be seen coming out: an empty `instructions` sends the
        // model an empty system turn, and what comes back is a plausible answer to nothing --
        // pasted as what Louis said. `Mode.validationError` is reused rather than re-derived so
        // there is one definition of a usable mode.
        //
        // `URL(string:)` is not that check: it is lenient enough to accept "not a url" (it
        // percent-encodes the spaces), so the nil branch below is the arm the compiler needs and
        // not a case anything reaches -- `validationError` has already parsed the same string.
        guard mode.validationError == nil, let endpoint = URL(string: mode.llm.endpoint) else {
            report(.modeIsUnusable(mode.validationError ?? .invalidLLMEndpoint(mode.llm.endpoint)))
            return transcript
        }

        switch await client.refine(
            transcript: transcript, instructions: mode.instructions, model: mode.llm.model,
            endpoint: endpoint
        ) {
        case .refined(let text):
            if Self.isUnchanged(text, from: transcript) {
                report(.modelChangedNothing(model: mode.llm.model))
            }
            // Reported, and returned anyway. The guard signals; it never rejects and never
            // retries. A transcript that was already clean *should* come back nearly unchanged
            // -- the anti-over-correction finding is that "I changed nothing" has to stay a
            // valid answer -- so the caller keeps the text and decides for itself.
            return text
        case .failed(let failure):
            report(.fellBackToTranscript(failure))
            return transcript
        }
    }

    /// Where "the model did nothing" is drawn, and the two things that were rejected.
    ///
    /// **Whitespace at the edges is ignored.** An echo with a trailing newline is an echo, and
    /// the guard must not be defeatable by a character nobody can see. `OllamaChat.outcome`
    /// already trims, so this changes nothing in production -- it stops the guard from depending
    /// on that staying true.
    ///
    /// **Everything else is compared exactly, case included.** The tempting widening is to
    /// normalise case and punctuation, on the grounds that an answer differing from its input by
    /// one capital and one full stop "did nothing". Rejected, for two reasons. Adding
    /// capitalisation and punctuation is operation 2 of the three the shipped `Prompt`
    /// instructions ask for: it is the job being done, so calling it a no-op would flag correct
    /// work. And there is no measurement behind any wider equivalence -- the benchmark measured
    /// disfluency medians, not edit distances -- so a looser rule would be a guess, where this
    /// one fires only on something certain.
    ///
    /// The cost of the strict rule is real and accepted: a model that changes one comma and
    /// nothing else is not caught. That is the right way round. This is a signal, not a gate; a
    /// missed signal costs a hint, while a signal that fires on correct refinements is a signal
    /// Louis stops reading.
    private static func isUnchanged(_ answer: String, from transcript: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
            == transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
