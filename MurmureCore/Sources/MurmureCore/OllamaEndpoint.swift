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
}
