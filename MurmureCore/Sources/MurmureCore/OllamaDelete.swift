import Foundation

/// Why a delete did not remove a language model, in terms of what to do about it.
///
/// A third small vocabulary beside ``OllamaFailure`` and ``OllamaPullFailure``, for the reason
/// each of those already gives for existing separately from the other: their remedies are written
/// for one particular moment (a dictation, a pull) and a delete is neither -- "Ollama could not
/// pull" would be the wrong verb for a request that never asked it to fetch anything.
public enum OllamaDeleteFailure: Equatable {
    /// Nothing answered on the loopback address at all.
    case notRunning(detail: String)
    /// Ollama looked at this model id and refused to delete it -- most often because it does not
    /// have it. `detail` is Ollama's own message, for the same reason
    /// ``OllamaPullFailure/rejected(model:detail:)`` carries one rather than a guessed taxonomy.
    case rejected(model: String, detail: String)
    /// A body this client cannot read. Nothing the user can fix.
    case malformedResponse(detail: String)

    public var remedy: String {
        switch self {
        case .notRunning:
            "Ollama is not answering on this machine. Start it (`ollama serve`) and try again."
        case .rejected(let model, let detail):
            "Ollama could not delete \"\(model)\": \(detail)."
        case .malformedResponse:
            "Ollama answered something Murmure could not read. This is a bug -- the details are in the log."
        }
    }

    public var description: String {
        switch self {
        case .notRunning(let detail): "ollama not running (\(detail))"
        case .rejected(let model, let detail): "delete of \(model) rejected: \(detail)"
        case .malformedResponse(let detail): "malformed response: \(detail)"
        }
    }
}

/// The wire shape of `DELETE /api/delete`, Ollama's own removal call -- the one thing that may
/// ever remove a model from Ollama's store, the same way `ollama rm` does from the command line.
/// Murmure never deletes a file under Ollama's own directory itself.
///
/// Lives in `MurmureCore` for the reason every other Ollama client in this app does: the request
/// and the reading of the response are exactly the part worth testing without a network, and the
/// app target has no test bundle to hold that test in. The HTTP call itself is the app target's.
public enum OllamaDelete {
    /// The delete route on a mode's configured base URL -- the same root every other Ollama route
    /// in this app appends to.
    public static func endpoint(base: URL) -> URL {
        base.appending(path: "api/delete")
    }

    /// The JSON body for one delete.
    public static func requestBody(model: String) -> Data {
        try! JSONEncoder().encode(Request(model: model))
    }

    private struct Request: Encodable {
        let model: String
    }

    public enum Outcome: Equatable {
        case succeeded
        case failed(OllamaDeleteFailure)
    }

    /// Ollama answers a successful delete with a bare 200 and no body worth decoding -- unlike
    /// `/api/pull`, there is no stream to read afterwards.
    public static func outcome(status: Int, body: Data, model: String) -> Outcome {
        guard status != 200 else { return .succeeded }
        if let message = OllamaChat.errorMessage(body) {
            return .failed(.rejected(model: model, detail: message))
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(.malformedResponse(detail: "HTTP \(status): \(text.prefix(300))"))
    }

    /// Classifies a transport-level failure the same way `OllamaPull.failure(transport:)` does.
    public static func failure(transport error: any Error) -> OllamaDeleteFailure {
        guard let urlError = error as? URLError else {
            return .notRunning(detail: error.localizedDescription)
        }
        return .notRunning(detail: "\(urlError.code.rawValue) \(urlError.localizedDescription)")
    }
}
