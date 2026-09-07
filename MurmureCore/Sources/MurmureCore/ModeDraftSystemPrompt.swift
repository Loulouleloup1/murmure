import Foundation

/// The system prompt for a mode-drafting conversation: everything the model needs to answer with a
/// mode Murmure can actually load, built from the SAME types and constants the rest of the app
/// reads -- never a hand-typed second description of the schema, which is exactly the kind of prose
/// that drifts the day a field is added to ``Mode`` and nobody remembers to update it here too.
public enum ModeDraftSystemPrompt {
    /// Assembles the prompt for one drafting session.
    ///
    /// `installedSpeechModels` and `installedOllamaModels` are read off the SAME state the Modes
    /// pane already holds (`ModesPaneModel.installedSpeechModels`, `.ollamaModels`) -- nothing here
    /// probes anything of its own, which is what lets the drafting sheet open with "nothing on
    /// appear".
    public static func build(installedSpeechModels: [String], installedOllamaModels: [String]) -> String {
        let chatModels = installedOllamaModels.filter(ChatModelFilter.isChatCapable)
        let s1Models = installedOllamaModels.filter(ChatModelFilter.looksLikeS1)

        return [
            introduction,
            schemaSection,
            fieldMeanings(
                installedSpeechModels: installedSpeechModels, chatModels: chatModels, s1Models: s1Models),
            controlLineSection,
            examplesSection,
            closing,
        ].joined(separator: "\n\n")
    }

    private static let introduction = """
        You are helping someone configure a new "mode" for Murmure, a macOS dictation app. A mode \
        is a JSON file describing: which speech model transcribes, in which language, whether an \
        LLM refines the transcript afterwards and how, and which background context it reads. You \
        do not write the file yourself -- the person reviews and saves it in Murmure's own editor. \
        Your job is to turn what they describe into one such mode.
        """

    /// The shape, read straight off `Mode`'s own `Codable` conformance rather than typed out by
    /// hand -- `ModeStore.encoder` is the exact encoder that writes a mode to disk, so this can
    /// never describe a shape Murmure does not actually read back.
    private static let schemaSection: String = {
        let example = Mode(
            key: "my-mode", name: "My mode", hotkey: nil,
            stt: .init(
                model: "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo",
                language: "en"),
            llm: .init(
                enabled: true, endpoint: "http://localhost:11434", model: "gemma4:12b-it-qat", api: .chat),
            instructions: "Clean up filler words. Keep the person's own wording otherwise.",
            context: .init(selectedText: false, clipboard: false, appContext: false),
            autoActivate: [], simulateKeypresses: false, symbol: "terminal")
        let json = (try? ModeStore.encoder.encode(example)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        return """
            A mode is exactly this JSON shape (an example, not a template to copy verbatim -- every \
            field below still has to answer what THIS person described):

            ```json
            \(json)
            ```
            """
    }()

    private static func fieldMeanings(
        installedSpeechModels: [String], chatModels: [String], s1Models: [String]
    ) -> String {
        let speechList = list(installedSpeechModels, whenEmpty: "(none installed on this machine)")
        let chatList = list(chatModels, whenEmpty: "(none installed)")
        let s1List = list(s1Models, whenEmpty: "(none installed)")
        let symbolList = list(ModeSymbol.library, whenEmpty: "(none)")

        return """
            Field by field:
            - "key": a short, lowercase, filename-safe identifier (letters, digits, - and _). It is \
            fine to omit it -- Murmure derives one from "name" when you do.
            - "name": what the mode is called in Murmure's own list.
            - "hotkey": always null in a draft -- the person records their own shortcut afterwards, \
            in the editor. Never invent one.
            - "stt.model": one of the speech models actually installed on this machine, spelled \
            exactly as below:
            \(speechList)
            - "stt.language": an ISO-639-1 code such as "en" or "fr" -- whichever language the \
            person will speak in this mode.
            - "llm.enabled": false for a mode that only transcribes and pastes, with no refinement \
            at all.
            - "llm.api": "chat" for an ordinary instructions-following model, or "s1" for the fast \
            cleanup model below -- read the control-line rules right after this list before ever \
            choosing "s1".
            - "llm.model": with "llm.api": "chat", one of these installed chat models:
            \(chatList)
              With "llm.api": "s1", one of these installed s1 models instead:
            \(s1List)
            - "llm.endpoint": always "http://localhost:11434" -- Murmure only talks to a local \
            Ollama.
            - "instructions": with "chat", written instructions for the model, in plain English, \
            describing how to clean up the transcript. With "s1", a control line -- see the next \
            section, this is not prose.
            - "context.selectedText" / "context.clipboard" / "context.appContext": whether the \
            refiner also reads, respectively, the app's current text selection, the general \
            clipboard, and the name of the frontmost application, as background -- never as \
            something to rewrite. All three are silently ignored under "llm.api": "s1": that api's \
            system turn is fixed by the model card, so there is nowhere to put them; only turn one \
            on when "llm.api" is "chat".
            - "autoActivate": bundle ids (e.g. "com.apple.Terminal") that select this mode \
            automatically when they are the frontmost app. Empty unless the person names specific \
            apps.
            - "simulateKeypresses": always false. It has no effect yet; do not turn it on.
            - "symbol": an SF Symbol name from this exact list, or omit the field entirely for the \
            default glyph:
            \(symbolList)
            """
    }

    /// The `s1` dialect's own grammar, restated from the same rule `Mode.validate()` enforces
    /// (`instructionsAreNotControlFields`) rather than a second description of it that could drift:
    /// a bracketed field, `[Name: value]`, one or more, whitespace-separated, and nothing else --
    /// this model does not read written instructions, it copies whatever is not a recognised field
    /// straight into the person's own transcript (measured; see `Mode.swift`'s doc comment on
    /// `Mode.prompt`).
    private static let controlLineSection = """
        The "s1" control-line grammar: when "llm.api" is "s1", "instructions" must be nothing but \
        bracketed fields such as "\(Mode.prompt.instructions)" (the shipped example below) -- one \
        or more of "[Name: value]", separated only by whitespace, never a sentence of prose. This \
        model does not follow written instructions; it copies anything that is not a recognised \
        bracketed field straight into the cleaned transcript it hands back, which reads as someone \
        else's words appearing inside the person's own dictation. When in doubt, or when the person \
        wants anything more than a light cleanup, use "llm.api": "chat" instead.
        """

    private static let examplesSection: String = {
        let voiceJSON = encoded(Mode.voice)
        let promptJSON = encoded(Mode.prompt)
        return """
            Two modes Murmure ships, for reference:

            "Voice" -- transcription only, no refiner:
            ```json
            \(voiceJSON)
            ```

            "Prompt" -- light cleanup through the s1 control line:
            ```json
            \(promptJSON)
            ```
            """
    }()

    private static let closing = """
        If what the person wants is unclear or underspecified, ask ONE clarifying question and \
        stop there -- do not guess at several fields at once. Once you have enough to propose a \
        mode, answer with a short explanation of what you set and why, followed by exactly ONE \
        fenced ```json block holding the COMPLETE mode (every field above that applies, not a \
        partial patch). That fenced block is what Murmure reads back to build the draft.
        """

    private static func encoded(_ mode: Mode) -> String {
        (try? ModeStore.encoder.encode(mode)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func list(_ items: [String], whenEmpty: String) -> String {
        items.isEmpty ? whenEmpty : items.map { "  - \($0)" }.joined(separator: "\n")
    }
}
