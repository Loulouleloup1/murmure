import Foundation

/// Whether a mode's `llm.endpoint` is the loopback address -- the one thing `Mode.validationError`
/// does not itself check.
///
/// **Why this exists.** `Mode.validationError` requires `llm.endpoint` to be an http(s) URL that is
/// its own root; it says nothing about the *host*. That is deliberate there -- a mode pointing at a
/// remote Ollama is a legitimate configuration `checkOllama()`'s own press-driven probe already
/// serves. But an automatic, on-appear read (`ModesPaneModel.reload()`, `ModelsPaneModel.reload()`)
/// is a different promise: both panes document that reading `/api/tags` on open is safe because it
/// is `localhost` and nothing has to be pressed for it. That promise is true only when the host
/// actually is loopback -- a mode holding `http://192.168.1.50:11434` would otherwise make opening
/// a settings pane silently reach across the network, which is exactly what "nothing on `onAppear`"
/// exists to rule out. This is the check that keeps the promise honest rather than assumed.
public enum OllamaEndpoint {
    /// `true` for `localhost`, `127.0.0.1`, or the IPv6 loopback `::1`. `URL.host` already strips
    /// the brackets an IPv6 literal carries in its string form (`"[::1]"` -> `"::1"`,
    /// `testTheLoopbackIPv6AddressIsLoopback` is what pins that down), so there is no bracket
    /// handling to do here. Case-insensitive: `URL`'s host is not normalised for case on the way
    /// in.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Ollama's own local root -- what every shipped mode already points at
    /// (`Mode.LLM.endpoint`'s own default), used whenever nothing more specific applies.
    public static let localRoot = URL(string: "http://localhost:11434")!

    /// The root to talk to when an automatic (never a pressed) call needs one: `preferring`'s own
    /// root, when it parses as a URL AND is loopback, else ``localRoot``.
    ///
    /// **Never falls back to a parsed-but-remote endpoint.** `preferring` most often comes from a
    /// mode's own `llm.endpoint`, which may legitimately name a remote server -- and reaching that
    /// automatically is exactly what ``isLoopback(_:)``'s own doc comment says an on-appear call
    /// must never do. A non-loopback (or unparsable, or absent) `preferring` therefore falls back
    /// to ``localRoot`` rather than being read anyway.
    public static func loopbackRoot(preferring endpoint: String?) -> URL {
        if let endpoint, let url = URL(string: endpoint), isLoopback(url) {
            return url
        }
        return localRoot
    }
}
