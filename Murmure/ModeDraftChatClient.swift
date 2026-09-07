import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "modeDrafting")

/// Streams one turn of a mode-drafting conversation from a local Ollama, calling `onDelta` for
/// each fragment of text as it arrives.
///
/// Thin, like `OllamaPuller`, and for the identical reason: the request, and the reading of every
/// NDJSON line Ollama can send back, are `ModeDraftChat` -- tested in `MurmureCore`. What is here
/// is the HTTP call itself, the `URLSession` configuration, and reading the response body one line
/// at a time.
struct ModeDraftChatClient: Sendable {
    /// What one call concluded: the full reply text assembled from every streamed delta (and
    /// whether it was cut off before the end), or why there is none.
    enum Outcome: Equatable {
        case replied(String, truncated: Bool)
        case failed(OllamaFailure)
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // The same shape `OllamaPuller`'s own comment explains: this bounds the gap between two
        // STREAMED lines, not the whole conversation turn -- a drafting reply can legitimately run
        // long while the model is still thinking through several fields.
        configuration.timeoutIntervalForRequest = OllamaChat.timeout
        configuration.timeoutIntervalForResource = OllamaChat.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Sends `turns` (the conversation so far, the new user turn already appended by the caller)
    /// plus `systemPrompt`, streaming every delta to `onDelta` as it arrives.
    func send(
        model: String, systemPrompt: String, turns: [ModeDraftingConversation.Turn], endpoint base: URL,
        onDelta: @escaping @Sendable (String) -> Void
    ) async -> Outcome {
        var request = URLRequest(url: ModeDraftChat.endpoint(base: base))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ModeDraftChat.requestBody(model: model, systemPrompt: systemPrompt, turns: turns)

        let start = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            return report(ModeDraftChat.failure(transport: error, elapsed: Date().timeIntervalSince(start)), model: model)
        }

        guard let http = response as? HTTPURLResponse else {
            return report(.malformedResponse(detail: "not an HTTP response"), model: model)
        }

        if http.statusCode != 200 {
            // A rejection at this point arrived with no stream at all: the whole body is small
            // enough to read in one go, the same shape `OllamaPuller` reads its own non-200 body in.
            var body = Data()
            do {
                for try await byte in bytes { body.append(byte) }
            } catch {
                // Whatever could be read is still worth handing to `statusFailure` below.
            }
            let failure = ModeDraftChat.statusFailure(status: http.statusCode, body: body, model: model)
                ?? .malformedResponse(detail: "HTTP \(http.statusCode) with an empty body")
            return report(failure, model: model)
        }

        var full = ""
        do {
            for try await line in bytes.lines {
                guard let outcome = ModeDraftChat.outcome(line: Data(line.utf8), model: model) else { continue }
                switch outcome {
                case .delta(let text):
                    full += text
                    if !text.isEmpty { onDelta(text) }
                case .done(let text, let truncated):
                    full += text
                    if !text.isEmpty { onDelta(text) }
                    return .replied(full, truncated: truncated)
                case .failed(let failure):
                    return report(failure, model: model)
                }
            }
        } catch {
            return report(ModeDraftChat.failure(transport: error, elapsed: Date().timeIntervalSince(start)), model: model)
        }
        // The stream ended with no `"done": true` line -- treat whatever text arrived as the whole
        // reply rather than discard it, the way a real answer with a late `done` line still would.
        return .replied(full, truncated: false)
    }

    private func report(_ failure: OllamaFailure, model: String) -> Outcome {
        logger.error(
            "mode-draft chat with \(model, privacy: .public) failed -- \(failure.description, privacy: .public)")
        return .failed(failure)
    }
}
