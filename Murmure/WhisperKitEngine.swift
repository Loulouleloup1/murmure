import Foundation
import MurmureCore
import os
import WhisperKit

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "transcription")

/// WhisperKit-backed speech-to-text. Downloads large-v3-turbo into
/// `Application Support/Murmure/models` on first use and keeps it loaded afterwards.
///
/// An `actor` rather than the `final class` the brief sketched: the model is a mutable stored
/// property written from an `async` function, so two overlapping dictations would each observe
/// "not loaded yet" and each start a 1.6 GB download plus a multi-gigabyte CoreML load. Actor
/// isolation alone does NOT fix that -- an actor is re-entrant, so it releases the executor at
/// every `await` inside the load -- which is why the load is stored as a `Task` that later
/// callers await instead of a plain `WhisperKit?`. Isolation is what makes storing that task
/// safe; the task is what makes the load happen once.
///
/// Concurrent `transcribe` calls on one loaded model are left unserialised on purpose:
/// WhisperKit itself fans a single transcription out over `concurrentWorkerCount` (16 on macOS)
/// workers sharing one instance, so serialising here would add nothing.
actor WhisperKitEngine {
    enum Failure: LocalizedError {
        case modelDownloadFailed(Error)
        case modelDownloadStalled(TimeInterval)
        case modelLoadFailed(Error)
        case transcriptionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .modelDownloadFailed(let error):
                """
                Could not download the transcription model. Check your internet connection \
                and try again. (\(error.localizedDescription))
                """
            case .modelDownloadStalled(let idle):
                """
                The transcription model download stopped making progress for \
                \(Int(idle)) s. Check your internet connection and try again.
                """
            case .modelLoadFailed(let error):
                "Could not load the transcription model: \(error.localizedDescription)"
            case .transcriptionFailed(let error):
                "Could not transcribe the recording: \(error.localizedDescription)"
            }
        }
    }

    /// Folder name in `argmaxinc/whisperkit-coreml`, verified against the repo file listing and
    /// against the `config.json` support list for this machine (Mac16,7 / M4 Pro).
    ///
    /// `large-v3-v20240930` IS large-v3-turbo, OpenAI's 2024-09-30 release; the `_turbo` suffix
    /// is WhisperKit's own compute variant on top of it. Getting this string wrong fails at
    /// download time with a confusing "model not found", so it is verified, not remembered.
    static let dictationModel = "openai_whisper-large-v3-v20240930_turbo"

    /// The Hugging Face repository the variant above lives in. Same default WhisperKit uses; it
    /// is spelled out here because the cached-folder check below has to resolve the exact same
    /// local path WhisperKit would have downloaded into.
    ///
    /// Not private, so the Models pane describes THIS repository rather than a second copy of the
    /// string: a table that named a repository the engine does not download from would be a table
    /// about a model nobody has.
    static let modelRepo = "argmaxinc/whisperkit-coreml"

    private var loading: Task<LoadedModel, Error>?

    /// Where "how far into the audio has the decoder got" is left for the interface to pull.
    ///
    /// No default, for the reason `DictationRefining` has none: a box nobody passed would compile
    /// at every call site, report nothing forever, and fail no test. `DictationController` owns
    /// the one box and hands it to whoever draws it, the way it already does with `AudioLevels`.
    private let progress: DecodeProgressBox

    /// Where the model's own preparation is announced, and nil when there is none in flight.
    ///
    /// **The seam the shipped comment on `load()` promised and never got.** The download has had a
    /// progress callback since lot 1 and it went to `os_log`; the interface said "Transcribing"
    /// for the whole 1.6 GB, and on a second Mac that is indistinguishable from a hang.
    ///
    /// It is `@MainActor` and **awaited** rather than a plain `@Sendable` closure hopping onto the
    /// main actor with an unstructured `Task`. Two such tasks have no ordering guarantee between
    /// them, and the one thing this value must never do is go backwards -- so the ordering is made
    /// structural instead of hoped for: awaiting the hop means this actor cannot issue report *n+1*
    /// until report *n* has run. It suspends rather than blocks, so a main actor busy drawing the
    /// card cannot deadlock the download waiting on it.
    ///
    /// No default, for the reason the box above has none: a reporter nobody passed would compile at
    /// every call site and reproduce exactly the defect this parameter exists to remove.
    private let report: @MainActor @Sendable (ModelPreparation?) -> Void

    init(
        progress: DecodeProgressBox,
        reportingPreparation report: @escaping @MainActor @Sendable (ModelPreparation?) -> Void
    ) {
        self.progress = progress
        self.report = report
    }

    /// Transcribes a WAV file. The first call also downloads and loads the model.
    ///
    /// The recording keeps the capture hardware's format; WhisperKit resamples to 16 kHz mono
    /// when it loads the file (`AudioProcessor.loadAudio` converts anything that is not already
    /// 16 kHz mono), so no conversion happens on the recording side.
    ///
    /// Returns the empty string when the audio held no speech, and does so WITHOUT running the
    /// model: `SpeechGate` measures the recording first and rejects near-silence. Whisper answers
    /// near-silence with a fabricated sentence often enough -- and non-deterministically enough,
    /// the same file returning `¿Qué es lo que se llama?`, then nothing, then `¿Qué es la vida?`
    /// -- that no check on its *output* can be trusted; the fabricated text would be pasted into
    /// whatever Louis is typing into. The empty-text normalisation below is kept as well: it
    /// still covers the runs where a recording with speech in it decodes to nothing.
    ///
    /// A recording that DOES hold speech has its long silences cut out before the model sees
    /// them, for the same reason: the accept/reject verdict is a whole-file decision, and 660 s
    /// of silence followed by 3.1 s of speech passes it while making the model fabricate a
    /// `"Thank you."` for each of the 22 silent windows in between. See
    /// `SpeechGate.framesWorthDecoding`.
    ///
    /// **`language` is never left to detection.** Whisper's language token has to be decided
    /// before the first text token: WhisperKit's default `DecodingOptions()` leaves `language` nil
    /// AND `detectLanguage` false (it is derived as `!usePrefillPrompt`), and the decoder then
    /// prefills `<|en|>` -- French audio would be decoded as English and come back as
    /// plausible-looking garbage with no error raised anywhere.
    ///
    /// Every real mode today still resolves to `"fr"` (`Mode.defaultLanguage`), and that default
    /// is measured, not assumed: across the whole real corpus (1 449 dictations, 17.1 h),
    /// `detectLanguage: true` re-evaluates the language PER WINDOW and again on every temperature
    /// fallback, so a single dictation can switch mid-way. It produced 9 non-Latin transcripts out
    /// of 1 449 plus Spanish switches that no count catches, and those outputs are every one of
    /// the cases where Superwhisper beat us in the head-to-head arbitration. Pinning removed
    /// 100 % of them (11/11, over 3 runs x 100 files), improved the median WER slightly, and
    /// halved run-to-run instability. Louis dictates French with occasional English technical
    /// terms, never full English -- the ~2 % measured as "English" IS the misdetection, not a
    /// population to protect, and Whisper keeps English technical terms verbatim inside a
    /// French-decoded transcript regardless.
    ///
    /// So `language` arrives as a parameter rather than as `"auto"` or a compiled-in constant: it
    /// is `activeMode.stt.language`, the per-mode seam this comment used to say lot 2 owed. A
    /// future mode that sets `"language": "en"` gets what it asked for instead of a re-run of the
    /// measurement above.
    ///
    /// `initialPrompt`, when not nil, is `VocabularyPrompt.build(from:)`'s output verbatim -- this
    /// method does not interpret it, per this file's own rule that it translates and does not
    /// decide.
    func transcribe(wav: URL, language: String, initialPrompt: String?) async throws -> String {
        // Here rather than beside the WhisperKit call: everything between the two -- reading the
        // file, measuring it for silence, and on the first dictation of a session loading the
        // model, 112 s measured cold -- happens while the interface is already showing
        // `.transcribing`. Without this the bar would spend all of it showing the previous
        // dictation's full one.
        progress.begin()

        let samples: [Float]
        do {
            samples = try Self.samples(of: wav)
        } catch {
            logger.error("""
                could not read \(wav.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            throw Failure.transcriptionFailed(error)
        }

        let voiced = Self.voicedFrames(in: samples)

        if case .silence(let reason) = SpeechGate.verdict(
            voicedSeconds: Double(voiced.filter { $0 }.count) * Double(SpeechGate.frameLength),
            totalSeconds: Double(samples.count) / Double(WhisperKit.sampleRate)
        ) {
            // Deliberately not an error: an empty recording is "you said nothing", which the
            // pipeline already handles as a no-op. No banner, no paste, nothing to dismiss.
            logger.info("""
                no speech in \(wav.lastPathComponent, privacy: .public) -- \
                \(reason, privacy: .public); not transcribed
                """)
            return ""
        }

        let audio = Self.audioWorthDecoding(samples: samples, voiced: voiced)
        if audio.count < samples.count {
            let removed = Double(samples.count - audio.count) / Double(WhisperKit.sampleRate)
            logger.info("""
                skipped \(removed, format: .fixed(precision: 1), privacy: .public)s of silence in \
                \(wav.lastPathComponent, privacy: .public)
                """)
        }

        let model = try await loadedKit()

        let results: [TranscriptionResult]
        do {
            results = try await model.transcribe(
                audio: audio, language: language, initialPrompt: initialPrompt, reporting: progress)
        } catch {
            logger.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.transcriptionFailed(error)
        }

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            logger.warning("no text from \(wav.lastPathComponent, privacy: .public)")
        }
        return text
    }

    /// Downloads and loads the model, transcribing nothing.
    ///
    /// **The one thing a script needs and `transcribe` cannot give it.** The wait a fresh Mac pays
    /// on its first dictation is not transcription: `sample` on the process showed the thread
    /// parked in `MLE5ProgramLibrary.prepareAndReturnError` for 2046 samples out of 2046, with
    /// `ANECompilerService` at 100 % CPU -- CoreML compiling the four `.mlmodelc` bundles for this
    /// machine's neural engine. 423 s measured on an 8-core Mac, 440 s documented by Argmax on an
    /// M4 Pro (WhisperKit#309), 3-5 s on every load afterwards. `ab090d5` made that wait legible;
    /// it did not move it, and at the first dictation somebody is waiting for a sentence rather
    /// than for an install.
    ///
    /// So `scripts/bootstrap.sh` calls it, through `ModelWarmup`, as the last thing it does.
    ///
    /// **It is `loadedKit()` and nothing else, which is the whole of why this method exists rather
    /// than a second binary that also links WhisperKit.** The compiled artefact CoreML caches is
    /// keyed on the configuration it compiled, so a warm-up that opened another variant, another
    /// `downloadBase` or another `WhisperKit.init` would warm nothing and would report that it
    /// had -- a wait that looks paid and still happens, which is worse than one that does not
    /// pretend. Every argument here is `transcribe`'s because it is literally the same call.
    func prepare() async throws {
        _ = try await loadedKit()
    }

    /// Which 100 ms frames of the recording carry sound, as `SpeechGate`'s thresholds were
    /// calibrated to measure it.
    ///
    /// The measurement lives here and the decisions live in `MurmureCore`: `EnergyVAD` is a
    /// WhisperKit type and the app target is the only one that links WhisperKit, while the
    /// thresholds need nothing but numbers and so can have regression tests. Those thresholds
    /// are what stands between a fabricated sentence and whatever Louis is typing into, and
    /// until that split they had none.
    ///
    /// The frame length is part of the calibrated rule rather than a local choice: `EnergyVAD`
    /// counts a frame as voiced when its RMS is above the threshold, so voiced time is a frame
    /// count times this length, and measuring at another resolution measures something else.
    private static func voicedFrames(in samples: [Float]) -> [Bool] {
        EnergyVAD(
            sampleRate: WhisperKit.sampleRate,
            frameLength: SpeechGate.frameLength,
            energyThreshold: SpeechGate.energyThreshold
        ).voiceActivity(in: samples)
    }

    /// The recording with long silences cut out, ready for the model.
    ///
    /// `SpeechGate.framesWorthDecoding` decides which frames survive and why; this only maps its
    /// frame ranges back onto samples, using `EnergyVAD`'s own frame-length arithmetic
    /// (`Int(frameLength * sampleRate)`, `EnergyVAD.swift:24`) so the two cannot drift apart.
    /// The final frame of a recording is short when the length does not divide evenly, hence the
    /// clamp to the sample count.
    private static func audioWorthDecoding(samples: [Float], voiced: [Bool]) -> [Float] {
        let frameSamples = Int(SpeechGate.frameLength * Float(WhisperKit.sampleRate))
        return SpeechGate.framesWorthDecoding(voiced: voiced).flatMap { frames -> ArraySlice<Float> in
            let start = min(frames.lowerBound * frameSamples, samples.count)
            let end = min(frames.upperBound * frameSamples, samples.count)
            return samples[start..<end]
        }
    }

    /// The recording as the model will hear it: 16 kHz mono float samples.
    ///
    /// This is the loader `transcribe(audioPath:)` uses itself (`WhisperKit.swift:933`), and the
    /// audio-path entry point does nothing afterwards but hand the array to
    /// `transcribe(audioArray:)` (`:941`). So calling that entry point directly is a
    /// silence-removal change and nothing else -- verified on 21 real files, which come back
    /// byte-identical. It also decodes the file once instead of twice, which the previous round
    /// paid for.
    private static func samples(of wav: URL) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: wav.path)
    }

    /// The loaded model, loading it exactly once.
    ///
    /// Creating the task and storing it happen with no `await` between them, so no second caller
    /// can observe `loading == nil` while a load is in flight. A failed load clears the task so
    /// the next dictation retries: a dropped Wi-Fi connection must not disable transcription for
    /// the lifetime of the process. Clearing unconditionally is safe -- a new task can only be
    /// created by a caller that found `loading` nil, and this is the only place that nils it.
    /// The loaded model, loading it exactly once.
    ///
    /// The `report(nil)` on both exits is what hands the surfaces back to the dictation: whichever
    /// way the load ends, the model is no longer being prepared, and a preparation left standing
    /// would sit on screen saying "Loading model" for the whole of the transcription that follows.
    /// It is deliberately NOT on the early return above -- a second dictation finds the model
    /// already loaded, reports nothing at all, and its card is the dictation's from the first frame.
    private func loadedKit() async throws -> LoadedModel {
        if let loading {
            return try await loading.value
        }
        let task = Task { [report] in try await Self.load(report: report) }
        loading = task
        do {
            let model = try await task.value
            await report(nil)
            return model
        } catch {
            loading = nil
            // Before the throw, so the failure the session is about to turn into `.failed` reaches
            // a card that is no longer showing a percentage frozen where the connection died.
            await report(nil)
            throw error
        }
    }

    /// Downloading and loading are separate steps so that "the model could not be fetched"
    /// (network, wrong identifier, Hugging Face down) is reportable as something other than
    /// "the model could not be loaded" (spec §9 wants a distinguishable failure per row), and so
    /// that the download has a progress callback routed to the UI. WhisperKit would do both inside
    /// its initialiser and collapse them into one `modelsUnavailable`.
    ///
    /// **The split is now visible from outside the app as well as inside it**, which is what that
    /// last clause was written for and never got: each of the two steps announces itself through
    /// `report`, so the wait a fresh Mac spends here says which half of it is happening.
    private static func load(
        report: @escaping @MainActor @Sendable (ModelPreparation?) -> Void
    ) async throws -> LoadedModel {
        let modelStore = try Storage.directory(subfolder: "models")

        // Warm start: the model is already on disk, so skip WhisperKit.download entirely.
        // `WhisperKit.download` asks the Hub for the file list BEFORE it looks at local files
        // (`WhisperKit.swift:250-260`: `getFilenames` then `snapshot`), which costs 4-5 s on
        // every process start even when nothing needs fetching -- paid before the first
        // dictation of every session, in an app whose whole value is being fast.
        if let cached = cachedModelFolder(in: modelStore) {
            do {
                // Announced on the warm path too, and that is not belt-and-braces: this is the
                // branch Louis's OWN Mac takes on the first dictation of every session, and the
                // load behind it was measured at 112 s cold. The machine with the model already on
                // disk has the same right to know what it is waiting for as the one downloading it.
                await report(.loading)
                return try await loadKit(from: cached, downloadBase: modelStore)
            } catch {
                // The folder looked complete but CoreML would not load it -- a truncated or
                // corrupted file inside one of the .mlmodelc bundles. Fall through to the normal
                // path, which re-validates every file against the Hub and refetches what is
                // broken, so a bad cache repairs itself instead of disabling the app forever.
                logger.warning("""
                    cached model did not load (\(error.localizedDescription, privacy: .public)) \
                    -- revalidating against the hub
                    """)
            }
        }

        let modelFolder = try await downloadModel(into: modelStore, report: report)

        do {
            await report(.loading)
            return try await loadKit(from: modelFolder, downloadBase: modelStore)
        } catch {
            logger.error("model load failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.modelLoadFailed(error)
        }
    }

    /// The local folder WhisperKit would have downloaded the variant into, if it holds a model.
    ///
    /// The path is asked of WhisperKit's own Hub client rather than spelled out here, so it
    /// cannot drift from where `WhisperKit.download` puts things. The three `.mlmodelc` bundles
    /// are the ones `loadModels` requires (`WhisperKit.swift:376-385`); anything less means an
    /// interrupted first download, and the caller must go back to the Hub. This is a cheap
    /// pre-filter, not a validation: a bundle can exist and still be corrupt, which is why the
    /// caller also treats a failed load as "go to the Hub".
    ///
    /// The list comes from `ModelInventory` rather than being spelled here, for the reason the
    /// path does: the Models pane decides whether a model reads as installed with the same
    /// constant, and two literals in two modules are two rules that can drift apart silently.
    private static func cachedModelFolder(in modelStore: URL) -> URL? {
        let folder = HubApiWrapper(downloadBase: modelStore)
            .localRepoLocation(HubApiWrapper.Repo(id: modelRepo, type: .models))
            .appending(path: dictationModel)
        let complete = ModelInventory.requiredBundles.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
        return complete ? folder : nil
    }

    private static func loadKit(from folder: URL, downloadBase: URL) async throws -> LoadedModel {
        let start = Date()
        let kit = try await WhisperKit(
            model: dictationModel,
            downloadBase: downloadBase,
            modelFolder: folder.path,
            verbose: false
        )
        logger.info("""
            model loaded in \
            \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s
            """)
        return LoadedModel(kit)
    }

    /// Downloads the model, failing loudly if the download stops making progress.
    ///
    /// There is still no cap on total duration -- the first pull is ~1.6 GB and a deadline short
    /// enough to catch a stall would abort a slow but healthy download. What is bounded is the
    /// gap between two progress reports, which is what a dropped connection actually looks like.
    /// Without this, a flaky connection leaves the caller suspended forever and Task 7's state
    /// machine stuck in `.transcribing`, which spec §9's error table has no row for.
    private static func downloadModel(
        into modelStore: URL,
        report: @escaping @MainActor @Sendable (ModelPreparation?) -> Void
    ) async throws -> URL {
        let lastProgress = OSAllocatedUnfairLock(initialState: Date())
        let start = Date()

        let modelFolder: URL
        do {
            modelFolder = try await withThrowingTaskGroup(of: URL?.self) { group in
                group.addTask {
                    try await announceBytesReceived(in: modelStore, report: report)
                }
                group.addTask {
                    let log = downloadProgressLogger()
                    return try await WhisperKit.download(
                        variant: dictationModel,
                        downloadBase: modelStore,
                        from: modelRepo,
                        progressCallback: { progress in
                            lastProgress.withLock { $0 = Date() }
                            log(progress)
                        }
                    )
                }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .seconds(stallCheckInterval))
                        let idle = Date().timeIntervalSince(lastProgress.withLock { $0 })
                        if idle >= downloadStallTimeout {
                            throw Failure.modelDownloadStalled(idle)
                        }
                    }
                }
                defer { group.cancelAll() }
                // The watchdog and the byte reporter only ever finish by throwing, so the first
                // result is the download's, and cancelling the group here stops both.
                for try await result in group {
                    if let result { return result }
                }
                throw Failure.modelDownloadStalled(Date().timeIntervalSince(start))
            }
        } catch let failure as Failure {
            logger.error("model download stalled: \(failure.localizedDescription, privacy: .public)")
            throw failure
        } catch {
            logger.error("model download failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.modelDownloadFailed(error)
        }

        logger.info("""
            model ready at \(modelFolder.path, privacy: .public) \
            in \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s
            """)
        return modelFolder
    }

    /// A download that reports no progress for this long is treated as stalled rather than slow.
    ///
    /// Read from the download code rather than guessed: `Downloader` broadcasts progress once per
    /// completed chunk, and `chunkSize` defaults to **10 MB** (`Downloader.swift:69`), so the
    /// longest legitimate silence is the time to pull 10 MB -- 80 s on a 1 Mbps link, 8 s on
    /// 10 Mbps. Below that, `URLRequest.timeoutInterval` is 10 s (`Downloader.swift:102,195`) and
    /// `httpGet` retries 5 times, so WhisperKit's own recovery budget for a dead connection is
    /// already ~55 s. 180 s sits above both: it never pre-empts a recovery WhisperKit would have
    /// made, and it only fires when sustained throughput is under ~56 kB/s -- while still turning
    /// "hangs forever" into a reportable failure.
    private static let downloadStallTimeout: TimeInterval = 180
    private static let stallCheckInterval: TimeInterval = 5

    /// How often the store is measured while the model comes down.
    ///
    /// A second, because the percentage it feeds is quantised to whole points and this is what
    /// bounds how late a point can be. It does not bound how often the interface changes: on a fast
    /// link several points land in one second and only the last is reported, on a slow one a point
    /// takes half a minute and nothing is reported in between. What actually keeps the card moving
    /// throughout is not this rate at all -- it is the sweep, which is a function of the clock.
    private static let byteCheckInterval: TimeInterval = 1

    /// Reports how much of the model is on disk, for as long as it is being downloaded.
    ///
    /// **Bytes on disk, rather than the fraction WhisperKit hands out**, and `ModelDownload`'s own
    /// note carries the measurement that forces it: the Hub's `Progress` averages 24 files
    /// unweighted, two of which are 98.6 % of the bytes, so its `fractionCompleted` reaches 91.7 %
    /// in the first seconds and crawls for the rest. Walking the store instead counts the
    /// `.incomplete` file currently being written as well as everything already moved into place,
    /// which is exactly the quantity the wait is made of.
    ///
    /// It never returns: it is cancelled by the group when the download finishes. The first report
    /// is sent before the first sleep so the card says what it is doing from the outset rather than
    /// a second in.
    ///
    /// **The store, not the variant folder.** `HubApiWrapper.localRepoLocation` is where the
    /// repository lands, and it is where both the finished files and the `.cache/…/*.incomplete`
    /// ones live. It holds one variant on a machine that has only ever run Murmure; a store that
    /// also held another would make this over-count, which the ceiling in `ModelDownload` bounds
    /// at 99 %.
    private static func announceBytesReceived(
        in modelStore: URL,
        report: @escaping @MainActor @Sendable (ModelPreparation?) -> Void
    ) async throws -> URL? {
        let repo = HubApiWrapper(downloadBase: modelStore)
            .localRepoLocation(HubApiWrapper.Repo(id: modelRepo, type: .models))
        var download = ModelDownload(expectedBytes: ModelDownload.transcriptionModelBytes)
        await report(.downloading(download))
        while true {
            try await Task.sleep(for: .seconds(byteCheckInterval))
            let shown = download
            download.observe(receivedBytes: bytesOnDisk(in: repo))
            // Only when what Louis would READ has changed. `ModelDownload` stores the percentage it
            // shows, so this comparison is that question rather than an approximation of it -- and
            // each report it skips is a hop onto the main actor, a route through `StatusRouter` and
            // a redraw of both surfaces that would have changed nothing.
            guard download != shown else { continue }
            await report(.downloading(download))
        }
    }

    /// Every byte under a folder, hidden files included.
    ///
    /// The `.incomplete` file being written right now lives in `.cache/huggingface/download/`, so
    /// skipping hidden files would skip the only part of the tree that is currently growing and the
    /// count would advance in whole-file steps -- the very defect the byte count exists to avoid.
    ///
    /// An unreadable folder measures zero, which `ModelDownload.observe` drops rather than treats
    /// as a reading: a percentage must not fall back to 0 because a directory walk failed once.
    private static func bytesOnDisk(in folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
        return total
    }

    /// Logs the first download once per completed tenth, in WhisperKit's own terms.
    ///
    /// Kept now that the download has a surface, and deliberately NOT replaced by it: this is the
    /// file-count fraction, the card shows the byte one, and having both in the record is what
    /// would let a future "the bar sat at 40 % for ten minutes" be diagnosed rather than guessed
    /// at. It is also the only thing that still says anything at all if the reporting path breaks.
    private static func downloadProgressLogger() -> ProgressCallback {
        let lastTenth = OSAllocatedUnfairLock(initialState: -1)
        return { progress in
            let tenth = Int(progress.fractionCompleted * 10)
            let isNew = lastTenth.withLock { last in
                guard tenth > last else { return false }
                last = tenth
                return true
            }
            guard isNew else { return }
            logger.info("""
                downloading \(dictationModel, privacy: .public) -- \
                \(tenth * 10, privacy: .public)%
                """)
        }
    }
}

/// Carries the loaded model across isolation boundaries and keeps every call to it on one side.
///
/// `WhisperKit` is a plain non-`Sendable` class, so handing an instance from the load task back
/// into the actor is rejected in the Swift 6 language mode. The `@unchecked` claim is narrow and
/// checkable: the instance is created inside `WhisperKitEngine.load()`, stored only here, and
/// reachable only through one actor. It is not a claim that `WhisperKit` is single-threaded --
/// WhisperKit fans a single transcription out over `DecodingOptions.concurrentWorkerCount`
/// (16 on macOS) workers sharing one instance, so its own design already assumes concurrent use.
///
/// `transcribe` is a method here rather than a `kit` property so that the call happens on this
/// side of the boundary: reading `kit` from the actor and calling into it there would push a
/// non-`Sendable` value back out of the actor and reintroduce the same diagnostic.
private final class LoadedModel: @unchecked Sendable {
    private let kit: WhisperKit

    init(_ kit: WhisperKit) {
        self.kit = kit
    }

    /// Runs the transcription and leaves its progress where the interface can pull it.
    ///
    /// `kit.progress` is read ONCE, before the call, and that object is what the box follows.
    /// Re-reading the property would report a different object: WhisperKit replaces it with a
    /// fresh `Progress` as soon as the transcription finishes (`WhisperKit.swift:1167-1169`), and
    /// measured on three real recordings the captured object reads 1.0 afterwards while the
    /// property reads 0. It is also read here rather than in `WhisperKitEngine` because that is
    /// what this class is for: the instance stays on this side of the isolation boundary.
    ///
    /// `finish()` only on the success path. A transcription that threw has not reached the end of
    /// the audio, and saying it did would be the one thing this whole mechanism exists not to do.
    ///
    /// `initialPrompt` is encoded here rather than in `WhisperKitEngine`, for the same isolation
    /// reason as `kit.progress` above: the tokenizer lives on `kit`, which does not cross the
    /// boundary either.
    func transcribe(
        audio: [Float], language: String, initialPrompt: String?, reporting box: DecodeProgressBox
    ) async throws -> [TranscriptionResult] {
        box.follow(kit.progress)
        let options = DecodingOptions(
            language: language, promptTokens: promptTokens(for: initialPrompt))
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        box.finish()
        return results
    }

    /// `initialPrompt`, tokenized the way `benchmark/vocabprobe/Sources/vocabprobe/main.swift:152`
    /// measured it -- `tokenizer.encode(text:)`, with the special tokens it prepends filtered back
    /// out, fed to `DecodingOptions.promptTokens`.
    ///
    /// The filter is load-bearing, not defensive. `encode` always prepends its own special tokens
    /// (`<|startoftranscript|>` and friends); feeding those back in as PROMPT tokens is a
    /// different, unmeasured input to the decoder -- not the recipe
    /// `docs/benchmarks/2026-09-vocabulary-prompt.md` ran. `specialTokenBegin` is the exact cutoff
    /// `vocabprobe` used.
    ///
    /// `nil` for no prompt, or when the loaded model has no tokenizer to encode it with.
    private func promptTokens(for initialPrompt: String?) -> [Int]? {
        guard let initialPrompt, let tokenizer = kit.tokenizer else { return nil }
        return tokenizer.encode(text: initialPrompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }
}


/// Actor isolation satisfies the nonisolated `async` requirement: callers must `await` either way.
extension WhisperKitEngine: Transcriber {}
