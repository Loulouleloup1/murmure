import Foundation
import MurmureCore
import os

/// What the Models pane is looking at: one row per model Murmure can name, and whether the local
/// Ollama has been asked about the language ones yet.
///
/// Thin, like `VocabularyPaneModel` and for the same reason -- the app target has no test bundle,
/// so anything decided here is verified by reading. Everything that is a decision lives in
/// `MurmureCore` and is tested there: what a directory listing means (`ModelInventory`), whether a
/// half-downloaded model counts as installed (same file), what a probe of Ollama concluded and
/// which sentence that is (`OllamaProbe`). What is left below is one directory walk, one HTTP GET
/// and the published state.
@MainActor
final class ModelsPaneModel: ObservableObject {
    /// The table, speech first (`ModelInventory.table`). Empty until `reload()` -- the pane is
    /// built before it is shown, and walking a 1.5 GB store in an initialiser would be a
    /// filesystem walk nobody asked for.
    @Published private(set) var rows: [ModelRow] = []

    /// A probe is in flight. The button that started it is disabled while it is, so a second
    /// press cannot stack requests on a server that is already not answering.
    @Published private(set) var isChecking = false

    /// Whether the language half has been asked about at all. Drawn as the difference between
    /// "not checked yet" and an answer -- see `OllamaProbe.row(for:outcome:)`.
    @Published private(set) var hasChecked = false

    private let store: URL
    private let speech: [SpeechModelDescriptor]
    /// The language models to ask about, **re-read on every `reload()` rather than frozen at
    /// construction**. It is a closure and not an array because the list is derived from the
    /// modes, and the Modes pane -- one click away in the same window -- can add, rename or
    /// disable a refining mode while this pane is built. A stored array would leave the table
    /// listing the models of the modes as they were when the window was first drawn, which is a
    /// pane that is quietly wrong rather than one that is visibly empty.
    private let language: () -> [LanguageModelReference]
    private var outcomes: [LanguageModelReference: OllamaProbe.Outcome] = [:]
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "models")

    /// A session of its own, and a short one. This is a listing on the loopback address: if it has
    /// not answered in a couple of seconds nothing is listening, and `OllamaChat.timeout`'s 120 s
    /// -- sized for a model generating text -- would leave the pane's spinner running for two
    /// minutes to report "Ollama is not running".
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// `store` is the model folder, injected rather than resolved here for the reason `Storage`
    /// gives: a pane that resolved `Application Support` itself could only ever be pointed at
    /// Louis's real models.
    ///
    /// `speech` carries `WhisperKitEngine`'s own variant constant rather than a copy of the
    /// string, so the table cannot describe a model the app does not run.
    init(
        store: URL,
        speech: [SpeechModelDescriptor],
        language: @escaping () -> [LanguageModelReference]
    ) {
        self.store = store
        self.speech = speech
        self.language = language
    }

    /// The one speech model this app runs, described from `WhisperKitEngine`'s own constants.
    ///
    /// Here rather than at the call site so there is a single expression to pass, and built from
    /// the engine's constants rather than from copies of the two strings: a table that named a
    /// variant or a repository the engine does not download from would describe a model nobody
    /// has, and would do it convincingly.
    static let dictationModel = SpeechModelDescriptor(
        repository: WhisperKitEngine.modelRepo,
        variant: WhisperKitEngine.dictationModel,
        expectedBytes: ModelDownload.transcriptionModelBytes)

    /// Whether there is anything to ask Ollama about. A machine whose modes all transcribe only
    /// has no language rows, and a check button that would probe nothing.
    var hasLanguageRows: Bool { !language().isEmpty }

    /// Re-reads the disk. **Touches no network**: opening a settings pane must not wake another
    /// process, and the language rows keep whatever the last probe said (nothing, on the first
    /// call).
    func reload() {
        rows = ModelInventory.table(
            speech: speech.map { ModelInventory.speechRow(for: $0, in: store) },
            language: language().map {
                OllamaProbe.row(for: $0.identifier, outcome: hasChecked ? outcomes[$0] : nil)
            })
    }

    /// Asks the local Ollama what it has, once, on demand.
    ///
    /// **Not called from `onAppear`, deliberately.** `/api/tags` is a listing and loads no model,
    /// so it is cheap and safe -- but it is still a request to another program, and this task
    /// ships it behind a press so the first version of this pane cannot be the reason a machine
    /// starts talking to Ollama on its own. Making it automatic later is deleting a button.
    func checkOllama() async {
        // Read once, so the loop below and the outcomes it files cannot be about two different
        // lists if the modes change underneath a probe that is already running.
        let references = language()
        guard !isChecking, !references.isEmpty else { return }
        isChecking = true
        for reference in references {
            outcomes[reference] = await probe(reference)
        }
        hasChecked = true
        isChecking = false
        reload()
    }

    private func probe(_ reference: LanguageModelReference) async -> OllamaProbe.Outcome {
        // `ModeStore` refuses a mode whose endpoint is not a URL root (`ModeValidationError
        // .invalidLLMEndpoint`), so this branch means a reference that never came from a mode
        // file. It is classified as the server being unreachable because that is what it is:
        // there is no address to reach.
        guard let base = URL(string: reference.endpoint) else {
            return .failed(.notRunning(detail: "not a URL: \(reference.endpoint)"))
        }
        let url = OllamaProbe.endpoint(base: base)
        let start = Date()
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.malformedResponse(detail: "not an HTTP response"))
            }
            let outcome = OllamaProbe.outcome(
                status: http.statusCode, body: data, model: reference.identifier)
            if case .failed(let failure) = outcome {
                log.info("""
                    probe of \(reference.identifier, privacy: .public) at \
                    \(url.absoluteString, privacy: .public) -- \(failure.description, privacy: .public)
                    """)
            }
            return outcome
        } catch {
            return OllamaProbe.outcome(
                transport: error, elapsed: Date().timeIntervalSince(start))
        }
    }
}
