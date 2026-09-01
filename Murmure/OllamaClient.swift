import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "refine")

/// Sends one transcript to a local Ollama and returns the refined text.
///
/// This type is deliberately thin. Everything worth testing — the request the model receives,
/// the reading of what comes back, which of the seven failures an answer is, and which of the two
/// Ollama APIs a mode speaks — lives in `MurmureCore` (`OllamaCall` and the two dialects behind
/// it), because the app target has no test bundle and anything put here is unverifiable except by
/// reading it. What is left here is the HTTP call itself and the `URLSession` configuration that
/// carries the deadline.
///
/// Nothing about this client is stateful: no connection is kept, no model is held. Ollama keeps
/// the model resident on its side for its own `keep_alive` window, which is why the first
/// refinement after a pause pays a load and the next ones do not.
final class OllamaClient: Sendable {
    /// Where the failure goes, for the record the session leaves behind. Required, no default
    /// value, no way to construct a client without deciding — the same shape task 6 gave
    /// `PasteInserter.onClipboardOutcome`, and for the same reason (ruling L7).
    ///
    /// It is no longer the only way out: since `refine` answers `OllamaOutcome`, the failure also
    /// travels **in the return value**, and that is the copy `TranscriptRefiner` turns into the
    /// notice Louis reads — because only the caller knows whether the raw transcript was inserted
    /// in its place. This closure is the log's copy, not a second user-facing one.
    private let onFailure: @Sendable (OllamaFailure) -> Void

    private let session: URLSession

    init(onFailure: @escaping @Sendable (OllamaFailure) -> Void) {
        self.onFailure = onFailure

        let configuration = URLSessionConfiguration.ephemeral
        // Two deadlines, both set to the same value, and the pair is deliberate.
        //
        // `timeoutIntervalForRequest` is the maximum time between two pieces of data, NOT the
        // total. It happens to be the total here only because the request sets `stream: false`,
        // so Ollama sends nothing at all until the answer is finished -- the whole call is one
        // idle interval. `timeoutIntervalForResource` is the real ceiling on the call, and it is
        // set so the deadline stays a deadline rather than quietly becoming unbounded.
        configuration.timeoutIntervalForRequest = OllamaChat.timeout
        configuration.timeoutIntervalForResource = OllamaChat.timeout
        // Nothing to cache and nobody to be identified to: this is a local process, and a
        // refinement request must never be answered from a cache.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Refines one transcript, or says why it could not.
    ///
    /// Answers `OllamaOutcome` rather than `String?` because a `nil` says only "there is no
    /// refined text", and the seven reasons that can be true have seven different remedies. Spec §9
    /// says a dictation is never lost, so `.failed` is not the end of the pipeline: the caller
    /// falls back to the raw transcript it already holds, and the failure is what lets it tell
    /// Louis *why* the text he got is the raw one.
    ///
    /// Not marked `@discardableResult`, on purpose. Calling this and throwing the result away
    /// spends up to two minutes of the user's time to produce nothing, and the compiler should
    /// say so.
    func refine(
        transcript: String, instructions: String, model: String, endpoint base: URL,
        api: Mode.LLM.API
    ) async -> OllamaOutcome {
        // Which URL, which body and which reading of the answer are one decision, taken in
        // `MurmureCore` where it is tested. Nothing here knows the two dialects apart.
        let call = OllamaCall(
            api: api, model: model, instructions: instructions, transcript: transcript,
            endpoint: base)
        let url = call.url
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = call.body

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return report(
                OllamaChat.failure(transport: error, elapsed: Date().timeIntervalSince(start)),
                model: model, url: url)
        }

        guard let http = response as? HTTPURLResponse else {
            // Required by the cast rather than invented: `URLSession` always hands back an
            // `HTTPURLResponse` for an http(s) URL, so this branch means the URL was not one.
            return report(.malformedResponse(detail: "not an HTTP response"), model: model, url: url)
        }

        switch call.outcome(status: http.statusCode, body: data) {
        case .refined(let text):
            logger.info("""
                refined \(transcript.count, privacy: .public) -> \(text.count, privacy: .public) \
                characters with \(model, privacy: .public) in \
                \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s
                """)
            return .refined(text)
        case .failed(let failure):
            return report(failure, model: model, url: url)
        }
    }

    /// Logs the failure, hands it to the consumer, and gives it back so the call site above reads
    /// as one line. The log is what survives the session; the returned `.failed` is what reaches
    /// the code that decides what to insert.
    ///
    /// The URL is in the log line because the client no longer repairs a wrong `llm.endpoint`
    /// (see `OllamaChat.endpoint(base:)`): a mode edited by hand into the `/v1` compatibility
    /// API produces a 404 whose remedy reads "this is a bug", and the requested URL is the only
    /// thing in the record that shows it was a typo rather than a defect.
    private func report(_ failure: OllamaFailure, model: String, url: URL) -> OllamaOutcome {
        logger.error("""
            refinement with \(model, privacy: .public) at \(url.absoluteString, privacy: .public) \
            failed -- \(failure.description, privacy: .public)
            """)
        onFailure(failure)
        return .failed(failure)
    }
}

/// Type-checks to nothing: the labels already matched, and the return type now does too. Written
/// out rather than declared on the type so the conformance reads as what it is -- the app's one
/// implementation of a seam that `MurmureCore` owns and tests against stubs.
extension OllamaClient: RefinementClient {}
