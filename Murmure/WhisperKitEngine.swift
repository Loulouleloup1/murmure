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
        case modelLoadFailed(Error)
        case transcriptionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .modelDownloadFailed(let error):
                """
                Could not download the transcription model. Check your internet connection \
                and try again. (\(error.localizedDescription))
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
    /// Returns the empty string when the audio held no speech. Whisper answers silence with
    /// either nothing or a hallucinated stock phrase; normalising the first case here means the
    /// pipeline gets "" rather than a string of whitespace it would treat as real text.
    func transcribe(wav: URL) async throws -> String {
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
            logger.warning("no speech in \(wav.lastPathComponent, privacy: .public)")
        }
        return text
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

        let modelFolder: URL
        do {
            let start = Date()
            modelFolder = try await WhisperKit.download(
                variant: dictationModel,
                downloadBase: modelStore,
                progressCallback: downloadProgressLogger()
            )
            logger.info("""
                model ready at \(modelFolder.path, privacy: .public) \
                in \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s
                """)
        } catch {
            logger.error("model download failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.modelDownloadFailed(error)
        }

        do {
            let start = Date()
            let kit = try await WhisperKit(
                model: dictationModel,
                downloadBase: modelStore,
                modelFolder: modelFolder.path,
                verbose: false
            )
            logger.info("""
                model loaded in \
                \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s
                """)
            return LoadedModel(kit)
        } catch {
            logger.error("model load failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.modelLoadFailed(error)
        }
    }

    /// Logs the first download once per completed tenth. There is deliberately no timeout: the
    /// first run pulls ~1.6 GB, and a deadline short enough to catch a stall would abort a slow
    /// but healthy download. Until the models lot gives this a UI, the log is what tells the
    /// difference between "downloading" and "stuck".
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

    func transcribe(path: String, options: DecodingOptions) async throws -> [TranscriptionResult] {
        try await kit.transcribe(audioPath: path, decodeOptions: options)
    }
}
