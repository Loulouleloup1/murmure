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
        /// Which of Ollama's two request shapes this model is talked to in.
        ///
        /// A **declared** field and not a look at `model`, deliberately. `s1-mini` returns empty
        /// content on `/api/chat` — Ollama parses its open `<think>` block — so it has to be
        /// driven through `/api/generate` with the conversation written by hand. Deciding that
        /// with `if model.contains("s1-mini")` would put one vendor's model id in the routing
        /// code, and the next model that needs the same treatment would silently get the wrong
        /// one. Here the mode file says which protocol it speaks, and the code never reads the
        /// model name.
        ///
        /// The value names a **wire protocol**, not a model: a sibling release that keeps the
        /// same conversation format is `"s1"` too, and a model that speaks neither needs a third
        /// case rather than a special case.
        public enum API: String, Codable {
            /// `/api/chat`: `instructions` is the system turn, the transcript is the user turn,
            /// and Ollama applies the model's own chat template. See ``OllamaChat``.
            case chat

            /// `/api/generate` with `raw: true`: the whole conversation is written by hand, the
            /// system prompt is fixed by the model card, and `instructions` carries only the
            /// control line (`[Context: general]`). See ``OllamaS1``.
            case s1
        }

        public var enabled: Bool
        public var endpoint: String
        public var model: String
        public var api: API

        public init(enabled: Bool, endpoint: String, model: String, api: API = .chat) {
            self.enabled = enabled
            self.endpoint = endpoint
            self.model = model
            self.api = api
        }

        /// Decoded by hand for one field. `api` is absent from every mode file written before
        /// `s1-mini` shipped, and every one of those files names a model that speaks `/api/chat`
        /// — so an absent `api` means `.chat`, the value that keeps an existing file doing
        /// exactly what it did yesterday. The synthesised decoder would refuse them outright and
        /// Louis would lose his hand-edited modes to a field he never wrote.
        ///
        /// Encoding stays synthesised, so a mode Murmure writes always carries the field
        /// explicitly: the default exists for files from before it, not as a value to leave out.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            endpoint = try container.decode(String.self, forKey: .endpoint)
            model = try container.decode(String.self, forKey: .model)
            api = try container.decodeIfPresent(API.self, forKey: .api) ?? .chat
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
    case instructionsAreNotControlFields(String)

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
        case .instructionsAreNotControlFields(let instructions):
            """
            "instructions" \(instructions.prefix(60).debugDescription) is not a control line. \
            With "api": "s1" the whole interface is bracketed fields such as "[Context: general]" \
            — the model does not follow written instructions, it copies them into the text it \
            gives back.
            """
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

        // Prose in an `s1` mode is not merely ignored: measured on the v3 probe, a sentence
        // appended to the control line came back **verbatim at the top of the cleaned text** on
        // 1 of 4 fixtures. That is Louis's dictation with someone else's words pasted into it,
        // and nothing downstream can tell it apart from a refinement. Caught here, the mode is
        // reported as unusable and the raw transcript is inserted instead.
        if llm.api == .s1, !Self.containsOnlyControlFields(instructions) {
            return .instructionsAreNotControlFields(instructions)
        }
        return nil
    }

    /// Whether `text` holds nothing but bracketed control fields — `[Context: general]`, or
    /// several of them separated by whitespace.
    ///
    /// Written as a scan rather than a regex so the rule is readable in one pass: a field opens
    /// with `[`, is not empty, holds no second `[`, closes on the first `]`, and nothing but
    /// whitespace separates two of them. It says nothing about *which* fields exist; the model
    /// owns that vocabulary, and a mode naming a field it does not know gets a worse refinement,
    /// not corrupted text.
    ///
    /// Empty text is vacuously true, as the name says — "only control fields" and "no fields at
    /// all" are the same claim here. The caller has already refused an empty `instructions` with
    /// its own error, which is the one a reader needs to see.
    private static func containsOnlyControlFields(_ text: String) -> Bool {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while !rest.isEmpty {
            guard rest.first == "[", let close = rest.firstIndex(of: "]") else { return false }
            let body = rest[rest.index(after: rest.startIndex)..<close]
            guard !body.isEmpty, !body.contains("[") else { return false }
            rest = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
        }
        return true
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
        llm: .init(enabled: false, endpoint: defaultEndpoint, model: rewriteModel),
        instructions: "",
        context: .init(selectedText: false, clipboard: false, appContext: false),
        autoActivate: [], simulateKeypresses: false
    )

    /// Light cleanup for dictating to AI harnesses -- the mode the refiner exists for.
    ///
    /// Runs `s1-mini`, a 1 GB model trained for exactly this task, rather than the 8.6 GB
    /// general-purpose model the other two use. Measured over 784 generations on 48 of Louis's
    /// own dictations: 1.08 GB resident against 8.63, a 0.38 s median against 3.82, and the
    /// transcript returned untouched 4 times out of 48 against 17 -- the failure that makes a
    /// refiner pointless. The instructions are the whole difference in interface: they are the
    /// model's control line, not prose (see ``Mode/LLM/API/s1``).
    ///
    /// **What the switch costs**, not hidden here because whoever edits this file is the person
    /// who will notice it: **sentences get merged**. 9 of the 48 real dictations come back with
    /// fewer sentences than they went in (counted on `.`/`!`/`?`), the widest a 416-word passage
    /// going from 27 down to 22. No control field and no option moves it -- it is the one
    /// fidelity cost of this model that has no setting behind it.
    ///
    /// What it does **not** cost, checked rather than assumed. This model does not turn a spoken
    /// "slash" into `/`, where the 12 B one does; that is not a limitation here, because Louis
    /// does not dictate paths -- the ones in the corpus arrived through his clipboard. What has
    /// to survive is a path or identifier **already written** in the transcript, and that is
    /// measured: `IndicatorList`, `true/false`, `~/Library/Application Support/Murmure/modes`,
    /// `tests/unit`, `files_used` and `p90` all come back through this mode character for
    /// character.
    ///
    /// A mode that cannot afford the merged sentences is a mode to point back at
    /// `gemma4:12b-it-qat` with `"api": "chat"`; both are still installed and both still work.
    public static let prompt = Mode(
        key: "prompt", name: "Prompt",
        stt: .init(model: defaultSTTModel, language: defaultLanguage),
        llm: .init(enabled: true, endpoint: defaultEndpoint, model: cleanupModel, api: .s1),
        // `[Context: general]` ALONE, and the omissions are the measured part. Adding
        // `[Styling: ...]` -- which the model card presents as the normal way to use the model --
        // drops sentence capitalisation from 96 % to 29 % on these same 48 dictations, and
        // `[Styling: casual]` is the arm where the runaway repetitions of `OllamaS1.repeatPenalty`
        // were found. Every field added here is a field to re-measure.
        instructions: "[Context: general]",
        context: .init(selectedText: false, clipboard: false, appContext: false),
        autoActivate: [], simulateKeypresses: false
    )

    /// Short conversational rewrite for Slack. Instructions are `message_rewrite.txt` verbatim.
    public static let message = Mode(
        key: "message", name: "Message",
        stt: .init(model: defaultSTTModel, language: defaultLanguage),
        llm: .init(enabled: true, endpoint: defaultEndpoint, model: rewriteModel),
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
        llm: .init(enabled: true, endpoint: defaultEndpoint, model: rewriteModel),
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

    /// The cleanup model: purpose-built for normalising speech-to-text, 1.08 GB resident, 0.38 s
    /// median. Speaks ``LLM/API/s1`` and nothing else. The tag is the Ollama model id, not the
    /// benchmark's `s1-mini` alias.
    private static let cleanupModel = "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"

    /// The rewriting model, for the two modes that ask for something a cleanup model cannot do.
    ///
    /// `Message` and `Email` do not clean a transcript, they rewrite it from written instructions
    /// -- and s1-mini follows no instructions at all, it copies them into its answer (v3 probe,
    /// 1 fixture in 4). Nothing in the 784-generation benchmark measured those two tasks on it,
    /// so they stay where their evidence is: v2 winner, unanimous across 3 judges, fidelity mean
    /// 1.98 / min 1 and 0 auto-fails against 1.52 / min 0 and 3 auto-fails for the 4.3 GB model.
    ///
    /// Also the placeholder in `Voice`, whose refiner is off -- unchanged so that turning it on
    /// by hand does what it did before.
    private static let rewriteModel = "gemma4:12b-it-qat"
}
