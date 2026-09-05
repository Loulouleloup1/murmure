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
/// which sentence that is (`OllamaProbe`). What is left below is the directory walks, the HTTP
/// calls and the published state.
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

    // MARK: - Adding a model

    /// What "Inspect" concluded, or `nil` when the sheet is dismissed. Louis's own words on the
    /// old, speech-only version of this field: *"je veux ajouter N'IMPORTE QUEL modèle et choisir
    /// moi-même s'il s'agit d'un modèle de parole ou d'un modèle de raffinement"* -- so the field
    /// takes anything, and this is what a press of Inspect read it as.
    enum Inspection: Equatable {
        /// `repository` is `HuggingFaceRepository.parse`'s output -- the canonical `owner/repo`.
        case huggingFace(repository: String, classification: HuggingFaceClassification)
        /// The input did not parse as a Hugging Face id or URL, so it is read as an Ollama model
        /// name (`gemma4:12b-it-qat`, `hf.co/owner/repo:QUANT`) and pulled exactly as typed --
        /// there is nothing further to classify about a name Ollama itself will resolve.
        case ollamaName(String)
        /// The repository looked well-formed but Hugging Face could not answer for it -- distinct
        /// from a repository classified `.notRunnable`, which DID answer.
        case failure(detail: String)
    }

    /// What Louis has typed into "Add a model" so far -- a Hugging Face id, a pasted
    /// `huggingface.co` URL, or an Ollama model name, unparsed. Parsing and classification happen
    /// on press (`inspect()`), not on every keystroke: a half-typed id is not an error, it is just
    /// not a repository yet.
    @Published var addModelInput = ""
    @Published private(set) var isInspecting = false
    @Published private(set) var inspection: Inspection?
    /// Which engine the selected candidate would install under. Pre-selected when `inspection` is
    /// unambiguous (`.speechOnly`/`.refinerOnly`/`.ollamaName`), left `nil` for `.both` so Louis
    /// chooses -- see design notes on the sheet for why the radio still shows in the unambiguous
    /// case rather than being hidden.
    @Published var selectedRole: ModelRole?
    /// The variant name (speech) or `.gguf` filename (refiner) currently chosen from the candidate
    /// list, or `nil` before anything is picked.
    @Published var selectedCandidateID: String?
    @Published private(set) var isSearchingSuggestions = false
    /// Repository ids `ModelInspector.searchGGUFConversions` found for a `.notRunnable` repository
    /// that publishes safetensors -- each an "Inspect this instead" affordance.
    @Published private(set) var ggufSuggestions: [String] = []

    /// The variant currently downloading, or `nil`. One at a time: a second press while the first
    /// is still running would start a second multi-gigabyte transfer into the same store.
    @Published private(set) var installingVariant: String?
    /// The last install OR delete failure with something to say -- `installSpeech`'s own catch,
    /// and now `confirmDeletion`'s. One field rather than two: both are "the last thing this pane
    /// tried to do to a model's files or to Ollama's store failed, and here is why" -- an install
    /// failure only ever shows while the sheet the failure belongs to is still open, and a delete
    /// failure is drawn beside the row it came from (`ModelsPaneView`'s own error line), so the
    /// two are never on screen making different claims about the same field at once.
    @Published private(set) var installError: String?

    /// A refiner pull started from the Inspect sheet -- distinct from `pullingModels`/`pullStatus`
    /// below, which are keyed on a `LanguageModelReference` a mode already names. A model typed
    /// into "Add a model" has no mode and no known endpoint yet, so it gets its own single-flight
    /// flag rather than a dictionary entry for a reference that does not exist.
    @Published private(set) var isInstallingRefiner = false
    @Published private(set) var refinerInstallStatus: String?

    // MARK: - Deleting

    /// A delete Louis pressed but has not confirmed yet -- the row it came from, and the question
    /// and directories `ModelInventory.removal`/`removal(forLanguageModel:)` computed for it. The
    /// view reads this to drive its confirmation `.alert`; nothing is removed until
    /// `confirmDeletion()` is called.
    @Published private(set) var pendingRemoval: (row: ModelRow, removal: ModelRemoval)?

    private let deleter = OllamaDeleter()

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
    /// The speech model every mode currently resolves to, one entry per mode -- the same
    /// derived-from-modes reasoning as `language` above, and resolved the same way
    /// `ModesPaneView`'s picker resolves a stored value: through `SpeechModelResolution`, so a
    /// mode still holding the shipped alias or a bare variant is compared as the reference it
    /// actually means rather than as the raw string in its file.
    private let speechModels: () -> [SpeechModelReference]
    /// Every mode, re-read on every call rather than frozen at construction -- the same reasoning
    /// as `language` and `speechModels` above. This is what a delete confirmation asks
    /// `ModelInventory.modesNaming`/`modesNaming(languageModel:in:)` about: which modes, right now,
    /// still name the model about to be removed.
    private let modes: () -> [Mode]
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
        language: @escaping () -> [LanguageModelReference],
        speechModels: @escaping () -> [SpeechModelReference],
        modes: @escaping () -> [Mode]
    ) {
        self.store = store
        self.speech = speech
        self.language = language
        self.speechModels = speechModels
        self.modes = modes
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

    /// Re-reads the disk, and reads (never probes) the local Ollama's own listing when it actually
    /// is local. **The one relaxation of "touches no network" this pane makes, and a deliberate,
    /// gated one**: `/api/tags` on `localhost` reads Ollama's manifest directory and loads
    /// nothing, so it is the same kind of read `ModelInventory.installedSpeechModels` already makes
    /// of the speech store just below -- not the multi-gigabyte download or model load the rest of
    /// this file keeps behind a press. `languageRows()`'s own `OllamaEndpoint.isLoopback` check is
    /// what keeps that true: a mode naming a remote server is left to the `checkOllama()` press
    /// instead. `ModesPaneModel.reload()` documents the identical relaxation and the identical
    /// gate, for the identical reason.
    func reload() async {
        rows = ModelInventory.table(speech: speechRows(), language: await languageRows())
    }

    /// Every speech row: what Murmure itself knows how to run (today, only the shipped default,
    /// described from `WhisperKitEngine`'s own constants), every reference actually installed
    /// under `store`, and every reference a mode currently resolves to but does not have on disk
    /// -- the last two folded in without duplicating a reference already covered by the first.
    /// `ModelInventory.speechRow` reads a reference's own folder to decide `.installed` versus
    /// `.absent`, so a mode-named-but-missing reference needs no separate case here: the same call
    /// that describes an installed one describes it correctly as absent too.
    private func speechRows() -> [ModelRow] {
        var rows: [ModelRow] = []
        var seen: Set<SpeechModelReference> = []
        for descriptor in speech {
            // Only the shipped default is known to have already paid the Neural Engine compile:
            // `scripts/bootstrap.sh` warms exactly that one before Murmure is ever used
            // (`ModelInventory.firstUseNotice`'s own doc comment). Anything else -- an installed
            // or mode-named reference below -- has no such guarantee and says so.
            rows.append(ModelInventory.speechRow(
                for: descriptor, in: store, knownWarm: descriptor.variant == Self.dictationModel.variant))
            seen.insert(descriptor.reference)
        }
        for reference in ModelInventory.installedSpeechModels(in: store) where !seen.contains(reference) {
            rows.append(ModelInventory.speechRow(for: reference, in: store))
            seen.insert(reference)
        }
        for reference in speechModels() where !seen.contains(reference) {
            rows.append(ModelInventory.speechRow(for: reference, in: store))
            seen.insert(reference)
        }
        return rows
    }

    /// Every language row: Ollama's own listing, read once on the first enabled refining mode's
    /// endpoint, plus a row for every mode-named model that listing does not carry -- shown
    /// `.absent`, the same sentence `checkOllama()`'s own per-model probe already gives that case.
    ///
    /// Falls back to the pre-listing behaviour (`outcomes`, filled only by the `checkOllama()`
    /// button, or "not checked yet" before it has ever run) when there is no endpoint to ask, the
    /// endpoint is not loopback (`OllamaEndpoint.isLoopback` -- a mode may legitimately name a
    /// remote server, and reaching it every time this pane appears is the silent network access
    /// the automatic read must not make), or the listing could not be read -- a table must still
    /// name the models Louis's modes point at even when the automatic read did not run, which is
    /// exactly what `checkOllama()`'s own press is still there for.
    private func languageRows() async -> [ModelRow] {
        let named = language()
        guard let endpoint = named.first?.endpoint, let base = URL(string: endpoint),
              OllamaEndpoint.isLoopback(base)
        else {
            return named.map { OllamaProbe.row(for: $0.identifier, outcome: hasChecked ? outcomes[$0] : nil) }
        }
        let url = OllamaProbe.endpoint(base: base)
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              case .listed(let listed) = OllamaProbe.list(status: http.statusCode, body: data)
        else {
            return named.map { OllamaProbe.row(for: $0.identifier, outcome: hasChecked ? outcomes[$0] : nil) }
        }
        var rows = listed.map { OllamaProbe.row(for: $0.name, outcome: .pulled(bytes: $0.bytes)) }
        for reference in named {
            // Reads the SAME body against this one reference's own identifier, tag and all --
            // `outcome(status:body:model:)` is the tested match (`OllamaProbeTests`'s implicit
            // `:latest` cases) that keeps "gemma4" and the listing's "gemma4:latest" from becoming
            // two rows for one model. `.pulled` here means the row above already covers it.
            if case .failed(.modelNotPulled) =
                OllamaProbe.outcome(status: http.statusCode, body: data, model: reference.identifier) {
                rows.append(OllamaProbe.row(
                    for: reference.identifier, outcome: .failed(.modelNotPulled(model: reference.identifier))))
            }
        }
        return rows
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
        await reload()
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

    // MARK: - Adding a model

    /// Reads `addModelInput` and classifies it -- a Hugging Face repository's blob listing through
    /// `ModelInspector`, or, when it does not parse as one, an Ollama name taken as-is. A press,
    /// like `checkOllama` -- inspecting is a read, but it is still a request this pane must not
    /// make on its own just because it was opened.
    func inspect() async {
        let trimmed = addModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isInspecting else { return }
        isInspecting = true
        inspection = nil
        selectedRole = nil
        selectedCandidateID = nil
        ggufSuggestions = []
        installError = nil
        refinerInstallStatus = nil

        if let repository = HuggingFaceRepository.parse(trimmed) {
            switch await ModelInspector.classify(repository: repository) {
            case .success(let classification):
                inspection = .huggingFace(repository: repository, classification: classification)
                selectedRole = Self.preselectedRole(for: classification)
                // Only worth searching when the reason IS safetensors: an empty or unreadable
                // repository has no conversion to look for either, and a search for it would be a
                // request nobody's press asked for.
                if case .notRunnable(_, true) = classification {
                    isSearchingSuggestions = true
                    ggufSuggestions = await ModelInspector.searchGGUFConversions(
                        of: repository.split(separator: "/").last.map(String.init) ?? repository)
                    isSearchingSuggestions = false
                }
            case .failure(let failure):
                inspection = .failure(detail: Self.describe(failure))
            }
        } else {
            // Not a Hugging Face shape -- Louis's own two examples, `gemma4:12b-it-qat` and
            // `hf.co/owner/repo:QUANT`, are both Ollama names and neither needs classifying: an
            // Ollama name IS the refiner candidate, pulled exactly as typed.
            inspection = .ollamaName(trimmed)
            selectedRole = .refiner
        }
        isInspecting = false
    }

    /// Re-runs `inspect()` against a repository `ggufSuggestions` offered -- the "Inspect this
    /// instead" affordance on a `.notRunnable` result.
    func inspectSuggestion(_ repository: String) async {
        addModelInput = repository
        await inspect()
    }

    /// Closes the sheet and clears everything it was showing, so the next press of "Inspect"
    /// starts from nothing rather than from whatever the last repository left behind.
    func dismissInspection() {
        addModelInput = ""
        inspection = nil
        selectedRole = nil
        selectedCandidateID = nil
        ggufSuggestions = []
        installError = nil
        refinerInstallStatus = nil
    }

    /// The role a classification leaves no real choice about, or the default the radio shows for
    /// `.both` -- a control has to display SOMETHING selected, and Louis can still change it before
    /// pressing Install. `.notRunnable` alone has nothing to default to.
    private static func preselectedRole(for classification: HuggingFaceClassification) -> ModelRole? {
        switch classification {
        case .speechOnly: .speech
        case .refinerOnly: .refiner
        case .both: .speech
        case .notRunnable: nil
        }
    }

    /// The sheet's own way of changing the role radio -- resets the candidate selection along
    /// with it, since a candidate id from the speech list means nothing once the refiner list is
    /// showing.
    func selectRole(_ role: ModelRole) {
        guard role != selectedRole else { return }
        selectedRole = role
        selectedCandidateID = nil
    }

    private static func describe(_ failure: ModelInspector.Failure) -> String {
        switch failure {
        case .notReachable(let detail): "Could not reach Hugging Face: \(detail)"
        case .notFound: "That repository does not exist on Hugging Face, or is private."
        }
    }

    /// Whether the Install button in the sheet may be pressed: a role is chosen, a candidate is
    /// chosen when the role's family offers more than one shape of "as is", and nothing is already
    /// installing.
    var canInstallSelection: Bool {
        guard let role = selectedRole, installingVariant == nil, !isInstallingRefiner else { return false }
        switch inspection {
        case .huggingFace(_, let classification):
            switch role {
            case .speech: return selectedCandidateID != nil
            case .refiner: return refinerCandidate(selectedCandidateID, in: classification) != nil
            }
        case .ollamaName:
            return role == .refiner
        case .failure, .none:
            return false
        }
    }

    /// The one Install button in the sheet, dispatching on whichever role and candidate are
    /// currently selected.
    func installSelection() async {
        guard let role = selectedRole else { return }
        switch inspection {
        case .huggingFace(let repository, let classification):
            switch role {
            case .speech:
                guard let variant = selectedCandidateID else { return }
                let bytes = speechCandidate(variant, in: classification)?.bytes
                await installSpeech(repository: repository, variant: variant, expectedBytes: bytes ?? 0)
            case .refiner:
                guard let candidate = refinerCandidate(selectedCandidateID, in: classification) else { return }
                await pullRefiner(name: OllamaModelName.huggingFace(repository: repository, tag: candidate.tag))
            }
        case .ollamaName(let name):
            await pullRefiner(name: name)
        case .failure, .none:
            return
        }
    }

    private func refinerCandidate(
        _ filename: String?, in classification: HuggingFaceClassification
    ) -> RefinerCandidate? {
        guard let filename else { return nil }
        let candidates: [RefinerCandidate]
        switch classification {
        case .refinerOnly(let refiner): candidates = refiner
        case .both(_, let refiner): candidates = refiner
        case .speechOnly, .notRunnable: candidates = []
        }
        return candidates.first { $0.filename == filename }
    }

    /// The `SpeechCandidate` `selectedCandidateID` names, so `installSelection()` can hand its own
    /// measured size to `installSpeech` instead of an unconditional `0` -- `ModelClassifier` already
    /// measured it (`totalSize(under:in:)`) whenever the blob listing reported a size for every
    /// file in the variant's folder, and a real number here is what lets the sheet's progress bar
    /// show an actual percentage instead of one permanently stuck at the guard in
    /// `ModelDownload.observe` (`expectedBytes > 0`).
    private func speechCandidate(
        _ variant: String?, in classification: HuggingFaceClassification
    ) -> SpeechCandidate? {
        guard let variant else { return nil }
        let candidates: [SpeechCandidate]
        switch classification {
        case .speechOnly(let speech): candidates = speech
        case .both(let speech, _): candidates = speech
        case .refinerOnly, .notRunnable: candidates = []
        }
        return candidates.first { $0.variant == variant }
    }

    /// Downloads `variant` from `repository` into Murmure's own store -- the speech half of
    /// `installSelection()`.
    ///
    /// `expectedBytes` is `0` exactly when `speechCandidate(_:in:)` found no measured size (the
    /// blob listing was missing a size for at least one file under the variant's folder) -- the
    /// same "nothing was measured, so nothing is claimed" rule `ModelRow.size` and
    /// `ModelClassifier.totalSize(under:in:)` already follow. It still feeds `ModelRow.size` and a
    /// delete confirmation's byte count once the model is installed; the sheet itself has no use
    /// for it while downloading -- see the footer's own comment on why that stays an indeterminate
    /// spinner.
    private func installSpeech(repository: String, variant: String, expectedBytes: Int64) async {
        installingVariant = variant
        installError = nil
        let descriptor = SpeechModelDescriptor(
            repository: repository, variant: variant, expectedBytes: expectedBytes)
        do {
            _ = try await WhisperKitEngine.installSpeechModel(descriptor) { _ in }
            installingVariant = nil
            dismissInspection()
        } catch {
            installingVariant = nil
            installError = error.localizedDescription
        }
        await reload()
    }

    /// The endpoint an ad-hoc pull or delete from the Inspect sheet targets when nothing more
    /// specific is known -- Ollama's own loopback default, the one every shipped mode already
    /// points at (`Mode.LLM.endpoint`'s own default).
    private static let localOllama = URL(string: "http://localhost:11434")!

    /// Pulls `name` on the local Ollama -- the refiner half of `installSelection()`, and also what
    /// an Ollama-name input pulls as is.
    private func pullRefiner(name: String) async {
        guard !isInstallingRefiner else { return }
        isInstallingRefiner = true
        refinerInstallStatus = "Starting -- pulling manifest"
        let outcome = await puller.pull(model: name, endpoint: Self.localOllama) { [weak self] line in
            Task { @MainActor in self?.refinerInstallStatus = Self.describe(line) }
        }
        isInstallingRefiner = false
        switch outcome {
        case .succeeded:
            refinerInstallStatus = nil
            dismissInspection()
            await checkOllama()
        case .failed(let failure):
            refinerInstallStatus = failure.remedy
        case .progress:
            break
        }
    }

    // MARK: - Deleting

    /// Computes what deleting `row` would do and asks before doing it -- the view reads
    /// `pendingRemoval` to drive its confirmation `.alert`.
    func requestDeletion(of row: ModelRow) {
        switch row.kind {
        case .speech:
            guard let reference = SpeechModelReference(parsing: row.identifier) else { return }
            let namedByModes = ModelInventory.modesNaming(
                reference: reference, in: modes(), engineDefault: .shippedDefault)
            let removal = ModelInventory.removal(
                for: reference, in: store, expectedBytes: row.expectedBytes, namedByModes: namedByModes)
            pendingRemoval = (row, removal)
        case .language:
            let namedByModes = ModelInventory.modesNaming(languageModel: row.identifier, in: modes())
            let removal = ModelInventory.removal(forLanguageModel: row.identifier, namedByModes: namedByModes)
            pendingRemoval = (row, removal)
        }
    }

    func cancelDeletion() {
        pendingRemoval = nil
    }

    /// Actually removes what `requestDeletion` computed -- never called except from the
    /// confirmation `.alert`'s destructive button.
    ///
    /// Speech removes the two directories `ModelRemoval.directories` names (the variant and its
    /// `.cache` sidecars); language asks Ollama's own `DELETE /api/delete` -- this app never
    /// writes to Ollama's store directly. A failure leaves the row exactly as it was, and
    /// `reload()` reports that honestly -- but the failure ALSO reaches `installError`, published
    /// rather than only logged: Louis pressed a destructive button and is owed the reason it did
    /// not happen, the same reasoning `installSpeech`'s own catch already acts on.
    func confirmDeletion() async {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        installError = nil
        switch pending.row.kind {
        case .speech:
            // `fileExists` first, not a caught "no such file": a directory this removal never
            // wrote to begin with (a variant installed with no `.cache` sidecar) is not a failure
            // to report, and treating it as one would raise an alarm over nothing every time.
            var failures: [String] = []
            for directory in pending.removal.directories
            where FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if !failures.isEmpty {
                installError = "Could not delete \(pending.row.name): \(failures.joined(separator: "; "))"
            }
        case .language:
            // The endpoint a mode naming this model points at, when one does -- the same limited
            // lookup `pull(modelIdentifier:)` already accepts (`reference(forRowIdentifier:)`'s
            // own doc comment): a model on two endpoints only ever resolves to the first. Falls
            // back to the local default for a row nothing names, which is the only endpoint this
            // pane's own automatic listing ever reads from.
            let endpoint = reference(forRowIdentifier: pending.row.identifier)
                .flatMap { URL(string: $0.endpoint) } ?? Self.localOllama
            let outcome = await deleter.delete(model: pending.row.identifier, endpoint: endpoint)
            if case .failed(let failure) = outcome {
                log.info("delete of \(pending.row.identifier, privacy: .public) failed -- \(failure.description, privacy: .public)")
                installError = failure.remedy
            }
        }
        await reload()
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
