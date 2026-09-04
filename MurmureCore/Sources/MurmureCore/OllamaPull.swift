import Foundation

/// Why a pull did not end in an installed model, in terms of what to do about it.
///
/// A sibling of `OllamaFailure` rather than a case added to it: that type's whole point is that
/// its remedies are written for the moment a DICTATION fails ("...and dictate again"), and a pull
/// is not a dictation -- there is no transcript waiting to be inserted, no fallback text, nothing
/// to redo. Folding the two together would mean either bending `OllamaFailure`'s remedies to fit a
/// case that never dictates anything, or leaving this one to borrow a sentence written about a
/// different moment. Two small vocabularies, one per moment, is what T8 already asks for and is
/// kept here rather than widened past its original case.
public enum OllamaPullFailure: Equatable {
    /// Nothing answered on the loopback address at all. See `OllamaFailure/notRunning(detail:)`
    /// for why this is inferred rather than observed -- the same reasoning applies on this route.
    case notRunning(detail: String)

    /// Ollama looked at this model id and refused it -- not found on the registry, a private
    /// repository, a tag that does not exist. `detail` is Ollama's own message, because it is the
    /// only place that can distinguish those for a given id, and inventing a taxonomy of reasons
    /// here would put words in its mouth for cases nobody has seen yet.
    case rejected(model: String, detail: String)

    /// A body this client cannot read: not JSON, or JSON with neither a status nor an error.
    /// Nothing the user can fix -- this one is a bug report.
    case malformedResponse(detail: String)

    /// What to do about it, in one sentence.
    public var remedy: String {
        switch self {
        case .notRunning:
            "Ollama is not answering on this machine. Start it (`ollama serve`) and try again."
        case .rejected(let model, let detail):
            "Ollama could not pull \"\(model)\": \(detail). Check the model id."
        case .malformedResponse:
            "Ollama answered something Murmure could not read. This is a bug -- the details are in the log."
        }
    }

    /// The line that goes in the log.
    public var description: String {
        switch self {
        case .notRunning(let detail): "ollama not running (\(detail))"
        case .rejected(let model, let detail): "pull of \(model) rejected: \(detail)"
        case .malformedResponse(let detail): "malformed response: \(detail)"
        }
    }
}

/// The wire shape of `POST /api/pull`, and the reading of the NDJSON progress it streams back.
///
/// Lives in `MurmureCore` for the reason every other Ollama client in this app does: the app
/// target has no test bundle, and what is here -- the request, and the reading of each streamed
/// line -- is exactly the part worth testing, and none of it needs a network. The HTTP call and
/// the line-by-line reading of the response body are the app target's (`OllamaPuller`).
public enum OllamaPull {
    /// The pull endpoint on a mode's configured base URL -- the same root `OllamaProbe.endpoint`
    /// and `OllamaChat.endpoint` append their own routes to.
    public static func endpoint(base: URL) -> URL {
        base.appending(path: "api/pull")
    }

    /// The JSON body for one pull. `stream` is left to Ollama's own default (true): a client that
    /// asked for `stream: false` would get one JSON object back only once the whole model had
    /// downloaded, with no progress at all in between.
    public static func requestBody(model: String) -> Data {
        try! JSONEncoder().encode(Request(model: model))
    }

    private struct Request: Encodable {
        let model: String
    }

    /// What one line of the streamed body decided -- or `nil` for a blank line, which NDJSON
    /// bodies commonly end on and which carries no information either way.
    public enum LineOutcome: Equatable {
        /// `fraction` is `nil` until Ollama reports both `total` and `completed` for the layer
        /// currently transferring -- true of the early "pulling manifest" lines, which carry a
        /// status and nothing to measure it by.
        case progress(status: String, fraction: Double?)
        case succeeded
        case failed(OllamaPullFailure)
    }

    /// Reads one line of the stream. `model` travels in because the one failure this can produce
    /// -- `.rejected` -- is about the *model asked for*, the same reason `OllamaChat.outcome` and
    /// `OllamaProbe.outcome` both take one.
    public static func outcome(line: Data, model: String) -> LineOutcome? {
        let trimmed = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let decoded = try? JSONDecoder().decode(StatusLine.self, from: Data(trimmed.utf8)) else {
            return .failed(.malformedResponse(detail: "could not read a status line -- \(trimmed.prefix(300))"))
        }
        // Measured against the documented shape of a failed pull: Ollama can answer a bad model id
        // with a 200 whose STREAM carries a single `{"error": "..."}` line rather than a non-200
        // status -- so this has to be checked per line, not only once at the top of the response
        // the way `statusFailure` checks the HTTP status.
        if let error = decoded.error {
            return .failed(.rejected(model: model, detail: error))
        }
        guard let status = decoded.status else {
            return .failed(.malformedResponse(detail: "a status line named neither a status nor an error"))
        }
        guard status != "success" else { return .succeeded }

        let fraction: Double?
        if let total = decoded.total, let completed = decoded.completed, total > 0 {
            fraction = min(1, Double(completed) / Double(total))
        } else {
            fraction = nil
        }
        return .progress(status: status, fraction: fraction)
    }

    /// What a non-200 status means, or `nil` at 200 -- the other shape a rejected pull can take:
    /// Ollama answering before the stream even opens. Shares `OllamaChat.errorMessage`'s reading
    /// of the `{"error": "..."}` body rather than re-parsing it, so the two clients cannot read the
    /// same JSON shape two different ways.
    public static func statusFailure(status: Int, body: Data, model: String) -> OllamaPullFailure? {
        guard status != 200 else { return nil }
        if let message = OllamaChat.errorMessage(body) {
            return .rejected(model: model, detail: message)
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .malformedResponse(detail: "HTTP \(status): \(text.prefix(300))")
    }

    /// Classifies a transport-level failure. No `.timedOut` case here, unlike `OllamaChat`'s: a
    /// pull can legitimately run for minutes over a slow connection with no fixed deadline to
    /// compare against, and the caller pins no `URLSession` timeout the way a refinement call
    /// does -- so a `.timedOut` `URLError` means exactly what it means for every other case that is
    /// neither a normal answer nor a stall: nothing is answering back.
    public static func failure(transport error: any Error) -> OllamaPullFailure {
        guard let urlError = error as? URLError else {
            return .notRunning(detail: error.localizedDescription)
        }
        return .notRunning(detail: "\(urlError.code.rawValue) \(urlError.localizedDescription)")
    }

    /// The half of one streamed line this reads. Ollama sends more (`digest`), decoded only when
    /// used, for the reason `OllamaProbe.Listing.Entry` gives for the same choice.
    private struct StatusLine: Decodable {
        let status: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }
}
