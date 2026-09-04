import Foundation

/// Which of the two families a model belongs to.
///
/// **Data, not a glyph.** Design notes §1.1 makes the `Type` column a mark rather than a word —
/// a waveform for a speech model, stacked lines for a language one — and the mark is the view's
/// business. What is decided here is which of the two a row *is*, because that is the thing a
/// test can hold: `MurmureCore` has no SwiftUI in it, the same seam `WindowPalette` already
/// works across.
public enum ModelKind: Equatable, Sendable {
    /// Whisper, on this disk, under Murmure's own model store.
    case speech
    /// An Ollama model, in Ollama's store, which Murmure never writes to.
    case language
}

/// What the single action column offers on a row.
///
/// Design notes §1.1: one column doing several jobs is the compression trick worth stealing —
/// a download button when the model is missing, a delete button when it is there. `pull` and
/// `managedElsewhere` are Murmure's own: an Ollama model is not in Murmure's store, and
/// `ollama pull` / `ollama rm` are the only two things that move it. `pull` is Murmure ASKING
/// Ollama to run the first of those two; `managedElsewhere` is every state where even that is not
/// offered -- neither ever offers a `delete`, which would be a button that lies about who owns the
/// file. The remedy travels as a sentence instead (``ModelRow/detail``).
public enum ModelAction: Equatable, Sendable {
    case download
    case delete
    /// Ollama does not have this model yet, and the one thing Murmure may do about it is ask
    /// Ollama to fetch it -- never write to Ollama's store directly, which is what every other
    /// language state still offers no button for. See ``ModelRow/action`` for the one state this
    /// applies to.
    case pull
    /// Nothing to press: another program owns this file.
    case managedElsewhere
}

/// Whether a model is on this machine, and how much of it.
public enum ModelInstallation: Equatable, Sendable {
    /// Complete and usable. `bytes` is what deleting it would free — 0 when the source of the
    /// answer does not report a size, which is why the size column can still be blank on an
    /// installed row.
    case installed(bytes: Int64)

    /// Files exist and the download did not finish. **The case this whole file is written
    /// around**: `WhisperKitEngine` sends a folder in this state back to the Hub, so a table
    /// that called it installed would offer a delete button for something the app is about to
    /// re-download, and would say "installed" about a model that cannot transcribe a word.
    case partiallyDownloaded(bytes: Int64, expected: Int64)

    /// Nothing on disk.
    case absent

    /// The question could not be answered, with the sentence saying why. Only a language model
    /// reaches this: a directory listing either finds files or does not, while a probe of another
    /// process can fail without telling us anything about the model.
    case undetermined(reason: String)
}

/// One line of the Models table, fully decided.
///
/// Every column is a property here rather than an expression in the view, for the structural
/// reason this package exists: the app target has no test bundle, so a rule written in a
/// `Text(...)` is a rule nothing can check.
public struct ModelRow: Equatable, Sendable, Identifiable {
    /// The identifier as it is configured and stored — the WhisperKit variant folder, or the
    /// Ollama model id. Kept whole because it is what a `ollama pull` command has to be spelled
    /// with, and because it is the row's identity.
    public let identifier: String
    public let kind: ModelKind
    public let installation: ModelInstallation
    /// What a complete copy weighs, when it is known in advance. `nil` for a language model:
    /// nothing tells us what an unpulled Ollama model would weigh without asking a registry.
    public let expectedBytes: Int64?

    /// A second sentence, independent of ``detail``, for an installed speech model that has not
    /// been proven fast on THIS Mac -- see ``ModelInventory/speechRow(for:in:fileManager:knownWarm:)``
    /// for who sets it and why it cannot be computed from ``installation`` alone. `nil` covers both
    /// "nothing to say" and "not applicable", the same way ``detail`` does for every other row.
    public let firstUseNotice: String?

    public var id: String { identifier }

    public init(
        identifier: String, kind: ModelKind, installation: ModelInstallation,
        expectedBytes: Int64? = nil, firstUseNotice: String? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.installation = installation
        self.expectedBytes = expectedBytes
        self.firstUseNotice = firstUseNotice
    }

    /// The name column. ``ModelDisplayName/readable(_:)`` and not a second rule: Louis asked for
    /// the model and not the path it was pulled from, and that question has one answer in this
    /// package.
    public var name: String { ModelDisplayName.readable(identifier) }

    /// The action column.
    ///
    /// Written as one `switch` over the pair, without a `default`, so a family or a state added
    /// later does not build until someone has said what its button does.
    public var action: ModelAction {
        switch (kind, installation) {
        // Murmure downloaded it into its own store, so Murmure can remove it.
        case (.speech, .installed): .delete
        // A half-downloaded model offers the download that finishes it, never the delete that
        // would look like the fix. The Hub resumes from the `.incomplete` file it left behind.
        case (.speech, .partiallyDownloaded): .download
        case (.speech, .absent): .download
        // A store that could not be read is not a store that is empty: offering a download would
        // be acting on an answer we do not have.
        case (.speech, .undetermined): .managedElsewhere
        // The one language state Murmure may act on: Ollama has answered and does not have this
        // model, so the only thing worth pressing is a pull -- never a delete, which stays
        // unreachable for every other language state below.
        case (.language, .absent): .pull
        case (.language, .installed), (.language, .partiallyDownloaded), (.language, .undetermined):
            .managedElsewhere
        }
    }

    /// The size column, or `nil` when there is no number worth printing.
    ///
    /// An absent speech model shows what the download will cost — design notes §1.1 puts the
    /// download size in this column precisely so the decision to press ⬇ is an informed one.
    public var size: String? {
        switch installation {
        case .installed(let bytes): bytes > 0 ? ModelSize.readable(bytes) : nil
        case .partiallyDownloaded(_, let expected): ModelSize.readable(expected)
        case .absent: expectedBytes.map(ModelSize.readable)
        case .undetermined: nil
        }
    }

    /// The second line of the row: what is wrong, or what a press would do. `nil` on a row with
    /// nothing to add, which is the common case — an installed model needs no sentence.
    public var detail: String? {
        switch installation {
        case .installed: nil
        case .partiallyDownloaded(let bytes, let expected):
            "Incomplete -- \(ModelSize.readable(bytes)) of \(ModelSize.readable(expected)) on disk."
        case .absent:
            switch kind {
            case .speech: "Not downloaded."
            // A language model that is absent is a model Ollama answered about and does not
            // have, so the sentence is lot 2's own remedy, derived from the identifier rather
            // than restated here. This is what keeps "Ollama isn't running" and "the model isn't
            // pulled" two different sentences without a second vocabulary (T8).
            case .language: OllamaFailure.modelNotPulled(model: identifier).remedy
            }
        case .undetermined(let reason): reason
        }
    }
}

/// A speech model as the machine can find it: which repository, which variant inside it, and what
/// a complete copy weighs.
///
/// The variant string is **not** defaulted here on purpose. `WhisperKitEngine.dictationModel` is
/// the single definition of which variant this app runs, and a copy of it in this package would
/// be a second definition that compiles perfectly while describing a model the app never
/// downloads. The caller passes the engine's own constant.
public struct SpeechModelDescriptor: Equatable, Sendable {
    /// The Hugging Face repository id, e.g. `argmaxinc/whisperkit-coreml`.
    public let repository: String
    /// The folder inside it, e.g. `openai_whisper-large-v3-v20240930_turbo`.
    public let variant: String
    /// What the whole repository weighs once the download is complete. See
    /// ``ModelDownload/transcriptionModelBytes`` for how that number was measured, and for the
    /// two ways it is allowed to drift.
    public let expectedBytes: Int64

    public init(repository: String, variant: String, expectedBytes: Int64) {
        self.repository = repository
        self.variant = variant
        self.expectedBytes = expectedBytes
    }
}

/// What a delete would actually remove, and the question to ask before it does.
public struct ModelRemoval: Equatable, Sendable {
    /// Every directory that has to go. **Not the repository root**: a store that held a second
    /// variant would lose it too, and the row the user pressed named one model.
    public let directories: [URL]
    /// What the confirmation says it will destroy. It names the size, because the cost of being
    /// wrong is re-downloading it.
    public let question: String
}

/// The Models table's speech half, read off a directory listing.
///
/// The root is **injected**, never resolved here, for the reason `Storage` gives at the top of
/// its own file: a function that resolved `Application Support` itself could only ever be
/// exercised against Louis's real 1.5 GB of models, and a test that walks a tree it did not build
/// proves nothing about the tree it will meet on another Mac.
public enum ModelInventory {
    // MARK: - Where things are

    /// The three CoreML bundles a WhisperKit model cannot load without.
    ///
    /// The requirement comes from `loadModels` (`WhisperKit.swift:376-385`), and
    /// `WhisperKitEngine.cachedModelFolder` reads **this** constant before it dares skip the Hub.
    ///
    /// **One list, in one module, consumed by both** — which is the point, and which it was not
    /// in the first version of this file: a copy of these three strings in the app target and a
    /// copy here are two literals nothing can hold in agreement, so a variant whose bundle names
    /// changed could be updated in the engine alone and leave this table saying "installed" about
    /// a folder the engine hands straight back to the Hub on the next dictation. Public for that
    /// reason and no other: the agreement is now held by the compiler rather than by a comment
    /// claiming it is.
    public static let requiredBundles = [
        "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
    ]

    /// The repository folder under a model store.
    ///
    /// The extra `models/` level is not a mistake in the path: `HubApi.localRepoLocation` is
    /// `downloadBase / <repo type> / <repo id>` and the type of a model repository is spelled
    /// `models`, so a store at `Application Support/Murmure/models` really does hold
    /// `models/argmaxinc/whisperkit-coreml`. Verified against the installed tree.
    ///
    /// Appended one component at a time because a repository id contains a slash, and
    /// `appendingPathComponent` is documented to add *one* component.
    public static func repository(for descriptor: SpeechModelDescriptor, in store: URL) -> URL {
        var url = store.appendingPathComponent("models", isDirectory: true)
        for component in descriptor.repository.split(separator: "/") {
            url = url.appendingPathComponent(String(component), isDirectory: true)
        }
        return url
    }

    /// The variant folder: the model itself.
    public static func variant(for descriptor: SpeechModelDescriptor, in store: URL) -> URL {
        repository(for: descriptor, in: store)
            .appendingPathComponent(descriptor.variant, isDirectory: true)
    }

    /// Where the Hub keeps this variant's bookkeeping: one `.metadata` sidecar per downloaded
    /// file, and the `.<etag>.incomplete` file of whatever is being transferred right now
    /// (`HubApi.snapshot`, which builds `<repo>/.cache/huggingface/download/`).
    public static func cache(for descriptor: SpeechModelDescriptor, in store: URL) -> URL {
        repository(for: descriptor, in: store)
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(descriptor.variant, isDirectory: true)
    }

    // MARK: - The row

    /// One speech model's row, from what is on the disk right now.
    ///
    /// **What makes a model installed, and why it is these two conditions.**
    ///
    /// 1. *No `.incomplete` file anywhere in the variant's cache subtree.* The Hub creates that
    ///    file — empty — **before the first byte** (`HubApi.prepareCacheDestination`) and *moves*
    ///    it onto its destination when the transfer finishes (`Downloader:211`). So its presence
    ///    is the download itself saying it is not done, and its absence is the only signal on
    ///    disk that no transfer was interrupted. This is the condition that catches the case the
    ///    plan names: a download killed while fetching `AudioEncoder.mlmodelc/weights/weight.bin`
    ///    leaves the *folder* `AudioEncoder.mlmodelc` in place, holding its two small sidecar
    ///    files, with 1.2 GB of the 1.6 missing. Every folder-existence check on earth calls that
    ///    installed. The `.incomplete` file does not.
    /// 2. *The three `.mlmodelc` bundles of ``requiredBundles`` all exist.* This is the
    ///    engine's own precondition, restated so the two cannot disagree, and it covers the
    ///    interruption that left no `.incomplete` behind — a process killed between two files.
    ///
    /// **What was considered and rejected as the criterion.** Comparing bytes on disk against
    /// ``SpeechModelDescriptor/expectedBytes`` looks like the obvious test and is the wrong one:
    /// that constant is measured, not fetched, and `ModelDownload` already records that it drifts
    /// whenever Argmax re-uploads the variant. A drifted constant would make a *complete* model
    /// read as partial forever, with a download button that never turns into a delete. Bytes are
    /// good enough to show a progress sentence, and not good enough to decide a state.
    ///
    /// A variant folder with no files in it and no transfer in flight is `absent`, not partial:
    /// an empty directory is a leftover, there is nothing to resume and nothing to free.
    /// `knownWarm` is the caller's answer to a question this function cannot ask the disk: has
    /// THIS Mac's Neural Engine already compiled this variant. See
    /// ``firstUseNotice(installation:knownWarm:)`` for why that has to travel in rather than be
    /// derived here.
    public static func speechRow(
        for descriptor: SpeechModelDescriptor,
        in store: URL,
        fileManager: FileManager = .default,
        knownWarm: Bool = false
    ) -> ModelRow {
        let variantURL = variant(for: descriptor, in: store)
        let cacheURL = cache(for: descriptor, in: store)
        let interrupted = hasIncompleteFile(under: cacheURL, fileManager: fileManager)
        let bytes = bytesOnDisk(in: variantURL, fileManager: fileManager)
            + bytesOnDisk(in: cacheURL, fileManager: fileManager)

        let installation: ModelInstallation
        if bytes == 0 && !interrupted {
            installation = .absent
        } else if interrupted || !hasRequiredBundles(in: variantURL, fileManager: fileManager) {
            installation = .partiallyDownloaded(bytes: bytes, expected: descriptor.expectedBytes)
        } else {
            installation = .installed(bytes: bytes)
        }

        return ModelRow(
            identifier: descriptor.variant, kind: .speech, installation: installation,
            expectedBytes: descriptor.expectedBytes,
            firstUseNotice: firstUseNotice(installation: installation, knownWarm: knownWarm))
    }

    /// The sentence an installed speech model carries about the machine-specific compile it has
    /// not been proven to have already paid -- or `nil` when it is not installed, or when the
    /// caller already knows it is warm.
    ///
    /// **Why `knownWarm` is a parameter and not a computation.** Nothing under `store` says
    /// whether this Mac's Neural Engine has already compiled a given variant: that cache is
    /// `ANECompilerService`'s own, outside `Application Support/Murmure` and outside anything a
    /// directory listing can read (`WhisperKitEngine.prepare()`'s own doc comment measures the
    /// cost, not where the receipt is kept). The one variant this can be said about with any
    /// confidence at all is the shipped default: `scripts/bootstrap.sh` runs `ModelWarmup` -- which
    /// calls exactly that `prepare()` -- as the last thing it does, before Murmure is ever used.
    /// Every other variant a caller names here has no such guarantee, however long it has sat on
    /// disk, so the caller has to say which one it is rather than this function guessing from the
    /// identifier.
    static func firstUseNotice(installation: ModelInstallation, knownWarm: Bool) -> String? {
        guard case .installed = installation, !knownWarm else { return nil }
        return """
            First dictation with this model will take several minutes while this Mac compiles it \
            for its Neural Engine; every one after that takes a few seconds.
            """
    }

    /// The two directories a delete has to remove, and the question that precedes it.
    ///
    /// Two and not one: the model is in the variant folder, and its `.metadata` sidecars are in
    /// the cache subtree beside it. Removing only the first leaves the Hub believing every file
    /// is present with a matching commit hash, which is how a "deleted" model comes back as a
    /// store that will not re-download and will not load either.
    /// `namedByModes` is which modes' `stt.model` resolves to this variant (``modesNaming``),
    /// empty when none do. It changes the question asked and not merely a footnote to it: deleting
    /// a model nobody names costs a re-download; deleting one a mode still names leaves that mode
    /// falling back to Murmure's shipped default at the next dictation with nothing on screen
    /// saying so -- the difference `WhisperKitEngine.load`'s own fallback is silent about. A
    /// confirmation that did not say which of the two this delete is would let Louis press it not
    /// knowing a mode goes with it.
    public static func removal(
        for descriptor: SpeechModelDescriptor, in store: URL, namedByModes modeNames: [String] = []
    ) -> ModelRemoval {
        let name = ModelDisplayName.readable(descriptor.variant)
        let size = ModelSize.readable(descriptor.expectedBytes)
        let question: String
        if modeNames.isEmpty {
            question = "Delete \(name)? Murmure will download \(size) again before the next dictation."
        } else {
            let modes = modeNames.joined(separator: ", ")
            let verb = modeNames.count == 1 ? "names" : "name"
            question = """
                Delete \(name)? \(modes) still \(verb) it -- without it, dictation there will \
                silently fall back to Murmure's default model until you point it at another one. \
                Murmure will download \(size) again if you reinstall it.
                """
        }
        return ModelRemoval(
            directories: [variant(for: descriptor, in: store), cache(for: descriptor, in: store)],
            question: question)
    }

    /// The names of the modes whose `stt.model` resolves to `variant`, in file order.
    ///
    /// Resolved through ``SpeechModelResolution`` rather than compared as raw strings: a mode's
    /// stored field is very often the shipped alias (`Mode.defaultSTTModel`) or blank, and neither
    /// is the exact folder name a row's `identifier` carries -- comparing them literally would
    /// never catch the common case, which is exactly the one the delete confirmation exists for.
    public static func modesNaming(variant: String, in modes: [Mode], engineDefault: String) -> [String] {
        modes.filter {
            SpeechModelResolution.variant(storedAs: $0.stt.model, engineDefault: engineDefault) == variant
        }.map(\.name)
    }

    /// The whole table, in the order it is drawn.
    ///
    /// Speech first: it is the model Murmure owns, the one it downloads, and the only row whose
    /// buttons do anything. Language models follow, sorted by their readable name so the order
    /// does not depend on which mode file happened to be read first.
    public static func table(speech: [ModelRow], language: [ModelRow]) -> [ModelRow] {
        speech + language.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Reading the disk

    /// Every byte under a folder, hidden files included, 0 when it cannot be walked.
    ///
    /// Hidden files included for the reason `WhisperKitEngine.bytesOnDisk` gives: the file
    /// currently growing is the `.incomplete` one, and it lives in a `.cache` folder — skipping
    /// hidden entries would make a download in flight measure as a series of whole-file jumps.
    static func bytesOnDisk(in folder: URL, fileManager: FileManager) -> Int64 {
        guard let files = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
        return total
    }

    private static func hasIncompleteFile(under cache: URL, fileManager: FileManager) -> Bool {
        guard let files = fileManager.enumerator(at: cache, includingPropertiesForKeys: nil)
        else { return false }
        for case let file as URL in files where file.pathExtension == "incomplete" {
            return true
        }
        return false
    }

    private static func hasRequiredBundles(in variant: URL, fileManager: FileManager) -> Bool {
        requiredBundles.allSatisfy {
            fileManager.fileExists(atPath: variant.appendingPathComponent($0).path)
        }
    }

    // MARK: - The language half

    /// The language models the modes actually use, deduplicated, in a stable order.
    ///
    /// **Only the modes whose refinement is on.** A mode with `llm.enabled == false` still names
    /// a model in its file — every built-in does — and listing those would fill the table with
    /// models Louis never runs, which is the opposite of what a table of what is installed is
    /// for.
    ///
    /// Deduplicated on the pair and not on the name: the same model served by two endpoints is
    /// two probes and can genuinely answer differently.
    public static func languageModels(in modes: [Mode]) -> [LanguageModelReference] {
        var seen: [LanguageModelReference] = []
        for mode in modes where mode.llm.enabled {
            let reference = LanguageModelReference(
                identifier: mode.llm.model, endpoint: mode.llm.endpoint)
            if !seen.contains(reference) { seen.append(reference) }
        }
        return seen.sorted {
            ModelDisplayName.readable($0.identifier)
                .localizedCaseInsensitiveCompare(ModelDisplayName.readable($1.identifier))
                == .orderedAscending
        }
    }
}

/// A language model to ask about: which model, on which server.
public struct LanguageModelReference: Equatable, Hashable, Sendable {
    public let identifier: String
    public let endpoint: String

    public init(identifier: String, endpoint: String) {
        self.identifier = identifier
        self.endpoint = endpoint
    }
}

/// A byte count as the table prints it.
///
/// **Base ten, like the Finder and like the README.** The model this app downloads is quoted as
/// 1.6 GB everywhere Louis has already read about it — the README's model table, the download
/// card, `ModelDownload`'s own note — and a pane that answered "1.53 GB" about the same file
/// would be reporting a different model. Powers of two are what a disk is made of; powers of ten
/// are what macOS says out loud.
///
/// Hand-rolled rather than `ByteCountFormatter` because the formatter is locale-dependent in both
/// its separator and its unit spelling, and a test that pins the string it produces would pass on
/// this Mac and fail on another. `String(format:)` with no locale argument is the POSIX one.
public enum ModelSize {
    public static func readable(_ bytes: Int64) -> String {
        let value = Double(bytes)
        switch bytes {
        case ..<1_000: return "\(bytes) B"
        case ..<1_000_000: return String(format: "%.0f kB", value / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB", value / 1_000_000)
        default: return String(format: "%.1f GB", value / 1_000_000_000)
        }
    }
}
