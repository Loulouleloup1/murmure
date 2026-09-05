import Foundation
import MurmureCore

/// Asks a local Ollama to remove a model -- the one thing that may ever delete from Ollama's own
/// store, and the same call `ollama rm` makes from the command line. Murmure never touches a file
/// under Ollama's directory itself.
///
/// Thin, like `OllamaPuller` and for the same reason: the request and the reading of the response
/// are `OllamaDelete`, tested in `MurmureCore`. What is here is the HTTP call.
struct OllamaDeleter: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func delete(model: String, endpoint base: URL) async -> OllamaDelete.Outcome {
        var request = URLRequest(url: OllamaDelete.endpoint(base: base))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = OllamaDelete.requestBody(model: model)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.malformedResponse(detail: "not an HTTP response"))
            }
            return OllamaDelete.outcome(status: http.statusCode, body: data, model: model)
        } catch {
            return .failed(OllamaDelete.failure(transport: error))
        }
    }
}
