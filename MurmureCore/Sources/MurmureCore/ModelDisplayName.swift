import Foundation

/// How a model identifier is written when a person reads it.
///
/// Ollama names a model `[host/][namespace/]name[:tag]`, and Murmure stores that string exactly —
/// it is what makes a history row reproducible, and it does not move. What Louis saw in the
/// metadata block was the whole of it: *"pour le language model, je trouve ça assez étrange...
/// Pourquoi est-ce qu'on a le lien du modèle et pas juste le nom ?"*
///
/// **One rule: drop everything up to the last slash, keep the rest verbatim.** The part before
/// the last slash says where the model was pulled from — a registry host, a publisher's
/// namespace, a `localhost:11434` — and none of it is the model. Splitting there rather than at
/// the first colon is also what makes a host with a port come out right.
///
/// **The tag stays.** It was tempting to drop `Q4_K_M` as a mere quantisation, and it would have
/// been wrong twice over. A tag is very often the identity: `gemma4:12b-it-qat` and `gemma4:27b`
/// are different models that write differently, and a row that said only `gemma4` would describe
/// text it did not produce. And telling a quantisation from a variant needs a classifier, which
/// would be a rule about particular tag spellings — the first `12b-instruct-q4_K_M` it met, and
/// those are the common ones, it would have thrown the size away with the quantisation. Nothing
/// here knows the name of any model.
public enum ModelDisplayName {
    /// The readable half of an identifier. Never empty when the input is not: an identifier that
    /// is all path, or ends on its slash, keeps what was given rather than becoming nothing.
    public static func readable(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return trimmed }
        let name = String(trimmed[trimmed.index(after: lastSlash)...])
        return name.isEmpty ? trimmed : name
    }
}
