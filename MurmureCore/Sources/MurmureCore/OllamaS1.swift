import Foundation

/// The wire shape of a refinement call to a model that speaks its own conversation format, and
/// the reading of what comes back.
///
/// The sibling of ``OllamaChat`` and the reason ``Mode/LLM/api`` exists. `s1-mini` cannot be
/// driven through `/api/chat` at all -- measured, it answers with **empty content**, because the
/// model opens its turn with a `<think>` block and Ollama's chat layer takes that for reasoning
/// and keeps it. So the conversation is written out by hand and posted to `/api/generate` with
/// `raw: true`, which tells Ollama to send the string through untouched.
///
/// Everything here is data: a template, five options and a way to read one JSON field. It lives
/// in `MurmureCore` because the app target has no test bundle, and because a hand-written
/// conversation template is exactly the kind of thing that has to be pinned by a test -- one
/// wrong newline and the model answers something plausible about the wrong input.
public enum OllamaS1 {
    // MARK: - The conversation

    /// The system turn, fixed by the model card and not a prompt to tune.
    ///
    /// The v3 grid dropped every off-template variant for this reason: a verdict measured on a
    /// model used outside the format it was trained on is a verdict about the misuse. Louis's
    /// half of the interface is the control line in ``Mode/instructions``, not this.
    public static let systemPrompt = """
        You are a text normalizer for speech-to-text transcripts. The input begins with a \
        control line specifying the styling, structure, and context settings; clean the \
        transcript to match those settings and output only the cleaned text.
        """

    /// One conversation: the fixed system turn, then the control line and the transcript as the
    /// user turn, then an assistant turn already opened.
    ///
    /// The assistant turn ends on an **empty, already-closed** `<think>` block. That is the
    /// whole trick: the model's format opens one, so leaving it to the model means paying for a
    /// reasoning pass on a task that needs none -- and, through `/api/chat`, getting nothing but
    /// that reasoning back. Prefilled and closed, generation starts at the cleaned text.
    ///
    /// Written as concatenated fragments rather than a multi-line literal so that every newline
    /// is visible where it is: the template ends on two of them, and a multi-line literal drops
    /// the last one.
    public static func conversation(control: String, transcript: String) -> String {
        "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
            + "<|im_start|>user\n\(control)\n\(transcript)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Where a turn ends. Sent as options because the conversation is raw: nothing else tells
    /// Ollama that `<|im_end|>` closes the answer, and without them the model keeps going and
    /// opens the next turn itself.
    public static let stop = ["<|im_end|>", "<|im_start|>"]

    // MARK: - Pinned options
    //
    // Four values that Ollama does not default to, and the failure each one prevents. None of
    // them is a preference and none is configurable: measured, the model's own modelfile
    // defaults corrupt a real dictation while returning HTTP 200.

    /// Zero, and this is the one that matters most.
    ///
    /// The model's modelfile ships `temperature: 0.6`, and nothing warns about it. Over 21 real
    /// dictations that default returns **2.52x the input's length on average**, worst case a
    /// 44-word dictation answered with 1 402 words -- the same fragment repeated over and over
    /// until the token cap. At 0 the same 21 come back at 0.99x, worst case 1.00x.
    public static let temperature = 0.0

    /// The second half of the same fix, and its useful window is narrow.
    ///
    /// Measured on the arm where the runaways actually happen (3 fixtures the model loops on,
    /// `[Styling: casual]`): repeat penalty 1.0 loops on 5 runs out of 5, 1.05 on 1 of 5, **1.1
    /// on 0 of 5**, and 1.2 loops again on 2 of 5. Higher is not safer -- 1.2 pushes the model
    /// off its own text and it starts inventing.
    ///
    /// Under the shipped control line no runaway was seen even without it. It stays because the
    /// control line is hand-editable and a runaway is not a slightly worse refinement: it is
    /// 1 400 words of repetition where 44 were dictated.
    public static let repeatPenalty = 1.1

    /// The same seed the benchmark generated its 784 refinements under, so a refinement in the
    /// app is reproducible against the evidence rather than merely deterministic in isolation.
    public static let seed = OllamaChat.seed

    /// Same cap as the chat dialect, for the same reason: a dictation must not be answered with
    /// a sentence cut in half. The longest answer measured here is 740 tokens.
    public static let numPredict = OllamaChat.numPredict

    /// Half the chat dialect's window, and that is the point of this model.
    ///
    /// 4096 is what holds the resident footprint at 1.08 GB against 8.63 for `gemma4:12b-it-qat`
    /// -- the number that lets Murmure run on a 16 GB machine. It is not tight: the longest
    /// dictation in the whole 1 449-dictation corpus (531 words) is 804 prompt tokens and 740
    /// completion tokens, 1 544 of 4 096. Measured across the sweep, 2048 already produces the
    /// identical answer and 8192 changes nothing but the footprint.
    public static let numContext = 4096

    /// Refuse the call rather than silently shorten the input, and this is the whole reason
    /// ``OllamaFailure/tooLongForTheContext(window:)`` can exist.
    ///
    /// Ollama's default is to truncate a prompt that does not fit **from the front**, answer 200
    /// and say nothing: measured at `num_ctx` 512 on a real 531-word dictation, `prompt_eval_count`
    /// came back 258 instead of 804 and the answer began a third of the way in, with
    /// `done_reason: "stop"` like any healthy call. With this flag the same request answers
    /// `400 exceed_context_size_error`, naming both numbers.
    ///
    /// Not sent on the chat dialect: measured on the same server, `/api/chat` ignores it.
    public static let truncate = false

    // MARK: - The request

    /// The generate endpoint for a mode's configured base URL. Same rule as
    /// ``OllamaChat/endpoint(base:)``: the base is the root and is never edited.
    public static func endpoint(base: URL) -> URL {
        base.appending(path: "api/generate")
    }

    /// The JSON body for one refinement.
    ///
    /// `instructions` is the mode's control line, not a system prompt -- see ``Mode/LLM/API/s1``.
    /// It is dropped in verbatim: `Mode.validationError` has already refused anything that is not
    /// bracketed fields, because prose here comes back inside Louis's text.
    ///
    /// Total rather than `throws`, for the same reason as ``OllamaChat/requestBody(model:instructions:transcript:)``:
    /// every field is a `String`, `Int`, `Double`, `Bool` or an array of strings, so there is no
    /// value this encoder can refuse.
    public static func requestBody(model: String, instructions: String, transcript: String) -> Data {
        try! JSONEncoder().encode(Request(
            model: model,
            prompt: conversation(control: instructions, transcript: transcript),
            raw: true,
            stream: false,
            truncate: truncate,
            options: Options(
                temperature: temperature, repeatPenalty: repeatPenalty, seed: seed,
                numPredict: numPredict, numContext: numContext, stop: stop)
        ))
    }

    private struct Request: Encodable {
        let model: String
        let prompt: String
        /// The reason this dialect exists. `raw: true` tells Ollama to send `prompt` through
        /// exactly as written instead of running it through the model's chat template -- which
        /// is what makes a hand-written conversation possible, and what the empty `<think>`
        /// prefill needs to survive.
        let raw: Bool
        let stream: Bool
        let truncate: Bool
        let options: Options
    }

    private struct Options: Encodable {
        let temperature: Double
        let repeatPenalty: Double
        let seed: Int
        let numPredict: Int
        let numContext: Int
        let stop: [String]

        /// Ollama's wire names, kept out of the property names so the Swift side reads like the
        /// rest of the package.
        enum CodingKeys: String, CodingKey {
            case temperature, seed, stop
            case repeatPenalty = "repeat_penalty"
            case numPredict = "num_predict"
            case numContext = "num_ctx"
        }
    }

    // MARK: - Reading the answer

    /// Reads one HTTP response into the outcome it means.
    ///
    /// Differs from ``OllamaChat/outcome(status:body:transcript:model:)`` in exactly two places:
    /// the 400 that ``truncate`` buys, and the field the text arrives in (`response`, not
    /// `message.content`). Everything after that -- empty, truncated, collapsed, refined -- is
    /// the same judgement on the same shared code, because what makes an answer unusable does
    /// not depend on the route it came back on.
    public static func outcome(
        status: Int, body: Data, transcript: String, model: String
    ) -> OllamaOutcome {
        // Matched on the machine-readable `type` and never on the sentence around it. The lesson
        // is already in this package: `isMissingModel` once parsed a model name out of Ollama's
        // prose and broke when the wording changed a release later.
        if status == 400, OllamaChat.errorMessage(body)?.contains("exceed_context_size_error") == true {
            return .failed(.tooLongForTheContext(window: numContext))
        }
        if let failure = OllamaChat.statusFailure(status: status, body: body, model: model) {
            return .failed(failure)
        }

        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: body)
        } catch {
            return .failed(OllamaChat.unreadableBody(error, body))
        }
        return OllamaChat.verdict(
            on: answer.response, doneReason: answer.doneReason, transcript: transcript)
    }

    private struct Answer: Decodable {
        /// `/api/generate` returns the text at the top level, where `/api/chat` nests it in a
        /// message. Decoding one body with the other's shape yields `malformedResponse`, which
        /// is what makes ``Mode/LLM/api`` a field that has to be right rather than a hint.
        let response: String
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case response
            case doneReason = "done_reason"
        }
    }
}
