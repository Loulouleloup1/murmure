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
    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// Whisper's language token has to be decided before the first text token. WhisperKit's
    /// default `DecodingOptions()` leaves `language` nil AND `detectLanguage` false (it is
    /// derived as `!usePrefillPrompt`), and the decoder then prefills `<|en|>` -- French audio
    /// would be decoded as English and come back as plausible-looking garbage with no error
    /// raised anywhere. Detection is turned on explicitly, which also matches the spec's
    /// per-mode `"language": "auto"` default (§5) instead of hard-coding French.
    private static let decodeOptions = DecodingOptions(detectLanguage: true)

    private var loading: Task<LoadedModel, Error>?

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
    func transcribe(wav: URL) async throws -> String {
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

        if case .silence(let reason) = SpeechGate.verdict(for: samples) {
            // Deliberately not an error: an empty recording is "you said nothing", which the
            // pipeline already handles as a no-op. No banner, no paste, nothing to dismiss.
            logger.info("""
                no speech in \(wav.lastPathComponent, privacy: .public) -- \
                \(reason, privacy: .public); not transcribed
                """)
            return ""
        }

        let model = try await loadedKit()

        let results: [TranscriptionResult]
        do {
            results = try await model.transcribe(path: wav.path, options: Self.decodeOptions)
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

    /// The recording as the model will hear it: 16 kHz mono float samples.
    ///
    /// This is WhisperKit's own loader, the same one `transcribe(audioPath:)` calls, so the gate
    /// measures exactly the signal the model would be given rather than an approximation of it.
    /// It is a second decode of the same file -- measured at a few milliseconds for a dictation
    /// of a few seconds, against the ~1.6 s the transcription itself takes -- and the alternative
    /// (`transcribe(audioArray:)`) would move the whole pipeline onto a different WhisperKit
    /// entry point than the one Task 5 verified.
    private static func samples(of wav: URL) throws -> [Float] {
        let buffer = try AudioProcessor.loadAudio(fromPath: wav.path)
        return AudioProcessor.convertBufferToArray(buffer: buffer)
    }

    /// The loaded model, loading it exactly once.
    ///
    /// Creating the task and storing it happen with no `await` between them, so no second caller
    /// can observe `loading == nil` while a load is in flight. A failed load clears the task so
    /// the next dictation retries: a dropped Wi-Fi connection must not disable transcription for
    /// the lifetime of the process. Clearing unconditionally is safe -- a new task can only be
    /// created by a caller that found `loading` nil, and this is the only place that nils it.
    private func loadedKit() async throws -> LoadedModel {
        if let loading {
            return try await loading.value
        }
        let task = Task { try await Self.load() }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    /// Downloading and loading are separate steps so that "the model could not be fetched"
    /// (network, wrong identifier, Hugging Face down) is reportable as something other than
    /// "the model could not be loaded" (spec §9 wants a distinguishable failure per row), and so
    /// that the download has a progress callback for a later lot to route to the UI. WhisperKit
    /// would do both inside its initialiser and collapse them into one `modelsUnavailable`.
    private static func load() async throws -> LoadedModel {
        let modelStore = try Storage.appSupportDirectory(subfolder: "models")

        // Warm start: the model is already on disk, so skip WhisperKit.download entirely.
        // `WhisperKit.download` asks the Hub for the file list BEFORE it looks at local files
        // (`WhisperKit.swift:250-260`: `getFilenames` then `snapshot`), which costs 4-5 s on
        // every process start even when nothing needs fetching -- paid before the first
        // dictation of every session, in an app whose whole value is being fast.
        if let cached = cachedModelFolder(in: modelStore) {
            do {
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

        let modelFolder = try await downloadModel(into: modelStore)

        do {
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
    private static func cachedModelFolder(in modelStore: URL) -> URL? {
        let folder = HubApiWrapper(downloadBase: modelStore)
            .localRepoLocation(HubApiWrapper.Repo(id: modelRepo, type: .models))
            .appending(path: dictationModel)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let complete = required.allSatisfy {
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
    private static func downloadModel(into modelStore: URL) async throws -> URL {
        let lastProgress = OSAllocatedUnfairLock(initialState: Date())
        let start = Date()

        let modelFolder: URL
        do {
            modelFolder = try await withThrowingTaskGroup(of: URL?.self) { group in
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
                // The watchdog only ever finishes by throwing, so the first result is the
                // download's, and cancelling the group here stops the watchdog.
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

    /// Logs the first download once per completed tenth. Until the models lot gives this a UI,
    /// the log is what tells the difference between "downloading" and "stuck".
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

/// Decides whether a recording is worth transcribing at all.
///
/// This exists because Whisper fabricates text on near-silence, non-deterministically: the same
/// 3.1 s of room tone returned `¿Qué es lo que se llama?`, then nothing, then `¿Qué es la vida?`
/// across three runs of identical options. Nothing about the model's *output* distinguishes those
/// from a real dictation, so the only safe place to act is before it runs. Superwhisper -- the app
/// this clones -- ships `vad-v1.onnx`/`vad-v2.onnx` for the same reason; an energy gate is the
/// no-new-dependency version of that, and WhisperKit already ships the energy VAD used here.
///
/// The thresholds are measured, not chosen. Over Louis's 1 482 real dictations
/// (`~/Documents/superwhisper/recordings/*/output.wav`, transcript in the sibling `meta.json`),
/// scoring each file by how many 100 ms frames have RMS above 0.005:
///
/// - the 1 437 files with a real transcript: **minimum 0.5 s** of voiced audio, median 21.3 s;
/// - the 40 files whose transcript is empty or a single character: 33 of them under 0.4 s;
/// - the room-tone recording that produced the hallucination above: **0.2 s**.
///
/// So 0.3 s sits between the quietest real dictation ever recorded (0.5 s, a 40 % margin) and the
/// hallucinating file (0.2 s), and rejects **0 of 1 437** real dictations. The bias is deliberate:
/// letting some room tone through costs a wrong paste that Whisper usually declines to produce,
/// while rejecting a real dictation loses something Louis actually said.
///
/// The 0.005 frame threshold is likewise from the corpus: raising it to WhisperKit's default 0.02
/// would false-reject 2.7 % of real dictations (39 of 1 437) because Louis's quiet recordings peak
/// below it, for only 7 more silent files rejected.
private enum SpeechGate {
    enum Verdict {
        case speech
        /// Carries why, for the log only -- the caller returns "" either way.
        case silence(String)
    }

    /// Frame length in seconds, WhisperKit's `EnergyVAD` default. A voiced frame is 100 ms.
    private static let frameLength: Float = 0.1

    /// RMS above which a 100 ms frame counts as voiced. See the type's note for the calibration.
    private static let energyThreshold: Float = 0.005

    /// Total voiced time a recording needs before it is worth transcribing.
    private static let minimumVoicedDuration: TimeInterval = 0.3

    /// Minimum length of the recording itself. The shortest real dictation in the 1 482-file
    /// corpus is 1.34 s, so 0.5 s is 2.7x under anything Louis has ever said; it is here to make
    /// a brushed hotkey (a 0-frame file, or tens of milliseconds of audio) cost nothing at all.
    private static let minimumDuration: TimeInterval = 0.5

    static func verdict(for samples: [Float], sampleRate: Int = WhisperKit.sampleRate) -> Verdict {
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration >= minimumDuration else {
            return .silence(String(format: "%.2fs long, under the %.1fs minimum", duration, minimumDuration))
        }

        let vad = EnergyVAD(
            sampleRate: sampleRate,
            frameLength: frameLength,
            energyThreshold: energyThreshold
        )
        let voiced = Double(vad.voiceActivity(in: samples).filter { $0 }.count) * Double(frameLength)
        guard voiced >= minimumVoicedDuration else {
            return .silence(String(
                format: "%.1fs of voice in %.1fs, under the %.1fs minimum",
                voiced, duration, minimumVoicedDuration
            ))
        }

        return .speech
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

    func transcribe(path: String, options: DecodingOptions) async throws -> [TranscriptionResult] {
        try await kit.transcribe(audioPath: path, decodeOptions: options)
    }
}

