import Foundation

/// One turn of a mode-drafting conversation, and the running state of the whole conversation --
/// what the drafting sheet shows and what a call to Ollama's `/api/chat` (``ModeDraftChat``) sends.
///
/// A value type on purpose, the same reason ``ModeDraft`` is: the app owns an `@Published` copy of
/// it, and every mutation is a plain, testable transformation rather than a side effect buried in a
/// view model only the app target can exercise (the app target has no test bundle).
public struct ModeDraftingConversation: Equatable {
    public struct Turn: Equatable, Identifiable, Sendable {
        public enum Role: Equatable, Sendable {
            case user
            case assistant
        }

        public let id: UUID
        public let role: Role
        public let content: String

        public init(id: UUID = UUID(), role: Role, content: String) {
            self.id = id
            self.role = role
            self.content = content
        }
    }

    /// The chat-capable Ollama model this conversation is run against -- picked once, in the
    /// sheet's own model picker, and free to change between turns: the picker stays live for the
    /// whole conversation, so a reply that came back wrong on one model can be retried on another
    /// without starting over.
    public var model: String

    public private(set) var turns: [Turn] = []

    /// How many of the OLDEST turns have been dropped to stay under ``characterBudget`` -- shown in
    /// the sheet as a notice ("N earlier turns dropped...") rather than left silent, the same
    /// reason `RefinementRequest.capped(_:)` marks a truncation instead of cutting quietly.
    public private(set) var truncatedTurnCount = 0

    /// The built system prompt's own length, in characters -- reserved out of ``characterBudget``
    /// so the two together never overshoot ``rawCharacterBudget``. See ``characterBudget``'s own
    /// doc comment for why this has to be a live number rather than an assumed one.
    private let systemPromptCharacterCount: Int

    /// `systemPromptCharacterCount` is the CURRENT system prompt's `.count` -- the one
    /// ``ModeDraftSystemPrompt/build(installedSpeechModels:installedOllamaModels:)`` returns for
    /// this machine's own installed models, not a placeholder. It does not change turn to turn (the
    /// installed-model listing this sheet was opened with does not change mid-conversation), so it
    /// is measured once, at `init`, rather than re-measured on every append.
    public init(model: String, systemPromptCharacterCount: Int) {
        self.model = model
        self.systemPromptCharacterCount = systemPromptCharacterCount
    }

    /// The raw derivation -- reusing ``RefinementRequest/characterCap``'s own
    /// (``OllamaChat/numContext`` minus ``OllamaChat/numPredict``, four characters per token, the
    /// usual order-of-magnitude estimate for Latin-script text with no tokenizer in this package)
    /// rather than inventing a second number for a second kind of Ollama call.
    ///
    /// **Not halved the way `RefinementRequest.characterCap` is.** That cap protects the
    /// instructions and the transcript from being outweighed by ONE OF SEVERAL optional context
    /// fields sharing the same request; here the conversation history is the only thing occupying
    /// the remaining budget beside the system prompt and the model's own reply, so there is no
    /// sibling field it has to leave room for.
    ///
    /// **This alone is not what a conversation may spend on its history.** It is the ceiling for
    /// the WHOLE request -- system prompt included -- and ``ModeDraftSystemPrompt``'s own prompt is
    /// not a fixed handful of words: with every installed speech model and every installed chat
    /// model listed by name, it measured 7 565 characters on one real machine. A conversation that
    /// filled the whole of this constant with history, on top of that prompt, would send Ollama a
    /// request over `numContext` before a single reply token is generated -- and the server drops
    /// from the FRONT, which is the system prompt, not the most recent turn. ``characterBudget``
    /// is the number that actually protects that.
    public static let rawCharacterBudget = (OllamaChat.numContext - OllamaChat.numPredict) * 4

    /// What the conversation HISTORY alone may spend -- ``rawCharacterBudget`` minus this
    /// conversation's own ``systemPromptCharacterCount``, so the two together stay under the
    /// ceiling the server actually enforces.
    public var characterBudget: Int {
        Self.rawCharacterBudget - systemPromptCharacterCount
    }

    /// Appends a user turn, then drops the oldest turns until the conversation fits
    /// ``characterBudget``.
    public mutating func appendUser(_ text: String) {
        turns.append(Turn(role: .user, content: text))
        truncateIfNeeded()
    }

    /// Appends an assistant turn -- the model's own reply, once it has finished streaming.
    public mutating func appendAssistant(_ text: String) {
        turns.append(Turn(role: .assistant, content: text))
        truncateIfNeeded()
    }

    private var totalCharacters: Int {
        turns.reduce(0) { $0 + $1.content.count }
    }

    /// Drops the oldest turn, repeatedly, while the conversation is over budget -- never the last
    /// one: a single turn that alone exceeds the budget is still the most recent thing said, and
    /// dropping it would send the model nothing of what was just typed rather than something.
    private mutating func truncateIfNeeded() {
        while totalCharacters > characterBudget, turns.count > 1 {
            turns.removeFirst()
            truncatedTurnCount += 1
        }
    }
}
