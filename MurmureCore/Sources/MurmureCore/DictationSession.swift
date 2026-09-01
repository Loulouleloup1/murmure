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

/// The application a dictation was aimed at: the one in front when the recording started.
///
/// Both halves are optional because both really are absent sometimes -- there may be no frontmost
/// application at all, and an application without a bundle identifier is unusual rather than
/// impossible. Storing `""` for either would put a lie in the archive where a NULL says the truth
/// (`HistoryRecord`, and D6 stated once for every optional column).
public struct DictationTarget: Equatable, Sendable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String? = nil, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name
    }

    /// Nothing was in front, or nothing could be read.
    public static let unknown = DictationTarget()
}

/// Where a finished dictation goes (§5.2), and what it was aimed at.
///
/// Two calls at opposite ends of one dictation, which is the shape -- and the reason --
/// ``DictationRefining`` already has: the target application is read when the recording STARTS,
/// because it is the application Louis was looking at while he spoke and not the one he may have
/// switched to by the time the text lands, while the row can only be written once there is
/// something to say about the dictation.
///
/// No default, for the third time in this file and for ruling L7's reason: a session built without
/// a recorder would run every dictation and archive none of them, and nothing on screen would
/// differ. `Murmure` builds the real one from `HistoryStore` and `NSWorkspace`; the tests use a
/// spy, so nothing here needs a database.
public protocol DictationRecording: Sendable {
    /// Called on the toggle that starts a recording, never later.
    func targetForNewDictation() async -> DictationTarget

    /// Called exactly once per dictation that got as far as recording, whatever became of it --
    /// including the two that produce no text at all, `.nothingHeard` and `.cancelled`. The
    /// absence of a row is as much a lost dictation as a wrong one.
    ///
    /// A press the microphone refused is the one thing that writes nothing: no recording began,
    /// so there is no dictation to archive -- the same line `modeForNewDictation()` already draws.
    func record(_ dictation: HistoryRecord) async
}

/// One dictation end-to-end: idle → recording → transcribing → [refining] → inserting →
/// completed → idle, or failed. `refining` only when the resolved mode has an LLM; `Voice` runs
/// lot 1's sequence unchanged.
///
/// The seams above are protocols so the whole state machine is testable in `MurmureCore`: the app
/// target has no test bundle, and the four real implementations each touch hardware, the network
/// or the pasteboard.
public actor DictationSession {
    public enum State: Equatable {
        case idle, recording, transcribing, refining, inserting
        /// The dictation ran to its end, and `insertedCharacters` is how much of it reached the
        /// target application. Always followed immediately by `.idle`: this state says what
        /// happened, it is not a state the session sits in, and how long a completion stays on
        /// screen is the interface's business, not the machine's.
        ///
        /// Zero is the case this state exists for. Until lot 3 the success path and the two
        /// silences -- a recording with no frames, a transcript Whisper returned empty -- all
        /// ended in `.idle`, so nothing downstream could tell "your text was pasted" from
        /// "nothing you said got through". A green flash driven by `.idle` would congratulate
        /// Louis for a dictation that inserted nothing.
        case completed(insertedCharacters: Int)
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
    private let recording: any DictationRecording
    private let now: @Sendable () -> Date
    private let onStateChange: @Sendable (State) -> Void

    /// The mode the recording in progress runs under, fixed when it started. `Voice` until the
    /// first dictation resolves one -- the same default `ModeSelection` falls back to.
    private var activeMode: Mode = .voice

    /// What was in front when the recording started, fixed there for the same reason as the mode.
    private var target: DictationTarget = .unknown

    /// When the recording in progress started. `distantPast` until one does; no row can carry it,
    /// because a row is only ever written for a dictation that reached `.recording`.
    private var startedAt: Date = .distantPast

    /// How long the microphone was live: from `startedAt` to the moment `recorder.stop()`
    /// returned. **Not** the pipeline that follows it (§5.2) -- a 4-second dictation whose
    /// transcription took 12 seconds is a 4-second dictation, and the two numbers below are where
    /// the other twelve are said.
    private var recordedSeconds: Double = 0
    /// Wall-clock spent inside `transcriber.transcribe`, failures included: a transcription that
    /// died after 40 s is a timeout and one that died instantly is a missing model, and the row is
    /// the only place that distinction survives.
    private var transcriptionSeconds: Double?
    /// Wall-clock spent inside `refiner.refine`. `nil` when the refiner was never called, which is
    /// also what makes `refinementSeconds != nil` with a NULL `refinedText` readable after the
    /// fact: a refinement ran and changed nothing (D6).
    private var refinementSeconds: Double?

    /// `now` has a default where `refiner` and `recording` deliberately do not, and the difference
    /// is ruling L7's own test: a seam left out here cannot fail silently, because there is only
    /// one right answer in production and it is the default. It exists so that the three durations
    /// above are assertable to the millisecond in a test rather than to "greater than zero".
    public init(
        recorder: Recorder, transcriber: Transcriber, inserter: TextInserter,
        refiner: any DictationRefining, recording: any DictationRecording,
        // A closure literal rather than `Date.init`, which is not `@Sendable` and warns here.
        now: @escaping @Sendable () -> Date = { Date() },
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.refiner = refiner
        self.recording = recording
        self.now = now
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
        // `.completed` is here for the compiler and not for the machine: it is emitted and left
        // in the same call (`complete(insertedCharacters:)`), so no press can ever observe it.
        // Grouped with `.idle` because that is what it becomes a line later.
        case .idle, .completed, .failed:
            do {
                try recorder.start()
                // The clock is read before either resolution below, because what the row calls
                // `startedAt` is when the RECORDING started -- the microphone has been live since
                // the line above, and the reads that follow are Murmure's own overhead, not
                // seconds Louis was speaking into.
                startedAt = now()
                recordedSeconds = 0
                transcriptionSeconds = nil
                refinementSeconds = nil

                // Both resolved here rather than in `finishRecording()`: what decides is the
                // application Louis was looking at while he pressed, not the one he may have
                // switched to by the time he stops. Resolved AFTER a successful start, so a
                // refused microphone never pays for a read of the modes folder -- and writes no
                // history row either, for the same reason: there was no dictation.
                //
                // The target is read first because it is the more perishable of the two: it is a
                // property of the desktop, which a click can change while the modes are being
                // read off the disk.
                //
                // These two `await`s are the suspension points in a branch lot 1 kept atomic, so a
                // second press landing inside them is read as another start rather than as a stop.
                //
                // Nothing closes that window: it stays open for as long as these lines take, and
                // the only reason a press does not land in it is TIMING -- what is awaited is one
                // read of the frontmost application and a read of four small files, orders of
                // magnitude under the reaction time of a double press. That is an argument to
                // re-verify the day either resolution grows a network call or a model load, not a
                // structural guarantee.
                //
                // What does not depend on timing is the outcome when a press DOES land inside:
                // `AudioRecorder.start()` refuses a second recording (`guard sink == nil`), so
                // the second press ends in `.failed` -- which the first press then overwrites
                // with `.recording` when it resumes, a brief and harmless flash. Never two taps
                // on one device. That exact sequence is pinned by
                // `testASecondPressInsideTheModeResolutionCannotStartASecondRecording`, so a
                // change to it fails a test rather than passing unnoticed.
                target = await recording.targetForNewDictation()
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
            recordedSeconds = now().timeIntervalSince(startedAt)
            let reason = recorder.lastFailure.map { "recording failed: \($0.localizedDescription)" }
                ?? "no audio captured"
            transition(to: .failed(message: reason, recoveredText: nil))
            // A row with no audio, which is exactly what happened: the recording ran and its bytes
            // did not reach the disk. `audioFilename` NULL says that, where a filename pointing at
            // a file that was never written would say something false.
            await archive(.failed, failureMessage: reason)
            return
        }
        // Read once the recorder has stopped, so it is the length of the recording and not of the
        // press-to-press round trip. Everything below this line -- reading the file, transcribing,
        // refining, pasting -- is the pipeline, and none of it belongs in this number.
        recordedSeconds = now().timeIntervalSince(startedAt)

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
            let message = "unreadable recording: \(error.localizedDescription)"
            transition(to: .failed(message: message, recoveredText: nil))
            // The WAV is named in the row even though it could not be read here. The file is on
            // disk, and a corrupt header is not the same as an absent recording: a row that points
            // at it is what lets it be found, replayed or salvaged later.
            await archive(.failed, audio: wav, failureMessage: message)
            return
        }
        guard frames > 0 else {
            complete(insertedCharacters: 0)
            // Nothing was transcribed, so `rawTranscript` and `transcriptionSeconds` stay NULL --
            // and the row still exists, with its duration and its audio. Two presses in a row are
            // a thing that happened, not a thing that did not.
            await archive(.nothingHeard, audio: wav)
            return
        }

        transition(to: .transcribing)
        let transcriptionStarted = now()
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(wav: wav)
        } catch {
            transcriptionSeconds = now().timeIntervalSince(transcriptionStarted)
            let message = "transcription failed: \(error.localizedDescription)"
            transition(to: .failed(message: message, recoveredText: nil))
            await archive(.failed, audio: wav, failureMessage: message)
            return
        }
        transcriptionSeconds = now().timeIntervalSince(transcriptionStarted)

        // The refined text, not the raw one, is what gets inserted -- so it is also what a
        // "paste the last transcript again" has to offer. Both are kept from here on: the archive
        // stores them side by side (D6), so the raw transcript survives a refinement rather than
        // being replaced by it.
        let text = await refined(transcript)
        lastTranscript = text

        transition(to: .inserting)
        do {
            try await inserter.insert(text)
            // The refined text, which is what `inserter` was handed and therefore what landed --
            // not the raw transcript, and not a boolean "it worked". `PasteInserter` returns
            // early on an empty string, so a count of 0 here is exactly the case where nothing
            // was pasted.
            complete(insertedCharacters: text.count)
            // Whisper answering silence with "" is the third silence of ruling L7, and it is a
            // `.nothingHeard` rather than an `.inserted` of zero characters: what is stored is
            // decided by whether there was text to insert, never recovered from the count (D8).
            await archive(
                text.isEmpty ? .nothingHeard : .inserted,
                audio: wav,
                rawTranscript: storedTranscript(transcript),
                refinedText: storedRefinement(text, of: transcript),
                insertedCharacters: text.count
            )
        } catch {
            // Spec §9: the dictation is never lost -- keep the text for recovery.
            let message = "insert failed: \(error.localizedDescription)"
            transition(to: .failed(message: message, recoveredText: text))
            // And the row carries the same text the `.failed` state does, which is the half that
            // outlives the app being quit: `recoveredText` lives in memory until the next
            // dictation, this is where a paste that could not be delivered is still findable
            // tomorrow.
            await archive(
                .failed,
                audio: wav,
                rawTranscript: storedTranscript(transcript),
                refinedText: storedRefinement(text, of: transcript),
                failureMessage: message
            )
        }
    }

    /// What goes in `rawTranscript`: the transcript, or NULL when there was none.
    ///
    /// Empty means nothing was transcribed, and that is what the column's NULL says. An empty
    /// string stored instead would read back as "a transcript that happens to be empty", which is
    /// the same erasure D6 forbids one column over.
    private func storedTranscript(_ transcript: String) -> String? {
        transcript.isEmpty ? nil : transcript
    }

    /// What goes in `refinedText` (D6): what the refinement CHANGED, or nothing at all.
    ///
    /// Two cases collapse into NULL here, and both are the same statement -- *there is no second
    /// version of this text to show*. No refiner ran, or one ran and gave back what it was given:
    /// a model that echoed its input, or a `TranscriptRefiner` that fell back to the transcript
    /// because Ollama was down. Storing the copy would make `Voice` and a failed refinement
    /// indistinguishable in the archive, and would show the Raw/Refined lens two identical panes.
    ///
    /// `refinementSeconds` is what still separates them: set whenever the refiner was actually
    /// called, so a row with a refinement time and no refined text is a refinement that ran and
    /// changed nothing.
    ///
    /// Compared exactly, whitespace included, unlike `TranscriptRefiner.isUnchanged` which trims.
    /// The two answer different questions: that one asks whether the model did its job, this one
    /// asks whether the archive holds two different texts. A trailing newline the model added is
    /// genuinely what was pasted, and this is the record of what was pasted.
    private func storedRefinement(_ text: String, of transcript: String) -> String? {
        guard refinementSeconds != nil, text != transcript else { return nil }
        return text
    }

    /// One row for the dictation that just ended, from the facts fixed at its start and the ones
    /// this call carries. The only place a `HistoryRecord` is built.
    private func archive(
        _ outcome: DictationOutcome,
        audio: URL? = nil,
        rawTranscript: String? = nil,
        refinedText: String? = nil,
        insertedCharacters: Int = 0,
        failureMessage: String? = nil
    ) async {
        await recording.record(HistoryRecord(
            startedAt: startedAt,
            durationSeconds: recordedSeconds,
            outcome: outcome,
            modeKey: activeMode.key,
            modeName: activeMode.name,
            sttModel: activeMode.stt.model,
            // NULL when the mode had no refiner at all -- which is a different fact from "the
            // refiner did not run this time", and the reason both columns exist.
            llmModel: activeMode.llm.enabled ? activeMode.llm.model : nil,
            rawTranscript: rawTranscript,
            refinedText: refinedText,
            insertedCharacters: insertedCharacters,
            targetBundleID: target.bundleID,
            targetAppName: target.name,
            // D7: the name, never the path. `recordings/` moves the day `Storage` changes, and an
            // absolute path in a row survives nothing -- `HistoryRecord.audioURL(inRecordings:)`
            // is what puts the two halves back together, against whichever folder the caller has.
            audioFilename: audio?.lastPathComponent,
            transcriptionSeconds: transcriptionSeconds,
            refinementSeconds: refinementSeconds,
            failureMessage: failureMessage
        ))
    }

    /// The dictation is over: say what it inserted, then go back to idle in the same breath.
    ///
    /// Two transitions rather than one state carrying a flag, because the interface needs both
    /// facts and they are not the same fact: what this dictation did, and that the session is
    /// free again. A consumer that only cares about the second keeps working unchanged.
    private func complete(insertedCharacters: Int) {
        transition(to: .completed(insertedCharacters: insertedCharacters))
        transition(to: .idle)
    }

    /// Abandon the recording in progress: stop the microphone, transcribe nothing, insert
    /// nothing, go back to idle.
    ///
    /// The WAV is kept, and this is where lot 3 D8's promise is kept: the recording is already on
    /// disk while it runs, and the row written here is what makes it findable again -- so there is
    /// nothing to destroy, and therefore nothing to confirm before doing this. A cancelled
    /// dictation is a row with audio, a duration and no text at all.
    ///
    /// A no-op outside `.recording`, and not "best effort": once the pipeline has started, the
    /// transcription and the paste are already in flight and stopping the recorder would stop
    /// nothing. `lastTranscript` is deliberately untouched -- a cancelled dictation produced no
    /// text of its own, so the last dictation that DID produce text is still the right answer for
    /// a re-paste. That is the opposite of `finishRecording()`, which clears it: there a
    /// dictation really was transcribed, and reaching back past it into an older one would paste
    /// something Louis never asked for twice.
    public func cancel() async {
        guard state == .recording else { return }
        // The URL is used now, where lot 3 discarded it: it is the whole of what a cancelled
        // dictation leaves behind.
        let wav = recorder.stop()
        recordedSeconds = now().timeIntervalSince(startedAt)
        transition(to: .idle)
        await archive(.cancelled, audio: wav)
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
        let started = now()
        let text = await refiner.refine(transcript, with: activeMode)
        // Set for every call that LEFT, including the ones that came back with the transcript
        // unchanged -- see `storedRefinement`, which reads it to tell "no refiner" from "a
        // refiner that changed nothing".
        refinementSeconds = now().timeIntervalSince(started)
        return text
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange(newState)
    }
}
