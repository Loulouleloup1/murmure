import Foundation

/// Which of Ollama's own listing can drive a mode-drafting conversation over `/api/chat` -- the
/// drafting sheet's model picker, and the drafting system prompt's own list of installed chat
/// models (``ModeDraftSystemPrompt``).
///
/// Two families are excluded by a NAME rule rather than a lookup table, because Murmure has no
/// other way to tell them apart: Ollama's `/api/tags` reports a name and a size, nothing that says
/// "this one speaks Ollama's own conversation format" or "this one only ever answers with a
/// vector of numbers". A model added to the machine later that happens to share the same naming
/// pattern is excluded the same way, with no list to update by hand.
public enum ChatModelFilter {
    /// `true` unless the name looks like an s1-style model (``Mode/LLM/API/s1``) or an embedding
    /// model -- neither can hold a mode-drafting conversation the way `/api/chat` needs: an s1
    /// model is driven through `/api/generate` with a hand-written conversation and reads no system
    /// turn at all (``OllamaS1``'s whole reason to exist), and an embedding model answers with a
    /// vector, never with text.
    public static func isChatCapable(_ name: String) -> Bool {
        !looksLikeS1(name) && !looksLikeEmbedding(name)
    }

    /// `hf.co/superwhisper/s1-mini-GGUF:Q4_K_M`'s own shape: any Ollama name naming the same
    /// `s1-mini` model family, whatever registry or tag it was pulled under.
    public static func looksLikeS1(_ name: String) -> Bool {
        name.lowercased().contains("s1-mini")
    }

    /// `nomic-embed-text`, `mxbai-embed-large`, and anything else whose name says what it is.
    public static func looksLikeEmbedding(_ name: String) -> Bool {
        name.lowercased().contains("embed")
    }

    /// The model the drafting sheet's picker opens on: `preferred` when it is installed, else the
    /// first chat-capable model in `names`' own order -- or `nil` when nothing installed can hold
    /// this conversation at all.
    ///
    /// `preferred` defaults to `gemma4:12b-it-qat` -- the shipped `Mode.prompt`'s own escape hatch
    /// for a task `s1-mini` cannot do (`Mode.swift`'s doc comment on `rewriteModel`), and the one
    /// general-purpose chat model this app already treats as its answer to "point it back here".
    /// Compared through ``OllamaProbe/tagged(_:)``, not literal equality, for the same reason every
    /// other picker in this app does: Ollama's own listing always spells the tag
    /// (`gemma4:12b-it-qat` rather than a bare `gemma4`), and a default that compared literally
    /// would never match an installed model spelled that way.
    public static func defaultModel(
        among names: [String], preferring preferred: String = "gemma4:12b-it-qat"
    ) -> String? {
        let chatCapable = names.filter(isChatCapable)
        if let match = chatCapable.first(where: { OllamaProbe.tagged($0) == OllamaProbe.tagged(preferred) }) {
            return match
        }
        return chatCapable.first
    }
}
