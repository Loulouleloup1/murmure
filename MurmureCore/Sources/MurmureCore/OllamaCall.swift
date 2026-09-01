import Foundation

/// One refinement request, fully decided: where it goes, what it sends, and how its answer is
/// read. The one place where ``Mode/LLM/api`` turns into behaviour.
///
/// A value rather than three functions the caller picks from, and that is the point: the URL, the
/// body and the reader of one dialect can never be paired with another's. Posting the `s1`
/// template to `/api/chat` returns an empty answer, and reading a `/api/generate` body as a chat
/// one returns "this is a bug" -- two silent-looking failures that no longer have a way to happen.
///
/// It lives in `MurmureCore` rather than next to the HTTP call because the app target has no test
/// bundle: routing that is written there is routing nothing can check.
public struct OllamaCall {
    public let url: URL
    public let body: Data

    /// Captured rather than re-derived at reading time. The verdict needs the transcript and the
    /// model that were sent -- two of the failures are about the *relationship* between the
    /// answer and the request -- and holding them here is what makes ``outcome(status:body:)``
    /// take only what the network actually returns.
    private let read: (Int, Data) -> OllamaOutcome

    public init(
        api: Mode.LLM.API, model: String, instructions: String, transcript: String,
        endpoint base: URL
    ) {
        switch api {
        case .chat:
            url = OllamaChat.endpoint(base: base)
            body = OllamaChat.requestBody(
                model: model, instructions: instructions, transcript: transcript)
            read = {
                OllamaChat.outcome(
                    status: $0, body: $1, transcript: transcript, model: model)
            }
        case .s1:
            url = OllamaS1.endpoint(base: base)
            body = OllamaS1.requestBody(
                model: model, instructions: instructions, transcript: transcript)
            read = {
                OllamaS1.outcome(status: $0, body: $1, transcript: transcript, model: model)
            }
        }
    }

    /// What the server's answer means, in the dialect this call was built for.
    public func outcome(status: Int, body: Data) -> OllamaOutcome {
        read(status, body)
    }
}
