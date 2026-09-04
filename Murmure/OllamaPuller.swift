import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "models")

/// Asks a local Ollama to pull a model, and reports each streamed status line as it arrives.
///
/// Thin, like `OllamaClient`, and for the same reason: the request, and the reading of every line
/// Ollama can send back, are `OllamaPull` -- tested in `MurmureCore`. What is here is the HTTP call
/// itself, the `URLSession` configuration, and reading the response body one NDJSON line at a
/// time.
struct OllamaPuller: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Unlike `OllamaClient`'s deadline, this is NOT measured against a real pull -- doing that
        // would mean actually pulling a multi-gigabyte model, which is exactly what this session's
        // hard safety rule forbids. `timeoutIntervalForRequest` bounds the gap between two
        // STREAMED lines rather than the whole call, the same shape `OllamaClient`'s comment
        // explains for the chat route; 60 s is generous for a route that is documented to emit a
        // new status line at least once per transferred layer, without pretending to be a
        // calibrated number the way `OllamaChat.timeout` is. `timeoutIntervalForResource` is
        // deliberately long rather than absent: a multi-gigabyte pull over a slow connection can
        // legitimately run for tens of minutes, and this is the ceiling that turns "hangs forever"
        // into a reportable failure without pre-empting a healthy transfer.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Pulls `model` from `endpoint`'s Ollama, calling `onLine` once per status line as it streams
    /// in. Returns the final line's outcome -- `.succeeded` or a `.failed` -- so the caller does
    /// not have to remember the last one `onLine` saw.
    func pull(
        model: String, endpoint base: URL, onLine: @escaping @Sendable (OllamaPull.LineOutcome) -> Void
    ) async -> OllamaPull.LineOutcome {
        var request = URLRequest(url: OllamaPull.endpoint(base: base))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = OllamaPull.requestBody(model: model)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            let outcome = OllamaPull.LineOutcome.failed(OllamaPull.failure(transport: error))
            onLine(outcome)
            return outcome
        }

        guard let http = response as? HTTPURLResponse else {
            let outcome = OllamaPull.LineOutcome.failed(.malformedResponse(detail: "not an HTTP response"))
            onLine(outcome)
            return outcome
        }

        if http.statusCode != 200 {
            // A rejection at this point arrived with no stream at all: the whole body is small
            // enough to read in one go rather than line by line.
            var body = Data()
            do {
                for try await byte in bytes { body.append(byte) }
            } catch {
                // Whatever could be read before the stream broke is still worth handing to
                // `statusFailure` below -- a truncated JSON error body fails to decode there and
                // falls through to `malformedResponse`, which is the honest answer to "the
                // connection died while Ollama was explaining itself".
            }
            let failure = OllamaPull.statusFailure(status: http.statusCode, body: body, model: model)
                ?? .malformedResponse(detail: "HTTP \(http.statusCode) with an empty body")
            let outcome = OllamaPull.LineOutcome.failed(failure)
            onLine(outcome)
            return outcome
        }

        var last: OllamaPull.LineOutcome = .progress(status: "pulling manifest", fraction: nil)
        do {
            for try await line in bytes.lines {
                guard let outcome = OllamaPull.outcome(line: Data(line.utf8), model: model) else { continue }
                onLine(outcome)
                last = outcome
                if case .succeeded = outcome { break }
                if case .failed = outcome { break }
            }
        } catch {
            let outcome = OllamaPull.LineOutcome.failed(OllamaPull.failure(transport: error))
            onLine(outcome)
            return outcome
        }
        if case .failed(let failure) = last {
            logger.error("pull of \(model, privacy: .public) failed -- \(failure.description, privacy: .public)")
        }
        return last
    }
}
