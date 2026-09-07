import Foundation

/// One field a mode-drafting reply got wrong, in terms of what the sheet shows under it -- the
/// drafting sibling of ``ModeLoadProblem``: that type is for a *file*, this one for a model's own
/// answer, which is why the sentences below talk about the reply rather than about disk.
public enum ModeDraftProblem: Error, Equatable, CustomStringConvertible {
    /// No fenced code block at all yet -- the ordinary shape of a clarifying question, not
    /// necessarily a defect in the reply.
    case noFencedBlock
    /// The fenced block's text is not a single JSON object, or `Mode`'s own decoder refused it.
    /// `caption` is the short, field-naming sentence this case's own `description` shows; `dump`
    /// is the full `DecodingError` (or `JSONSerialization`) text, carried along rather than
    /// discarded so whoever is running this session can still log it -- a person reading the
    /// sheet needs "instructions is missing", not a multi-line `Swift.DecodingError` dump.
    case malformedJSON(caption: String, dump: String)
    /// A key the mode schema does not have -- refused rather than silently dropped, so a stray
    /// field never disappears without a word (a decoder that ignored it would still build a
    /// draft, just not the one whose field the person may have been relying on). Dotted for a
    /// nested field, e.g. `"llm.foo"` or `"context.screenshot"`.
    case unknownKey(String)
    /// `Mode.validate()`'s own refusal, reused rather than re-described.
    case invalidField(ModeValidationError)
    /// `key` names a mode that is already on disk.
    case keyCollision(String)

    public var description: String {
        switch self {
        case .noFencedBlock:
            "The reply has no fenced ```json block yet -- keep describing the mode, or ask it to "
                + "show the JSON."
        case .malformedJSON(let caption, _):
            "The fenced block is not valid mode JSON -- \(caption)"
        case .unknownKey(let key) where key.contains("."):
            """
            The draft has a field Murmure does not know, \(key.debugDescription) -- that section \
            of a mode only has room for the fields Murmure's own schema declares there.
            """
        case .unknownKey(let key):
            """
            The draft has a field Murmure does not know, \(key.debugDescription) -- a mode file has \
            no room for anything beyond key, name, hotkey, stt, llm, instructions, context, \
            autoActivate, simulateKeypresses and symbol.
            """
        case .invalidField(let error):
            error.description
        case .keyCollision(let key):
            "Another mode already uses the key \(key.debugDescription) -- ask for a different key, "
                + "or rename that mode first."
        }
    }
}

/// A mode the last reply of a drafting conversation proposed, decoded and validated, plus whether
/// its two model references are actually installed on this machine.
///
/// The two installation flags are **not** refusals (``ModeDraftProblem`` carries no case for
/// either): a mode naming a model nobody has pulled yet is still a mode Murmure can save, exactly
/// the way the editor's own pickers already show "(not installed)" beside a stored value they do
/// not find in their own listing (`ModesPaneView.speechModelOptions`/`refinerModelOptions`) rather
/// than refusing to open the mode at all.
public struct ModeDraftCandidate: Equatable {
    public let mode: Mode
    public let sttModelInstalled: Bool
    public let llmModelInstalled: Bool

    public init(mode: Mode, sttModelInstalled: Bool, llmModelInstalled: Bool) {
        self.mode = mode
        self.sttModelInstalled = sttModelInstalled
        self.llmModelInstalled = llmModelInstalled
    }
}

/// Reading a mode out of one assistant reply -- the one seam between a chat conversation, which is
/// free-form text, and ``Mode``, which is a schema `ModeStore` will actually write to disk.
public enum ModeDraftExtraction {
    /// Every top-level key ``Mode``'s `Codable` conformance recognises -- kept in one place so
    /// ``extract(from:installedSpeechModels:installedOllamaModels:existingModeKeys:)`` and its own
    /// test cannot drift from `Mode`'s real `CodingKeys` (synthesised, and therefore not otherwise
    /// nameable from outside `Mode.swift`).
    static let allowedTopLevelKeys: Set<String> = [
        "key", "name", "hotkey", "stt", "llm", "instructions", "context", "autoActivate",
        "simulateKeypresses", "symbol",
    ]

    /// The same idea one level down, for the three nested objects a reply can misspell into --
    /// `Mode.LLM` most of all, since it is the field the system prompt spends the most words on
    /// (`api`, `enabled`, plus the s1/chat split). A key `JSONDecoder` would otherwise ignore
    /// inside `"llm"` or `"context"` is exactly as silent a loss as one at the top level.
    static let allowedNestedKeys: [String: Set<String>] = [
        "stt": ["model", "language"],
        "llm": ["enabled", "endpoint", "model", "api"],
        "context": ["selectedText", "clipboard", "appContext"],
    ]

    /// The same shape as `Mode`, decoded separately because `Mode`'s own decoder REQUIRES `key` --
    /// exactly right for a file already on disk, wrong for a reply that has not been asked for one
    /// yet: ``ModeDraftSystemPrompt`` tells the model omitting `"key"` is fine, and a model that
    /// takes that at its word would otherwise fail every first answer with `keyNotFound`.
    ///
    /// `hotkey` is not a field here at all, not merely optional. The prompt also says "never
    /// invent one"; a model that emits one anyway must not have it survive into the candidate --
    /// a saved, invented combo registers a real global shortcut, which is a worse failure than a
    /// silently ignored field for once.
    private struct PartialMode: Decodable {
        let key: String?
        let name: String
        let stt: Mode.STT
        let llm: Mode.LLM
        let instructions: String
        let context: Mode.Context
        let autoActivate: [String]
        let simulateKeypresses: Bool
        let symbol: String?
    }

    /// Extracts and validates the mode the LAST fenced ```json block of `reply` proposes.
    ///
    /// **The last block, not the first.** A reply can carry more than one fenced block before the
    /// real answer -- an inline example while the model is still asking a clarifying question, a
    /// snippet quoted back from earlier in the conversation -- and only the final one is the
    /// model's own finished proposal, per the system prompt's own instruction
    /// (``ModeDraftSystemPrompt``'s closing paragraph).
    ///
    /// **Refuses stray keys**, top-level or nested, which `JSONDecoder` would otherwise ignore in
    /// silence: `Mode`'s decoder only ever reads the keys it declares, so a field the model
    /// invented would vanish from the draft with nothing said, which is a worse failure than
    /// refusing outright -- the person reviewing this draft in the editor has no way to know a
    /// field they described was never captured at all.
    public static func extract(
        from reply: String,
        installedSpeechModels: [String],
        installedOllamaModels: [String],
        existingModeKeys: [String]
    ) -> Result<ModeDraftCandidate, ModeDraftProblem> {
        guard let jsonText = lastFencedBlock(in: reply) else { return .failure(.noFencedBlock) }
        let data = Data(jsonText.utf8)

        guard let topLevel = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.malformedJSON(
                caption: "the fenced block is not a JSON object",
                dump: "the fenced block is not a JSON object"))
        }
        let strayTopLevel = Set(topLevel.keys).subtracting(allowedTopLevelKeys)
        if let stray = strayTopLevel.sorted().first {
            return .failure(.unknownKey(stray))
        }
        if let stray = strayNestedKey(in: topLevel) {
            return .failure(.unknownKey(stray))
        }

        let partial: PartialMode
        do {
            partial = try JSONDecoder().decode(PartialMode.self, from: data)
        } catch {
            let (caption, dump) = describeDecodingError(error)
            return .failure(.malformedJSON(caption: caption, dump: dump))
        }

        let trimmedKey = partial.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = trimmedKey.isEmpty
            ? Mode.availableKey(basedOn: partial.name, avoiding: existingModeKeys) : trimmedKey

        if existingModeKeys.contains(key) {
            return .failure(.keyCollision(key))
        }

        let mode = Mode(
            key: key, name: partial.name, hotkey: nil, stt: partial.stt, llm: partial.llm,
            instructions: partial.instructions, context: partial.context,
            autoActivate: partial.autoActivate, simulateKeypresses: partial.simulateKeypresses,
            symbol: partial.symbol)

        do {
            try mode.validate()
        } catch let error as ModeValidationError {
            return .failure(.invalidField(error))
        } catch {
            // `Mode.validate()` only ever throws `ModeValidationError` (`Mode.swift`), so this is
            // unreachable in practice; kept rather than force-cast so a future case added to the
            // function's signature still compiles into a reported problem instead of a crash.
            let dump = String(describing: error)
            return .failure(.malformedJSON(caption: dump, dump: dump))
        }

        let sttInstalled = installedSpeechModels.contains(mode.stt.model)
        let llmInstalled = !mode.llm.enabled
            || installedOllamaModels.contains { OllamaProbe.tagged($0) == OllamaProbe.tagged(mode.llm.model) }

        return .success(
            ModeDraftCandidate(mode: mode, sttModelInstalled: sttInstalled, llmModelInstalled: llmInstalled))
    }

    /// The first key inside `"stt"`, `"llm"` or `"context"` that ``allowedNestedKeys`` does not
    /// list for that field, dotted with its parent (`"llm.foo"`) -- or nil. Fields whose value is
    /// not itself an object (or is absent) are left to `PartialMode`'s own decoder, which reports
    /// those failures on its own terms.
    private static func strayNestedKey(in topLevel: [String: Any]) -> String? {
        for field in allowedNestedKeys.keys.sorted() {
            guard let nested = topLevel[field] as? [String: Any], let allowed = allowedNestedKeys[field]
            else { continue }
            if let stray = Set(nested.keys).subtracting(allowed).sorted().first {
                return "\(field).\(stray)"
            }
        }
        return nil
    }

    /// Turns a decoding failure into a short sentence naming the field, for the caption, alongside
    /// the untouched dump for whoever wants to log the technical detail. `Swift.DecodingError`'s
    /// own `description` is a multi-line dump of the whole coding path and underlying error --
    /// correct, and useless to read under a chat bubble.
    private static func describeDecodingError(_ error: Error) -> (caption: String, dump: String) {
        let dump = String(describing: error)
        guard let decodingError = error as? DecodingError else { return (caption: dump, dump: dump) }
        switch decodingError {
        case .keyNotFound(let key, let context):
            let field = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            return (caption: "missing field \(field.debugDescription)", dump: dump)
        case .typeMismatch(_, let context):
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            return (
                caption: field.isEmpty
                    ? "a field has the wrong type" : "\(field.debugDescription) has the wrong type",
                dump: dump)
        case .valueNotFound(_, let context):
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            return (
                caption: field.isEmpty
                    ? "a field is missing its value" : "\(field.debugDescription) is missing its value",
                dump: dump)
        case .dataCorrupted(let context):
            return (caption: "malformed JSON -- \(context.debugDescription)", dump: dump)
        @unknown default:
            return (caption: dump, dump: dump)
        }
    }

    /// The text of the LAST fenced code block in `text`, tolerating a missing (or any) language
    /// tag on the opening fence -- a model that writes bare ``` ```` `` fences instead of
    /// ```` ```json ```` still has its answer read.
    static func lastFencedBlock(in text: String) -> String? {
        fencedBlocks(in: text).last
    }

    /// Every fenced code block in `text`, in order, closed blocks only -- an opening fence with no
    /// matching close (the reply was cut off mid-block) contributes nothing rather than the
    /// dangling remainder, which would very likely fail to parse as JSON anyway and is better
    /// reported as "no fenced block" than as a confusing parse error.
    private static func fencedBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") else {
                index += 1
                continue
            }
            var body: [String] = []
            var cursor = index + 1
            var closed = false
            while cursor < lines.count {
                if lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    closed = true
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            if closed {
                blocks.append(body.joined(separator: "\n"))
            }
            index = cursor + 1
        }
        return blocks
    }
}
