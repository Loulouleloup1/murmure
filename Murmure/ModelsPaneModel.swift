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

    // MARK: - Adding a speech model

    /// What Louis has typed into "add a speech model" so far -- a repository id or a pasted URL,
    /// unparsed. Parsing happens on press (`fetchSpeechModelListing`), not on every keystroke: a
    /// half-typed id is not an error, it is just not a repository yet.
    @Published var repositoryInput = ""
    @Published private(set) var isFetchingListing = false
    @Published private(set) var listing: SpeechModelCatalog.Listing?
    /// Set only when `repositoryInput` itself could not be read as a repository -- distinct from
    /// `listing`'s own `.failure`, which means the repository WAS well-formed and the network or
    /// the Hub said no.
    @Published private(set) var repositoryInputError: String?

    /// The variant currently downloading, or `nil`. One at a time: a second press while the first
    /// is still running would start a second multi-gigabyte transfer into the same store.
    @Published private(set) var installingVariant: String?
    @Published private(set) var installProgress: ModelPreparation?
    @Published private(set) var installError: String?

    // MARK: - Pulling a language model

    /// The references currently being pulled, so the button they came from can disable itself and
    /// no two presses on the same row stack two pulls.
    @Published private(set) var pullingModels: Set<LanguageModelReference> = []
    /// The latest line Ollama reported for a pull, or the remedy once it failed. Cleared on
    /// success, where `checkOllama()`'s own refresh becomes the row's story instead.
    @Published private(set) var pullStatus: [LanguageModelReference: String] = [:]

    private let puller = OllamaPuller()

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
            speech: speech.map {
                // Only the shipped default is known to have already paid the Neural Engine
                // compile: `scripts/bootstrap.sh` warms exactly that one before Murmure is ever
                // used (`ModelInventory.firstUseNotice`'s own doc comment). Anything else in
                // `speech` -- today, nothing; after a pane-driven install, that variant -- has no
                // such guarantee and says so.
                ModelInventory.speechRow(
                    for: $0, in: store, knownWarm: $0.variant == Self.dictationModel.variant)
            },
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

    // MARK: - Adding a speech model

    /// Reads `repositoryInput` and asks that repository what it offers. A press, like
    /// `checkOllama` -- listing a repository is a read, but it is still a request this pane must
    /// not make on its own just because it was opened.
    func fetchSpeechModelListing() async {
        guard let repository = HuggingFaceRepository.parse(repositoryInput) else {
            listing = nil
            repositoryInputError =
                "That doesn't look like a Hugging Face repository. Paste \"owner/repo\", or its huggingface.co URL."
            return
        }
        repositoryInputError = nil
        isFetchingListing = true
        listing = await SpeechModelCatalog.fetchListing(repository: repository)
        isFetchingListing = false
    }

    /// Downloads `variant` from the repository named in `repositoryInput` -- which
    /// `fetchSpeechModelListing` must already have parsed successfully, since `variant` only
    /// exists as a choice offered from its result.
    ///
    /// The size is NOT known in advance for a repository picked this way: `WhisperKit`'s listing
    /// API answers with names, never sizes (`SpeechModelCatalog`'s own doc comment). `0` is passed
    /// rather than a guess, and it is what makes the size column read "size unknown" instead of a
    /// fabricated number -- see `ModelsPaneView` for where that reads as a sentence.
    func install(variant: String) async {
        guard let repository = HuggingFaceRepository.parse(repositoryInput) else { return }
        installingVariant = variant
        installError = nil
        let descriptor = SpeechModelDescriptor(repository: repository, variant: variant, expectedBytes: 0)
        do {
            _ = try await WhisperKitEngine.installSpeechModel(descriptor) { [weak self] preparation in
                self?.installProgress = preparation
            }
            installingVariant = nil
            installProgress = nil
            listing = nil
            repositoryInput = ""
        } catch {
            installingVariant = nil
            installProgress = nil
            installError = error.localizedDescription
        }
        reload()
    }

    // MARK: - Pulling a language model

    /// Which reference a row's identifier means, so the view -- which only ever sees `ModelRow`,
    /// with no endpoint on it -- can ask for a pull without knowing `language()`'s own shape.
    ///
    /// **The one thing this cannot tell apart.** Two modes naming the SAME model on two different
    /// endpoints are two distinct rows in `ModelInventory.languageModels` but share one
    /// `identifier`, and `ModelRow` carries no endpoint to disambiguate them (§ "which language
    /// models the table shows" in `ModelInventoryTests`). This returns the first match, which is
    /// the accepted limit of pulling from this pane rather than from a mode editor: it is rare
    /// enough that this task does not solve it, and correcting it would mean widening `ModelRow`'s
    /// own shape for every row, speech included, to fix a language-only edge case.
    private func reference(forRowIdentifier identifier: String) -> LanguageModelReference? {
        language().first { $0.identifier == identifier }
    }

    func isPulling(_ identifier: String) -> Bool {
        guard let reference = reference(forRowIdentifier: identifier) else { return false }
        return pullingModels.contains(reference)
    }

    /// The line to show under a row that is being pulled, or has just failed to be.
    func pullStatus(for identifier: String) -> String? {
        guard let reference = reference(forRowIdentifier: identifier) else { return nil }
        return pullStatus[reference]
    }

    /// Asks Ollama to pull the model named by `identifier`'s row.
    func pull(modelIdentifier identifier: String) async {
        guard let reference = reference(forRowIdentifier: identifier), !pullingModels.contains(reference)
        else { return }
        guard let base = URL(string: reference.endpoint) else {
            pullStatus[reference] = OllamaPullFailure.notRunning(detail: "not a URL: \(reference.endpoint)").remedy
            return
        }
        pullingModels.insert(reference)
        pullStatus[reference] = "Starting -- pulling manifest"
        let outcome = await puller.pull(model: reference.identifier, endpoint: base) { [weak self] line in
            Task { @MainActor in self?.pullStatus[reference] = Self.describe(line) }
        }
        pullingModels.remove(reference)
        switch outcome {
        case .succeeded:
            // Ollama's own listing is what says the real size now that the model is there --
            // `outcomes[reference]` from a fabricated value would be a number nobody measured.
            pullStatus[reference] = nil
            await checkOllama()
        case .failed(let failure):
            pullStatus[reference] = failure.remedy
        case .progress:
            break
        }
    }

    private static func describe(_ line: OllamaPull.LineOutcome) -> String {
        switch line {
        case .progress(let status, let fraction):
            guard let fraction else { return status }
            return "\(status) -- \(Int(fraction * 100))%"
        case .succeeded: return "Pulled."
        case .failed(let failure): return failure.remedy
        }
    }
}
