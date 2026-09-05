import Foundation

/// Spelling an Ollama model name -- so the one shape "Add a model" builds by hand
/// (`hf.co/<owner>/<repo>:<tag>`, Ollama's own convention for pulling a Hugging Face GGUF) is
/// written in one place and tested, rather than assembled by string interpolation at the one call
/// site that needs it.
public enum OllamaModelName {
    /// `hf.co/<repository>:<tag>` -- what `ollama pull` resolves to fetch `tag`'s `.gguf` file(s)
    /// straight from `repository` on the Hugging Face Hub. `repository` is the bare `owner/repo`
    /// id (`HuggingFaceRepository.parse`'s output); `tag` is a `RefinerCandidate.tag`
    /// (`GGUFQuantization.tag`'s output), already upper-cased to match Ollama's own listing.
    public static func huggingFace(repository: String, tag: String) -> String {
        "hf.co/\(repository):\(tag)"
    }
}
