import AVFoundation
import Foundation

public protocol Recorder {
    func start() throws
    func stop() -> URL?
    /// Why the last `stop()` returned nil, when it returned nil because a write failed rather
    /// than because nothing was recorded. Added by ruling L7 -- without it both cases collapse
    /// into one generic message and `AudioRecorder`'s failure detail has no consumer.
    var lastFailure: Error? { get }
}

public protocol Transcriber {
    func transcribe(wav: URL) async throws -> String
}

public protocol TextInserter {
    func insert(_ text: String) async throws
}

/// One dictation end-to-end: idle → recording → transcribing → inserting → idle/failed.
///
/// The seams above are protocols so the whole state machine is testable in `MurmureCore`: the app
/// target has no test bundle, and the three real implementations each touch hardware, the network
/// or the pasteboard.
public actor DictationSession {
    public enum State: Equatable {
        case idle, recording, transcribing, inserting
        case failed(message: String, recoveredText: String?)
    }

    public private(set) var state: State = .idle

    /// The text of the last dictation that produced any, kept so it can be pasted again -- into
    /// another app, or after an insertion failure. Cleared when a dictation produces no text, so
    /// a "paste the last transcript" action can never reach back past a failure into an older one.
    public private(set) var lastTranscript: String?

    private let recorder: Recorder
    private let transcriber: Transcriber
    private let inserter: TextInserter
    private let onStateChange: @Sendable (State) -> Void

    public init(
        recorder: Recorder, transcriber: Transcriber, inserter: TextInserter,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.onStateChange = onStateChange
    }

    /// The hotkey's only entry point: starts a recording when idle, otherwise stops it and runs
    /// the pipeline. Presses arriving while the pipeline runs are ignored -- an actor is
    /// re-entrant, so they really do arrive, and starting a second recording under a running
    /// transcription is never what the press meant.
    public func toggle() async {
        switch state {
        case .recording:
            await finishRecording()
        case .transcribing, .inserting:
            break // pipeline already running; ignore extra presses
        case .idle, .failed:
            do {
                try recorder.start()
                transition(to: .recording)
            } catch {
                transition(to: .failed(
                    message: "mic start failed: \(error.localizedDescription)", recoveredText: nil))
            }
        }
    }

    private func finishRecording() async {
        // This dictation's transcript is not known yet, and the previous one is no longer "the
        // last": if this dictation fails before producing text, a recovery paste must have nothing
        // to offer rather than silently offer the text of the dictation before it.
        lastTranscript = nil

        // Ruling L7, first half: `stop()` returns nil for two very different reasons -- nothing was
        // recorded, or buffers failed to reach the disk. Collapsing them loses the only actionable
        // one, and `AudioRecorder` already carries the detail.
        guard let wav = recorder.stop() else {
            let reason = recorder.lastFailure.map { "recording failed: \($0.localizedDescription)" }
                ?? "no audio captured"
            transition(to: .failed(message: reason, recoveredText: nil))
            return
        }

        // Ruling L7, second half: a start-then-immediate-stop yields a VALID 0-frame WAV, not nil.
        // Sending it to WhisperKit wastes a model load and returns either empty text or a
        // hallucinated phrase on silence -- the worse outcome, since it would be pasted. Treat an
        // empty recording as a no-op that returns to idle, not as an error to report.
        //
        // Read with a real `do`/`catch` rather than `try?`: a file that cannot be opened at all is
        // a corrupt or truncated recording, and `try?` would hand it to the `frames > 0` guard
        // below, which would report it as "nothing was said" -- the same silent failure the two
        // branches above exist to avoid.
        let frames: AVAudioFramePosition
        do {
            frames = try AVAudioFile(forReading: wav).length
        } catch {
            transition(to: .failed(
                message: "unreadable recording: \(error.localizedDescription)", recoveredText: nil))
            return
        }
        guard frames > 0 else {
            transition(to: .idle)
            return
        }

        transition(to: .transcribing)
        let text: String
        do {
            text = try await transcriber.transcribe(wav: wav)
        } catch {
            transition(to: .failed(
                message: "transcription failed: \(error.localizedDescription)",
                recoveredText: nil))
            return
        }
        lastTranscript = text

        transition(to: .inserting)
        do {
            try await inserter.insert(text)
            transition(to: .idle)
        } catch {
            // Spec §9: the dictation is never lost -- keep the text for recovery.
            transition(to: .failed(
                message: "insert failed: \(error.localizedDescription)", recoveredText: text))
        }
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange(newState)
    }
}
