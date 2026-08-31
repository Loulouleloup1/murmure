import Foundation

/// One mode: which model transcribes, in which language, refined by which LLM with which
/// instructions, in which apps (spec §5).
///
/// The stored shape is exactly the JSON of spec §5 and nothing more. These files are hand-edited
/// in a text editor, so every field is a field someone has to understand; a field added "in case"
/// is a field to explain and to keep working.
public struct Mode: Codable, Equatable {
    public struct STT: Codable, Equatable {
        public var model: String
        public var language: String

        public init(model: String, language: String) {
            self.model = model
            self.language = language
        }
    }

    public struct LLM: Codable, Equatable {
        public var enabled: Bool
        public var endpoint: String
        public var model: String

        public init(enabled: Bool, endpoint: String, model: String) {
            self.enabled = enabled
            self.endpoint = endpoint
            self.model = model
        }
    }

    public struct Context: Codable, Equatable {
        public var selectedText: Bool
        public var clipboard: Bool
        public var appContext: Bool

        public init(selectedText: Bool, clipboard: Bool, appContext: Bool) {
            self.selectedText = selectedText
            self.clipboard = clipboard
            self.appContext = appContext
        }
    }

    /// Also the file name: the mode lives in `modes/<key>.json`.
    public var key: String
    public var name: String
    public var hotkey: KeyCombo?
    public var stt: STT
    public var llm: LLM
    public var instructions: String
    public var context: Context
    /// Bundle ids that select this mode automatically. Resolved at recording start (lot 2, task 4).
    public var autoActivate: [String]
    public var simulateKeypresses: Bool

    public init(
        key: String, name: String, hotkey: KeyCombo? = nil, stt: STT, llm: LLM,
        instructions: String, context: Context, autoActivate: [String],
        simulateKeypresses: Bool
    ) {
        self.key = key
        self.name = name
        self.hotkey = hotkey
        self.stt = stt
        self.llm = llm
        self.instructions = instructions
        self.context = context
        self.autoActivate = autoActivate
        self.simulateKeypresses = simulateKeypresses
    }

    /// Written by hand for one reason that only matters because a human opens this file: the
    /// synthesised encoder uses `encodeIfPresent` for optionals, so a mode with no hotkey would
    /// have no `hotkey` line at all, where spec §5 shows `"hotkey": null` -- a field you cannot
    /// see is a field you cannot fill in. Decoding stays synthesised.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(name, forKey: .name)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(stt, forKey: .stt)
        try container.encode(llm, forKey: .llm)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(context, forKey: .context)
        try container.encode(autoActivate, forKey: .autoActivate)
        try container.encode(simulateKeypresses, forKey: .simulateKeypresses)
    }
}

/// One case per field a mode file can get wrong, so a report can name the line to fix rather than
/// say "invalid mode".
public enum ModeValidationError: Error, Equatable, CustomStringConvertible {
    case emptyKey
    case keyIsNotFilenameSafe(String)
    case emptyName
    case emptySTTModel
    case emptySTTLanguage
    case invalidLLMEndpoint(String)
    case llmEndpointIsNotARoot(endpoint: String, root: String)
    case emptyLLMModel
    case emptyInstructions

    public var description: String {
        switch self {
        case .emptyKey: "\"key\" is empty"
        case .keyIsNotFilenameSafe(let key):
            "\"key\" \(key.debugDescription) is not usable as a file name (letters, digits, - and _ only)"
        case .emptyName: "\"name\" is empty"
        case .emptySTTModel: "\"stt.model\" is empty"
        case .emptySTTLanguage: "\"stt.language\" is empty"
        case .invalidLLMEndpoint(let endpoint):
            "\"llm.endpoint\" \(endpoint.debugDescription) is not an http(s) URL"
        case .llmEndpointIsNotARoot(let endpoint, let root):
            """
            "llm.endpoint" \(endpoint.debugDescription) must be the server root: Murmure appends \
            the API path itself. Write \(root.debugDescription).
            """
        case .emptyLLMModel: "\"llm.model\" is empty while \"llm.enabled\" is true"
        case .emptyInstructions: "\"instructions\" is empty while \"llm.enabled\" is true"
        }
    }
}

extension Mode {
    /// The `key` doubles as the file name, so it is restricted to characters that cannot escape
    /// the modes folder or collide with the `.json` suffix.
    private static let filenameSafeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// The first field that is wrong, or nil. Separate from `validate()` because `ModeStore` needs
    /// the case to build its report and a non-throwing function cannot catch one exhaustively.
    var validationError: ModeValidationError? {
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyKey }
        if !key.unicodeScalars.allSatisfy(Self.filenameSafeCharacters.contains) {
            return .keyIsNotFilenameSafe(key)
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if stt.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptySTTModel }
        if stt.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptySTTLanguage
        }

        // The three LLM fields exist only to be sent to Ollama. Requiring them on a mode whose
        // refiner is off would make `Voice`, the shipped default, invalid.
        guard llm.enabled else { return nil }

        guard let url = URL(string: llm.endpoint), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host
        else { return .invalidLLMEndpoint(llm.endpoint) }

        // The endpoint is the server root, not an API URL: the client appends the API path itself.
        // A path left here is silently concatenated, and spec §5's own example carried "/v1" --
        // which yields /v1/api/chat, a 404, and a client that can only report it as a response it
        // could not read. Someone who copied the example would go looking for a bug.
        //
        // A lone "/" passes: it addresses the same root, it is what a copy-paste from a browser
        // gives, and it costs nothing -- measured on the client as shipped, `URL.appending(path:)`
        // turns "http://localhost:11434/" and "http://localhost:11434" into the same
        // "http://localhost:11434/api/chat".
        if !url.path.isEmpty, url.path != "/" {
            return .llmEndpointIsNotARoot(
                endpoint: llm.endpoint,
                root: "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? ""))
        }
        if llm.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyLLMModel }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyInstructions
        }
        return nil
    }

    /// Throws on the first invalid field, naming it. Called by `ModeStore.save`, so a mode that
    /// does not validate is a mode that never reaches the disk.
    public func validate() throws {
        if let error = validationError { throw error }
    }
}

// MARK: - Built-in modes (spec §5)

extension Mode {
    /// The four modes written on first launch. All editable afterwards, `Voice` included.
    public static let builtIns: [Mode] = [.voice, .prompt, .message, .email]

    /// Raw transcription, no LLM -- the default mode and the daily driver for Claude Code.
    /// Lot 2 requires this one to stay byte-identical to the dictation shipped in lot 1.
    public static let voice = Mode(
        key: "voice", name: "Voice",
        stt: .init(model: defaultSTTModel, language: defaultLanguage),
        llm: .init(enabled: false, endpoint: defaultEndpoint, model: defaultLLMModel),
        instructions: "",
        context: .init(selectedText: false, clipboard: false, appContext: false),
        autoActivate: [], simulateKeypresses: false
    )

    /// Light cleanup for dictating to AI harnesses. Instructions are `prompt_cleanup_A.txt`
    /// verbatim: they are what 45 blind scores were produced against, and the plan is explicit
    /// that editing them invalidates that evidence. `A` is the best non-few-shot variant on the
    /// shipped model -- 3 judges out of 3 rank it above the baseline on `gemma4-12b-qat`.
    public static let prompt = Mode(
        key: "prompt", name: "Prompt",
        stt: .init(model: defaultSTTModel, language: defaultLanguage),
        llm: .init(enabled: true, endpoint: defaultEndpoint, model: defaultLLMModel),
        instructions: """
You edit a raw speech-to-text transcript. The input is French dictation, often containing English technical terms.

Your output must be reachable from the input by these three operations only:
1. DELETE hesitations (euh, hum), meaningless fillers (alors, donc, du coup, genre, tu vois, quoi), stuttered repetitions, and abandoned false starts — keep the wording the speaker landed on.
2. ADD punctuation, capitalisation and paragraph breaks.
3. RENDER dictated symbols: "slash" as /, "point" as . inside a path, filename or URL.

Every word you do not delete under operation 1 stays exactly as spoken: same word, same spelling, same order, same language. This covers technical terms, product names, file paths, commands, English words, numbers and proper nouns. If a better word comes to mind, keep the original one. If in doubt, do not change it.

Two things go wrong on this task. Avoid both:
- Returning the transcript unchanged. A raw dictation almost always carries at least one filler or one missing full stop; apply operations 1-3 wherever they apply.
- Rewriting. Substituting a synonym, reordering a clause, merging two sentences or translating a term is out of scope even when it would read better.

Return the edited transcript and nothing else.
""",
        context: .init(selectedText: false, clipboard: false, appContext: false),
        autoActivate: [], simulateKeypresses: false
    )

    /// Short conversational rewrite for Slack. Instructions are `message_rewrite.txt` verbatim.
    public static let message = Mode(
        key: "message", name: "Message",
        stt: .init(model: defaultSTTModel, language: defaultLanguage),
        llm: .init(enabled: true, endpoint: defaultEndpoint, model: defaultLLMModel),
        instructions: """
You turn dictated text into a short Slack message. The input is a raw speech-to-text transcript in French, often mixed with English technical terms.

Rules:
- Rewrite as a concise, informal-professional Slack message in French (tutoiement).
- Remove all hesitations, fillers, and false starts.
- Keep every technical term, product name, path, and English word exactly as dictated — never translate them.
- Keep the original intent and ALL factual content (numbers, names, questions). Do not add greetings or sign-offs the speaker did not say.
- Output ONLY the message text. No preamble, no quotes, no markdown fences, no commentary.
""",
        context: .init(selectedText: false, clipboard: false, appContext: false),
        autoActivate: [], simulateKeypresses: false
    )

    /// Structured rewrite for email. Unlike the other two, these instructions were NOT benchmarked
    /// -- lot 0 measured `prompt_cleanup` and `message_rewrite` only, and no email prompt exists in
    /// `benchmark/prompts/`. They follow the shape of the measured ones and are a starting point.
    public static let email = Mode(
        key: "email", name: "Email",
        stt: .init(model: defaultSTTModel, language: defaultLanguage),
        llm: .init(enabled: true, endpoint: defaultEndpoint, model: defaultLLMModel),
        instructions: """
You turn dictated text into an email. The input is a raw speech-to-text transcript in French, often mixed with English technical terms.

Rules:
- Rewrite as a clear, professional email in French: an opening line, the body in paragraphs, a closing line.
- Remove all hesitations, fillers, and false starts.
- Keep every technical term, product name, path, and English word exactly as dictated - never translate them.
- Keep the original intent and ALL factual content (numbers, names, questions). Do not invent a recipient, a subject, or any fact the speaker did not say.
- Output ONLY the body of the email. No subject line, no preamble, no quotes, no markdown fences, no commentary.
""",
        context: .init(selectedText: false, clipboard: false, appContext: false),
        autoActivate: [], simulateKeypresses: false
    )

    /// Spec §3: large-v3-turbo for live dictation.
    private static let defaultSTTModel = "large-v3-turbo"

    /// Pinned, not `"auto"`. Measured on the whole 1 449-dictation corpus: `detectLanguage` is
    /// re-evaluated per window and produced 9 non-Latin transcripts plus unseen language switches,
    /// and it accounted for every case where Superwhisper beat us. Per-mode, so a future English
    /// mode changes this field rather than the mechanism.
    private static let defaultLanguage = "fr"

    /// Ollama's native API root. Spec §5 shows `/v1` (its OpenAI-compatible surface), but lot 2
    /// task 2 pins the client to `/api/chat` with `think: false` and explicit `options`, none of
    /// which exist under `/v1`. Storing the root keeps the client from having to strip a suffix.
    private static let defaultEndpoint = "http://localhost:11434"

    /// v2 benchmark winner, unanimous across 3 judges: fidelity mean 1.98 / min 1 and 0 auto-fails
    /// against 1.52 / min 0 and 3 auto-fails for the 4.3 GB model. The tag is the Ollama model id,
    /// not the benchmark's `gemma4-12b-qat` alias.
    private static let defaultLLMModel = "gemma4:12b-it-qat"
}
