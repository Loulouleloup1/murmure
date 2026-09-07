import Foundation

/// The wire shape of a mode-drafting call to Ollama's own `/api/chat`, streamed -- the sibling of
/// ``OllamaChat`` and ``OllamaPull`` this feature needs rather than either of them.
///
/// **Why not `OllamaChat`.** That type's `requestBody(model:instructions:transcript:)` hardcodes
/// `stream: false` and exactly one system turn plus one user turn -- the shape a REFINEMENT needs,
/// answered once and read as a single JSON body. A drafting conversation is the opposite of that:
/// an open-ended back-and-forth that has to show partial text as it arrives, over however many
/// turns the conversation has grown to. Reusing `OllamaChat.outcome(status:body:transcript:model:)`
/// here would mean decoding a streamed NDJSON body as one JSON document, which fails on every line
/// but the last.
///
/// **Why not `OllamaPull`.** Its NDJSON reading (`LineOutcome`) is the closest shape in this
/// package -- one line at a time, streamed -- and this type mirrors it deliberately. It cannot be
/// reused outright: a pull's lines carry a download's `status`/`total`/`completed`, and a chat's
/// carry a `message.content` delta plus a `done` flag. Two different wire shapes read the same
/// *way*, not one shape read twice.
public enum ModeDraftChat {
    /// The chat endpoint for a mode's configured base URL -- ``OllamaChat/endpoint(base:)``'s own
    /// route, on the same root.
    public static func endpoint(base: URL) -> URL {
        base.appending(path: "api/chat")
    }

    /// The JSON body for one turn of the conversation: the drafting system prompt, then every turn
    /// so far, streamed, reasoning off, the same pinned floors ``OllamaChat`` measured
    /// (`temperature`, `seed`, `numPredict`, `numContext`) -- a drafting reply is not exempt from
    /// the failures those floors exist to prevent (a truncated reply, a silently dropped tail).
    public static func requestBody(
        model: String, systemPrompt: String, turns: [ModeDraftingConversation.Turn]
    ) -> Data {
        var messages = [Message(role: "system", content: systemPrompt)]
        messages += turns.map { Message(role: $0.role.wireRole, content: $0.content) }
        return try! JSONEncoder().encode(Request(
            model: model, messages: messages, stream: true, think: false,
            options: Options(
                temperature: OllamaChat.temperature, seed: OllamaChat.seed,
                numPredict: OllamaChat.numPredict, numContext: OllamaChat.numContext)))
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
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

        enum CodingKeys: String, CodingKey {
            case temperature, seed
            case numPredict = "num_predict"
            case numContext = "num_ctx"
        }
    }

    // MARK: - Reading the stream

    /// What one streamed NDJSON line of `/api/chat` means.
    public enum LineOutcome: Equatable {
        /// A fragment of the reply's text -- possibly empty, on the line that only carries `done`.
        case delta(String)
        /// The stream is finished. `text` is whatever content THIS SAME line still carries --
        /// Ollama's own final line can be both at once, `message.content` non-empty and
        /// `done: true` together, and reading only one half would either drop the reply's last
        /// fragment or, read as a plain `.delta`, never notice the stream had ended. `truncated` is
        /// `done_reason == "length"`: `num_predict` cut the reply off mid-sentence, the same
        /// failure ``OllamaFailure/truncated(kept:)`` names for a refinement -- surfaced here
        /// rather than swallowed, because a cut-off reply can still look like one valid (but
        /// incomplete) fenced JSON block.
        case done(String, truncated: Bool)
        case failed(OllamaFailure)
    }

    /// Reads one streamed line, or `nil` for a blank one -- the same shape `OllamaPull.outcome`
    /// reads its own NDJSON stream in.
    public static func outcome(line: Data, model: String) -> LineOutcome? {
        let trimmed = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8)) else {
            return .failed(.malformedResponse(detail: "could not read a chat line -- \(trimmed.prefix(300))"))
        }
        if decoded.done == true {
            return .done(decoded.message?.content ?? "", truncated: decoded.doneReason == "length")
        }
        return .delta(decoded.message?.content ?? "")
    }

    /// What a non-200 status means, or `nil` at 200 -- shared with ``OllamaChat``: both dialects
    /// are the same server, so a missing model looks the same on either route.
    public static func statusFailure(status: Int, body: Data, model: String) -> OllamaFailure? {
        OllamaChat.statusFailure(status: status, body: body, model: model)
    }

    /// Classifies a transport-level failure -- delegated, the same reasoning ``OllamaProbe``'s own
    /// transport reader gives for reusing this exact function rather than reclassifying `URLError`
    /// a third time in this package.
    public static func failure(transport error: any Error, elapsed: TimeInterval) -> OllamaFailure {
        OllamaChat.failure(transport: error, elapsed: elapsed)
    }

    private struct Line: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message?
        let done: Bool?
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case message, done
            case doneReason = "done_reason"
        }
    }
}

extension ModeDraftingConversation.Turn.Role {
    /// Ollama's own spelling for a chat message's role -- matching `OllamaChat`'s own wire values
    /// (`"system"`/`"user"`, private to that file), restated here rather than shared because
    /// neither of `OllamaChat`'s two roles is `private` for a reason worth reusing across a file
    /// boundary.
    fileprivate var wireRole: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        }
    }
}
