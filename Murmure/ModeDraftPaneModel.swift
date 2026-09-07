import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "modeDrafting")

/// What the "Draft a mode with help" sheet is looking at: the conversation, the candidate mode the
/// last reply proposes (or the reason it does not), and whether a call is in flight.
///
/// Thin, the same reason every pane model in this app is: the app target has no test bundle, so
/// what is DECIDED here is `ModeDraftingConversation` and `ModeDraftExtraction` (`MurmureCore`,
/// tested) -- this is the `@Published` binding, the one network call, and nothing else.
///
/// **Nothing on appear.** Every model reference this needs -- the installed speech models, Ollama's
/// own listing, the keys already on disk -- is handed in at `init`, read from whatever
/// `ModesPaneModel` already loaded on the Modes pane's own appearance. Opening this sheet never
/// probes Ollama a second time.
@MainActor
final class ModeDraftPaneModel: ObservableObject {
    @Published private(set) var conversation: ModeDraftingConversation
    @Published var input = ""
    @Published private(set) var isSending = false
    @Published private(set) var streamingReply = ""
    @Published private(set) var networkNote: String?
    @Published private(set) var replyWasTruncated = false

    /// The picker's own options -- chat-capable models only (``ChatModelFilter/isChatCapable(_:)``),
    /// computed once at `init` from the same listing the system prompt reads.
    let chatCapableModels: [String]

    private let endpoint: URL
    private let installedSpeechModels: [String]
    private let installedOllamaModels: [String]
    private let existingModeKeys: [String]
    private let client = ModeDraftChatClient()

    init(
        endpoint: URL, installedSpeechModels: [String], installedOllamaModels: [String],
        existingModeKeys: [String]
    ) {
        self.endpoint = endpoint
        self.installedSpeechModels = installedSpeechModels
        self.installedOllamaModels = installedOllamaModels
        self.existingModeKeys = existingModeKeys
        chatCapableModels = installedOllamaModels.filter(ChatModelFilter.isChatCapable)
        // Measured once, here, from the SAME prompt `systemPrompt` below builds -- the listings it
        // is built from do not change for the life of this sheet, so this stays accurate without
        // being recomputed on every append (`ModeDraftingConversation.characterBudget`'s own note).
        let prompt = ModeDraftSystemPrompt.build(
            installedSpeechModels: installedSpeechModels, installedOllamaModels: installedOllamaModels)
        conversation = ModeDraftingConversation(
            model: ChatModelFilter.defaultModel(among: installedOllamaModels) ?? "",
            systemPromptCharacterCount: prompt.count)
    }

    var systemPrompt: String {
        ModeDraftSystemPrompt.build(
            installedSpeechModels: installedSpeechModels, installedOllamaModels: installedOllamaModels)
    }

    func selectModel(_ model: String) {
        conversation.model = model
    }

    /// The candidate the LAST assistant turn proposes, or nil -- recomputed on every read rather
    /// than cached: the conversation stays short (a handful of turns), and this is only read a few
    /// times a frame while the sheet is open.
    var candidate: ModeDraftCandidate? {
        guard case .success(let candidate) = extraction else { return nil }
        return candidate
    }

    /// The sentence to show under the last reply, or nil when there is no reply yet or it read
    /// cleanly. Covers `.noFencedBlock` too -- read by the person as a gentle nudge ("keep
    /// describing the mode"), not an error, which is exactly what that case's own wording says.
    var problem: String? {
        guard case .failure(let problem) = extraction else { return nil }
        return problem.description
    }

    private var extraction: Result<ModeDraftCandidate, ModeDraftProblem>? {
        guard let last = conversation.turns.last, last.role == .assistant else { return nil }
        return ModeDraftExtraction.extract(
            from: last.content, installedSpeechModels: installedSpeechModels,
            installedOllamaModels: installedOllamaModels, existingModeKeys: existingModeKeys)
    }

    /// Sends `input` as the next user turn, streaming the reply into ``streamingReply`` and, once
    /// finished, appending it to ``conversation`` as an assistant turn.
    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !conversation.model.isEmpty else { return }
        input = ""
        conversation.appendUser(text)
        isSending = true
        streamingReply = ""
        networkNote = nil
        replyWasTruncated = false

        let prompt = systemPrompt
        let model = conversation.model
        let turnsSoFar = conversation.turns
        let outcome = await client.send(
            model: model, systemPrompt: prompt, turns: turnsSoFar, endpoint: endpoint
        ) { [weak self] delta in
            Task { @MainActor in self?.streamingReply += delta }
        }

        isSending = false
        switch outcome {
        case .replied(let full, let truncated):
            conversation.appendAssistant(full)
            streamingReply = ""
            replyWasTruncated = truncated
            // The caption ``problem`` shows is the short, field-naming sentence
            // (`ModeDraftProblem.malformedJSON`'s own doc comment); the full `DecodingError` dump
            // that sentence was built from goes here instead, once per reply, rather than either
            // being shown under the bubble or discarded.
            if case .failure(.malformedJSON(let caption, let dump)) = extraction {
                logger.error(
                    "mode-draft reply did not decode (\(caption, privacy: .public)) -- \(dump, privacy: .public)")
            }
        case .failed(let failure):
            networkNote = failure.remedy
            streamingReply = ""
        }
    }
}
