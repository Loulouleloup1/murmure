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

/// Which mode a dictation runs under, and what its transcript becomes (spec §5).
///
/// Two calls rather than one because they happen at opposite ends of one dictation: the mode is
/// resolved when the recording STARTS -- the application Louis was looking at while he spoke is
/// what decides, not the one he may have switched to since -- while a refinement can only run
/// once there is a transcript to refine.
///
/// Neither the requirement nor `init`'s parameter has a default. A "refine nothing" default would
/// compile at every call site, Louis would never get a refinement, and no test would fail: the
/// silent failure ruling L7 keeps catching. `Murmure` builds the real one from `ModeStore`,
/// `ModeSelection` and `TranscriptRefiner`.
public protocol DictationRefining: Sendable {
    /// Called on the toggle that starts a recording, never later.
    func modeForNewDictation() async -> Mode

    /// The text to insert. Total, and never `nil`: Louis has just spoken and that text exists
    /// nowhere else, so a refinement that cannot happen answers with the raw transcript.
    func refine(_ transcript: String, with mode: Mode) async -> String
}

/// One dictation end-to-end: idle → recording → transcribing → [refining] → inserting →
/// idle/failed. `refining` only when the resolved mode has an LLM; `Voice` runs lot 1's sequence
/// unchanged.
///
/// The seams above are protocols so the whole state machine is testable in `MurmureCore`: the app
/// target has no test bundle, and the four real implementations each touch hardware, the network
/// or the pasteboard.
public actor DictationSession {
    public enum State: Equatable {
        case idle, recording, transcribing, refining, inserting
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
    private let refiner: any DictationRefining
    private let onStateChange: @Sendable (State) -> Void

    /// The mode the recording in progress runs under, fixed when it started. `Voice` until the
    /// first dictation resolves one -- the same default `ModeSelection` falls back to.
    private var activeMode: Mode = .voice

    public init(
        recorder: Recorder, transcriber: Transcriber, inserter: TextInserter,
        refiner: any DictationRefining,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.refiner = refiner
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
        case .transcribing, .refining, .inserting:
            break // pipeline already running; ignore extra presses
        case .idle, .failed:
            do {
                try recorder.start()
                // Resolved here rather than in `finishRecording()`: what decides is the
                // application Louis was looking at while he pressed, not the one he may have
                // switched to by the time he stops. Resolved AFTER a successful start, so a
                // refused microphone never pays for a read of the modes folder.
                //
                // This `await` is the one suspension point in a branch lot 1 kept atomic, so a
                // second press landing inside it is read as another start rather than as a stop.
                //
                // Nothing closes that window: it stays open for as long as this line takes, and
                // the only reason a press does not land in it is TIMING -- what is awaited is a
                // read of four small files, orders of magnitude under the reaction time of a
                // double press. That is an argument to re-verify the day this resolution grows a
                // network call or a model load, not a structural guarantee.
                //
                // What does not depend on timing is the outcome when a press DOES land inside:
                // `AudioRecorder.start()` refuses a second recording (`guard sink == nil`), so
                // the second press ends in `.failed` -- which the first press then overwrites
                // with `.recording` when it resumes, a brief and harmless flash. Never two taps
                // on one device. That exact sequence is pinned by
                // `testASecondPressInsideTheModeResolutionCannotStartASecondRecording`, so a
                // change to it fails a test rather than passing unnoticed.
                activeMode = await refiner.modeForNewDictation()
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
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(wav: wav)
        } catch {
            transition(to: .failed(
                message: "transcription failed: \(error.localizedDescription)",
                recoveredText: nil))
            return
        }

        // The refined text, not the raw one, is what gets inserted -- so it is also what a
        // "paste the last transcript again" has to offer.
        let text = await refined(transcript)
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

    /// The transcript as it will be inserted.
    ///
    /// `Voice` -- and any other mode with `llm.enabled == false` -- returns from the first line:
    /// no `.refining` state, and no call to the refiner at all. Lot 1's behaviour has to survive
    /// this lot byte for byte, and the only way to guarantee that is for the step not to happen,
    /// rather than to happen and be expected to change nothing.
    ///
    /// The empty check is about what gets PASTED, not about a wasted call. Whisper answers
    /// silence with "" or a lone newline, and the refiner's anti-refusal rule is a fraction of the
    /// transcript's length: against a length of zero, every answer clears it -- "Bien sûr ! Voici
    /// le texte corrigé :" included -- and it would land in whatever Louis has focused as if he
    /// had dictated it. `PasteInserter` already refuses an empty string, which stops the paste of
    /// nothing; it cannot stop the paste of something. Trimmed rather than `isEmpty`, because a
    /// transcript of one newline is the same nothing and would defeat the guard unseen.
    private func refined(_ transcript: String) async -> String {
        guard activeMode.llm.enabled,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return transcript }

        // Its own state, because the wait is long enough to look like a hang: 19 s at the p-high
        // of the measured refinements and 57.5 s on the worst real case, during which a frozen
        // hourglass says nothing about whether the model is working or the app is stuck.
        transition(to: .refining)
        return await refiner.refine(transcript, with: activeMode)
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange(newState)
    }
}
