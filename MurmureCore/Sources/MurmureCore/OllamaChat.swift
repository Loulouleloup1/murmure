import Foundation

/// Why a refinement produced no text, in terms of what Louis has to DO about it.
///
/// The whole point of this type is that these are **not** one failure. "The refinement failed"
/// is unusable: launching Ollama, pulling a model, waiting for a slower model, dictating a
/// shorter passage, reporting a bug and rewriting a prompt are six different actions, and the
/// message is the only thing that tells him which one he is in. `testEveryFailureCarriesItsOwnRemedy`
/// is the regression that keeps them from being merged back into one.
///
/// Deliberately **not** an `Error`. An `Error` can be thrown, and a thrown error can be
/// swallowed by `try?` at any call site — which is exactly the "failure mechanism with no
/// consumer" shape ruling L7 keeps catching. A value that is not an `Error` has to be received
/// and looked at.
public enum OllamaFailure: Equatable {
    /// Nothing answered on the loopback address at all.
    ///
    /// The claim is inferred, not observed: the endpoint is `localhost`, so there is no DNS, no
    /// TLS, no proxy and no network in between — every transport failure that is not a timeout
    /// means the server on the other end is not there. `detail` carries the underlying
    /// `URLError` so the log can still tell a refused connection from anything else.
    case notRunning(detail: String)

    /// Ollama is up and says it does not have this model. One `ollama pull` away, which is why
    /// the model name travels with the failure instead of being left in a log line.
    case modelNotPulled(model: String)

    /// The call was given up on with no answer.
    ///
    /// Distinct from `notRunning` because the remedy is the opposite one: the machine is
    /// working, it is the model that is too slow for this passage. `after` is the time actually
    /// spent, NOT ``OllamaChat/timeout`` -- measured, after a first version reported "no answer
    /// within 120 s" about a call that had died in 7.8 s. `URLSession` surfaces `.timedOut` for
    /// more than a blown deadline (a server that accepts a connection and then drops it reaches
    /// here too), so the configured limit is not what happened and saying it would be a wrong
    /// description of the case.
    case timedOut(after: TimeInterval)

    /// Ollama answered something this client cannot read: a non-JSON body, a JSON body with no
    /// message content, an empty answer, or any status other than 200 and a recognised 404.
    /// Nothing the user can fix — this one is a bug report.
    case malformedResponse(detail: String)

    /// The model hit `num_predict` and stopped mid-sentence.
    ///
    /// Not one of the five outcomes the lot-2 plan lists, and added because the corpus contains
    /// it: `r-verylong-04` (370 words) came back cut at "Donc en fait, il faut qu'on" with
    /// `done_reason: "length"`. Raising the cap to 2048 moves that boundary, it does not remove
    /// it. What makes it worth its own case is that the truncated text is a **grammatical
    /// fragment** — it looks like a finished refinement, so pasting it silently is the same
    /// class of invisible corruption the pinned options exist to prevent.
    case truncated(kept: String)

    /// The model answered, but its answer is not a refinement of the transcript.
    ///
    /// What is actually measured is a **length collapse**, not an intent: the answer is under
    /// ``OllamaChat/refusalRatio`` of the transcript it was given. Over the 263 measured
    /// refinements of the v2 benchmark (5 models, 6 prompts, 2 tasks) the shortest legitimate
    /// answer is 0.320 of its input, so an answer under 0.25 is outside everything a working
    /// refinement has ever done.
    ///
    /// The limit of the rule, stated rather than hidden: a refusal long enough to clear that
    /// ratio is not caught, and a refusal to a one-sentence dictation is indistinguishable by
    /// any measurement available from a legitimately terse rewrite. The residual case is bounded
    /// — the caller still holds the raw transcript (spec §9), so the worst outcome is a
    /// refinement Louis has to redo, never a dictation he loses.
    case refused(reply: String)

    /// What to do about it, in one sentence. This is the text a caller shows; ``description``
    /// is what it logs.
    ///
    /// English, matching the two existing failure enums in the app (`InsertError`,
    /// `WhisperKitEngine.Failure`); `AppState` is where user-facing French is produced from them.
    public var remedy: String {
        switch self {
        case .notRunning:
            "Ollama is not answering on this machine. Start it (`ollama serve`) and dictate again."
        case .modelNotPulled(let model):
            "The refinement model is not installed. Run `ollama pull \(model)`."
        case .timedOut(let after):
            "No answer after \(Int(after)) s. Try again, or pick a smaller model for this mode."
        case .malformedResponse:
            "Ollama answered something Murmure could not read. This is a bug -- the details are in the log."
        case .truncated:
            "The refinement was cut off before the end. Dictate this passage in shorter pieces."
        case .refused:
            "The model answered instead of refining. Adjust this mode's instructions, or pick another model."
        }
    }

    /// The line that goes in the log: the remedy plus whatever detail the failure carries.
    public var description: String {
        switch self {
        case .notRunning(let detail): "ollama not running (\(detail))"
        case .modelNotPulled(let model): "model not pulled: \(model)"
        case .timedOut(let after): "gave up after \(Int(after))s"
        case .malformedResponse(let detail): "malformed response: \(detail)"
        case .truncated(let kept): "answer truncated after \(kept.count) characters"
        case .refused(let reply): "model refused: \(reply.prefix(200))"
        }
    }
}

/// The two things a refinement can produce. There is no third, and no `nil`: to reach the text
/// a caller has to switch, and the other branch carries a failure it cannot look past.
public enum OllamaOutcome: Equatable {
    case refined(String)
    case failed(OllamaFailure)
}

/// The wire shape of a refinement call to Ollama's native chat API, and the reading of what
/// comes back.
///
/// This lives in `MurmureCore` and not next to the HTTP call for one structural reason: the app
/// target has no test bundle, so anything put there is unverifiable except by reading it. What
/// is here — the request the model receives, and the six ways an answer can fail — is exactly
/// the part worth testing, and none of it needs a network.
public enum OllamaChat {
    // MARK: - Pinned options
    //
    // These are floors, not preferences (lot 2 plan). Two of them were measured to corrupt a
    // real dictation at Ollama's own defaults, and neither failure raises anything: the request
    // succeeds, the model answers, and the answer is wrong.

    /// Zero, so the same dictation refined twice gives the same text. A refinement that varies
    /// run to run cannot be compared against the benchmark evidence that chose the model.
    public static let temperature = 0.0

    /// The same seed `benchmark/run_benchmark_v2.py` generated the 765 blind scores under, so a
    /// refinement in the app is reproducible against the evidence rather than merely
    /// deterministic in isolation.
    public static let seed = 20_260_901

    /// Ollama's default is 512, which is 380 completion tokens short of a 370-word dictation:
    /// `r-verylong-04` came back cut at "Donc en fait, il faut qu'on", with `done_reason` the
    /// only sign anything had gone wrong.
    public static let numPredict = 2048

    /// Ollama's default is 2048, and this is the worse of the two: input past roughly 600 words
    /// is dropped **silently** — no error, no status code, no `done_reason`, just a model that
    /// never saw the end of what Louis said and cleans up the part it did see.
    public static let numContext = 8192

    /// How long a refinement gets before it is given up on.
    ///
    /// Grounded on the slowest thing ever measured rather than picked round: over the 263 v2
    /// generations the longest single call is **26.35 s** (`gemma4-12b-qat` on a 370-word real
    /// dictation), and a cold call also pays the model load, which for the 7.2 GB default is
    /// seconds more. 120 s leaves ~4x headroom over that worst case while still turning "hangs
    /// forever" into a reportable outcome — the same bargain `WhisperKitEngine`'s download
    /// watchdog makes.
    ///
    /// Verified to actually fire, against a server that accepts the connection and then never
    /// answers: the call returned at 120.7 s rather than hanging.
    public static let timeout: TimeInterval = 120

    /// Below this fraction of the transcript's length, an answer is treated as a refusal rather
    /// than a refinement. See ``OllamaFailure/refused(reply:)`` for the measurement behind it.
    public static let refusalRatio = 0.25

    // MARK: - The request

    /// The chat endpoint for a configured base URL.
    ///
    /// A trailing `v1` is dropped. Spec §5's example mode still carries
    /// `"endpoint": "http://localhost:11434/v1"`, written before §10 ruled that refinement goes
    /// through the **native** API because the OpenAI-compatible one cannot turn reasoning off.
    /// A mode copied from that example would otherwise request `/v1/api/chat`, which Ollama
    /// answers with a plain-text 404 — a failure whose message would say nothing about the
    /// actual mistake.
    public static func endpoint(base: URL) -> URL {
        var path = base.pathComponents.filter { $0 != "/" }
        if path.last == "v1" { path.removeLast() }
        path += ["api", "chat"]
        // The fallback is not dead code and not a force unwrap on purpose: this URL comes from a
        // mode file Louis can edit by hand, and a URL that cannot be decomposed into components
        // should reach Ollama as a 404 he can read, not crash the app.
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base.appending(path: "api/chat")
        }
        components.path = "/" + path.joined(separator: "/")
        return components.url ?? base.appending(path: "api/chat")
    }

    /// The JSON body for one refinement: the mode's instructions as the system turn, the raw
    /// transcript as the user turn, reasoning off, streaming off, options pinned.
    ///
    /// Total rather than `throws`. `JSONEncoder.encode` declares `throws`, but every field of
    /// `Request` is a `String`, `Int`, `Double` or `Bool` and none of the doubles is infinite or
    /// NaN, so there is no value this encoder can refuse; propagating an error no caller could
    /// act on would add a seventh outcome for something that cannot happen.
    public static func requestBody(model: String, instructions: String, transcript: String) -> Data {
        try! JSONEncoder().encode(Request(
            model: model,
            messages: [
                Message(role: "system", content: instructions),
                Message(role: "user", content: transcript),
            ],
            stream: false,
            think: false,
            options: Options(
                temperature: temperature, seed: seed,
                numPredict: numPredict, numContext: numContext)
        ))
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        /// Native-API only, and the reason refinement does not go through the
        /// OpenAI-compatible endpoint: that one has no way to turn reasoning off (spec §10).
        ///
        /// Re-measured against the live server rather than taken from the spec, one model and
        /// one request, the two values back to back: with `think: true` the answer came back
        /// with `eval_count: 2048` — the ENTIRE `num_predict` budget — spent on a
        /// 7 752-character reasoning field, `done_reason: "length"` and **content of length 0**.
        /// With `think: false`, 10 tokens and the cleaned sentence. The failure is not "slower",
        /// it is "no output at all".
        let think: Bool
        let options: Options
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Options: Encodable {
        let temperature: Double
        let seed: Int
        let numPredict: Int
        let numContext: Int

        /// Ollama's wire names, kept out of the property names so the Swift side reads like the
        /// rest of the package.
        enum CodingKeys: String, CodingKey {
            case temperature, seed
            case numPredict = "num_predict"
            case numContext = "num_ctx"
        }
    }

    // MARK: - Reading the answer

    /// Classifies a transport-level failure. On a loopback endpoint there is nothing between
    /// the two processes, so the only two things that can go wrong are "nobody is listening"
    /// and "nobody answered in time".
    ///
    /// A `URLError` that is neither — `.cancelled`, say — arrives as `notRunning` with its code
    /// in the detail. That is the honest mapping rather than a seventh case: the remedy really
    /// is "check Ollama", and the log still distinguishes them.
    ///
    /// `elapsed` is how long the call actually ran, and it is a parameter rather than
    /// ``timeout`` because the two are not the same number: a server that accepts the connection
    /// and then drops it also surfaces as `.timedOut`, seconds in.
    public static func failure(transport error: any Error, elapsed: TimeInterval) -> OllamaFailure {
        guard let urlError = error as? URLError else {
            return .notRunning(detail: error.localizedDescription)
        }
        if urlError.code == .timedOut { return .timedOut(after: elapsed) }
        return .notRunning(detail: "\(urlError.code.rawValue) \(urlError.localizedDescription)")
    }

    /// Reads one HTTP response into the outcome it means.
    ///
    /// The transcript is a parameter because two of the six verdicts are about the *relationship*
    /// between the answer and what was dictated, not about the answer alone. The model is a
    /// parameter for a smaller reason, learned the hard way -- see ``isMissingModel(_:)``.
    public static func outcome(
        status: Int, body: Data, transcript: String, model: String
    ) -> OllamaOutcome {
        guard status == 200 else {
            // A 404 is two very different things. Ollama answers a request for a model it does
            // not have with a JSON `error` body; it answers a request for a route it does not
            // have with a bare `404 page not found`. Telling Louis to pull a model he already
            // has, because the endpoint was misconfigured, is worse than saying nothing.
            if status == 404, isMissingModel(body) {
                return .failed(.modelNotPulled(model: model))
            }
            let text = String(decoding: body, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(.malformedResponse(detail: "HTTP \(status): \(text.prefix(300))"))
        }

        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: body)
        } catch {
            let text = String(decoding: body, as: UTF8.self)
            return .failed(.malformedResponse(
                detail: "could not read the answer (\(error.localizedDescription)) -- body: \(text.prefix(300))"))
        }

        let text = answer.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // 0 of the 263 measured refinements returned empty text, so an empty answer is a defect
        // and never a legitimate "there was nothing to clean up".
        guard !text.isEmpty else {
            return .failed(.malformedResponse(detail: "the model returned no text"))
        }
        // Checked before the collapse rule: a truncated answer is long, so the two cannot both
        // fire, but the token cap is a fact reported by Ollama while the collapse is our
        // inference — the fact wins.
        guard answer.doneReason != "length" else {
            return .failed(.truncated(kept: text))
        }
        guard Double(text.count) >= refusalRatio * Double(transcript.count) else {
            return .failed(.refused(reply: text))
        }
        return .refined(text)
    }

    /// Whether this 404 body is Ollama saying it does not have the model.
    ///
    /// The model NAME is deliberately not parsed out of the message, and that is a correction
    /// rather than a preference: this originally lifted the name from between the double quotes
    /// of `model "x" not found, try pulling it first`, and running it against the real server
    /// showed Ollama 0.33.2 says `model 'x' not found` -- single quotes, no trailing clause. The
    /// parse returned nil, the case fell through to `malformedResponse`, and the one failure with
    /// a one-command remedy was reported as "this is a bug". The caller already knows which model
    /// it asked for, so nothing needs to be parsed at all.
    private static func isMissingModel(_ body: Data) -> Bool {
        guard let error = try? JSONDecoder().decode(ErrorAnswer.self, from: body) else {
            return false
        }
        return error.error.contains("not found")
    }

    private struct Answer: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
        /// `"stop"` normally, `"length"` when `num_predict` cut the answer off. Optional because
        /// nothing in the protocol promises it, and its absence is not a failure by itself.
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case doneReason = "done_reason"
        }
    }

    private struct ErrorAnswer: Decodable {
        let error: String
    }
}
