import Foundation

/// Reading what Louis typed into "add a speech model" as a repository id, whichever of the two
/// shapes he actually pasted.
///
/// *"connecter Hugging Face ou alors mettre juste le lien de Hugging Face"* -- his own two shapes,
/// and both have to resolve to the one thing `WhisperKit.fetchAvailableModels`/`.download` want:
/// the bare `owner/repo` id. Getting this wrong either refuses a perfectly good paste (a URL) or
/// accepts something that is not a repository at all and sends it to the Hub, where it fails as a
/// confusing network error rather than as a plain "that doesn't look right" said before anything
/// was asked of the network.
public enum HuggingFaceRepository {
    /// `nil` when `input` is neither shape. Never throws: a field the user is still typing into
    /// is not an error, it is just not a repository yet.
    public static func parse(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host?.lowercased(),
            host == "huggingface.co" || host == "www.huggingface.co"
        {
            // A repository URL carries the id as its first two path segments and, very often,
            // more after it -- `/tree/main`, `/blob/main/config.json`, a trailing slash. All of
            // that is the Hub's own UI chrome, not part of the id, so only the first two segments
            // are read.
            let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard segments.count >= 2 else { return nil }
            return validated(owner: segments[0], repo: segments[1])
        }

        // Not a recognised URL, so read it as a bare id. Leading/trailing slashes are stripped
        // rather than refused -- a paste that picked up a trailing "/" is still unambiguously
        // "owner/repo" -- but anything that leaves more or fewer than two components is refused:
        // a third segment is not part of an id typed by hand, and one segment is a model name
        // with no owner, which is not the shape this field asks for.
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2 else { return nil }
        return validated(owner: segments[0], repo: segments[1])
    }

    private static func validated(owner: String, repo: String) -> String? {
        guard isValidComponent(owner), isValidComponent(repo) else { return nil }
        return "\(owner)/\(repo)"
    }

    /// A Hugging Face namespace or repo name: letters, digits, `-`, `_` and `.`, and not empty.
    /// Rejecting anything else is what keeps a stray URL fragment (a scheme, a query string) from
    /// being read as a plausible-looking owner or repo name.
    private static func isValidComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}
