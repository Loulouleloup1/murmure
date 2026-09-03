import AVFoundation
import XCTest
@testable import MurmureCore

/// Writes a real WAV so the session's empty-recording guard has a real file to read.
/// `frames: 0` produces the valid 0-frame file `AudioRecorder` returns on an instant stop.
private final class FakeRecorder: Recorder {
    var started = false
    var stopReturnsNil = false
    /// Writes bytes that are not audio at all, standing in for a truncated or corrupt recording.
    var stopReturnsUnreadableFile = false
    /// Thrown by `start()`, standing in for a denied microphone or a busy device.
    var startError: Error?
    /// Run inside `stop()`. The lot 4 tests use it to advance `ManualClock` by the length of the
    /// recording: nothing else moves that clock, so the seconds it adds here are exactly the
    /// seconds the microphone was live.
    var onStop: (() -> Void)?
    var lastFailure: Error?
    /// How many recordings actually began. One is the whole point of the concurrency test below:
    /// two would be two taps on one microphone.
    private(set) var startCount = 0
    /// How many times the recorder was asked to stop. A cancel that forgot to stop the
    /// microphone would leave the device running for the rest of the session.
    private(set) var stopCount = 0
    let frames: AVAudioFrameCount
    private var isRecording = false
    /// The WAV `stop()` returns. Read by the cancel tests: a cancel keeps the recording.
    let url: URL

    init(frames: AVAudioFrameCount = 16_000) {
        self.frames = frames
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
    }

    func start() throws {
        if let startError { throw startError }
        // Mirrors the real `AudioRecorder.start()`'s `guard sink == nil else { throw
        // .alreadyRecording }`. A fake that happily starts twice would let the concurrency test
        // below assert something the device does not actually do.
        guard !isRecording else { throw AlreadyRecording() }
        isRecording = true
        started = true
        startCount += 1
        // The real `AudioRecorder` opens its WAV when the recording starts and writes into it as
        // it goes, so the file exists from here on. Mirrored because the cancel tests ask whether
        // the recording SURVIVES a cancel -- a fake that only created the file in `stop()` would
        // answer that question with a stop that never happened.
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func stop() -> URL? {
        isRecording = false
        stopCount += 1
        onStop?()
        if stopReturnsNil { return nil }
        if stopReturnsUnreadableFile {
            try! Data("not audio".utf8).write(to: url)
            return url
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try! AVAudioFile(forWriting: url, settings: format.settings)
        if frames > 0 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            try! file.write(from: buffer)
        }
        return url
    }
}

/// A class, not a struct: the lot 4 T6 tests hold a reference after the session has run, to read
/// back what `language` and `initialPrompt` the pipeline actually handed the engine -- the only
/// way to prove those values, and never a compiled-in constant, reached it.
private final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var result: Result<String, Error>
    /// Run inside `transcribe`, before it answers -- so a `ManualClock` advanced here measures
    /// the transcription and nothing else, on the failing path as well as the succeeding one.
    var onCall: (() -> Void)?

    /// One dictation's worth of what `transcribe` was called with.
    struct Call: Equatable {
        var language: String
        var initialPrompt: String?
    }

    private let lock = NSLock()
    private var storage: [Call] = []

    init(result: Result<String, Error>, onCall: (() -> Void)? = nil) {
        self.result = result
        self.onCall = onCall
    }

    var calls: [Call] { lock.withLock { storage } }

    func transcribe(wav: URL, language: String, initialPrompt: String?) async throws -> String {
        lock.withLock { storage.append(Call(language: language, initialPrompt: initialPrompt)) }
        onCall?()
        return try result.get()
    }
}

/// A vocabulary that hands back a fixed list, however many times it is asked.
private struct FakeVocabulary: VocabularyProviding {
    var entries: [VocabularyEntry] = []
    func vocabulary() async -> [VocabularyEntry] { entries }
}

private final class SpyInserter: TextInserter, @unchecked Sendable {
    var inserted: [String] = []
    var error: Error?

    /// Where this inserter claims the text went.
    ///
    /// Defaults to the paste, which is what `PasteInserter` does under the shipped
    /// `PasteBehaviour.pasteIntoFrontmostApp` -- so every test written before the destination was
    /// a question keeps running the dictation it was written about, and only the tests that set
    /// this are about the other one.
    var delivery: InsertionDelivery = .pastedIntoFrontmostApp

    func insert(_ text: String) async throws -> InsertionDelivery {
        if let error { throw error }
        inserted.append(text)
        return delivery
    }
}

/// The refinement seam, recording what it was asked and when.
///
/// Defaults to `Voice`, the mode that refines nothing, so the lot 1 tests above keep running the
/// pipeline lot 1 shipped -- only their `init` call changed, never what they assert.
private final class SpyRefiner: DictationRefining, @unchecked Sendable {
    struct Calls: Equatable {
        var modeResolutions = 0
        /// Every transcript actually handed to the model. Empty is the assertion that matters:
        /// it is how a test proves a call never left.
        var refined: [String] = []
    }

    private let lock = NSLock()
    private var storage = Calls()
    private let mode: Mode
    private let answer: @Sendable (String) -> String

    init(mode: Mode = .voice, answer: @escaping @Sendable (String) -> String = { $0 }) {
        self.mode = mode
        self.answer = answer
    }

    var calls: Calls {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func modeForNewDictation() async -> Mode {
        lock.lock()
        storage.modeResolutions += 1
        lock.unlock()
        return mode
    }

    func refine(_ transcript: String, with mode: Mode) async -> String {
        lock.lock()
        storage.refined.append(transcript)
        lock.unlock()
        return answer(transcript)
    }
}

/// The archive seam, keeping every row it was handed and counting the target resolutions.
///
/// `target` is a `var` on purpose: a test moves it between the press that starts a dictation and
/// the one that stops it, which is how a target read at the START is told apart from one read at
/// the insertion. A double answering the same value whenever it is asked could not tell them
/// apart, and the mutation that moves that line would pass unnoticed.
private final class SpyRecording: DictationRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HistoryRecord] = []
    private var resolutions = 0
    private var storedTarget: DictationTarget

    init(target: DictationTarget = .unknown) {
        storedTarget = target
    }

    var target: DictationTarget {
        get { lock.withLock { storedTarget } }
        set { lock.withLock { storedTarget = newValue } }
    }

    /// Every row written, in order. The count is an assertion in its own right: one dictation is
    /// one row, and never two.
    var records: [HistoryRecord] { lock.withLock { storage } }

    var targetResolutions: Int { lock.withLock { resolutions } }

    /// `withLock` rather than the `lock()`/`unlock()` pair the older doubles in this file use:
    /// both methods below are `async`, where the pair is unavailable and warns.
    func targetForNewDictation() async -> DictationTarget {
        lock.withLock {
            resolutions += 1
            return storedTarget
        }
    }

    func record(_ dictation: HistoryRecord) async {
        lock.withLock { storage.append(dictation) }
    }
}

/// A clock that only moves when a test moves it, so the three durations a row carries are
/// assertable to the millisecond instead of to "greater than zero" -- which is what a real clock
/// would leave, and what would let a duration measured over the wrong span pass.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// Parsed rather than built by arithmetic on `Date()`, the same rule `HistoryStoreTests`
    /// follows: the stored form carries milliseconds and a fixture that cannot be read back in
    /// the format the schema promises is not a fixture.
    init(from iso: String = "2026-09-01T14:42:00.000Z") {
        current = HistoryTimestamp.date(from: iso)!
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private struct TestError: Error {}

/// Stands in for `AudioRecorder.Failure.alreadyRecording`, which lives in the app target and
/// cannot be imported here. `LocalizedError` so the message the session builds out of it is a
/// stable string an assertion can pin, rather than Foundation's "error 1" boilerplate.
private struct AlreadyRecording: LocalizedError {
    var errorDescription: String? { "already recording" }
}

final class DictationSessionTests: XCTestCase {
    func testFullToggleCycleInsertsTranscriptAndReturnsToIdle() async {
        let inserter = SpyInserter()
        let recorder = FakeRecorder()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("bonjour murmure")),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle() // start
        let recordingState = await session.state
        XCTAssertEqual(recordingState, .recording)
        XCTAssertTrue(recorder.started)
        await session.toggle() // stop + pipeline
        XCTAssertEqual(inserter.inserted, ["bonjour murmure"])
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
    }

    func testTranscriberFailureLandsInFailedStateWithNoInsert() async {
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .failure(TestError())),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertTrue(inserter.inserted.isEmpty)
        guard case .failed(_, let recovered) = await session.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertNil(recovered)
    }

    func testInsertFailureKeepsTranscriptForRecovery() async {
        let inserter = SpyInserter()
        inserter.error = TestError()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("texte précieux")),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard case .failed(_, let recovered) = await session.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertEqual(recovered, "texte précieux") // never lose a dictation (spec §9)
    }

    // Ruling L7, first half.
    func testAWriteFailureReportsItsOwnReasonNotTheGenericOne() async {
        struct DiskFull: LocalizedError { var errorDescription: String? { "disk full" } }
        let recorder = FakeRecorder()
        recorder.stopReturnsNil = true
        recorder.lastFailure = DiskFull()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard case .failed(let message, _) = await session.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertTrue(message.contains("disk full"), "got \(message)")
    }

    // Ruling L7, second half: an empty recording is a no-op, never a transcription.
    func testAnEmptyRecordingReturnsToIdleWithoutTranscribing() async {
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(frames: 0),
            transcriber: FakeTranscriber(result: .success("hallucination sur du silence")),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertTrue(inserter.inserted.isEmpty, "silence must never reach the pasteboard")
    }

    /// Same ruling, third case: a file that cannot be read at all is NOT an empty recording. The
    /// two look identical to a `try?`, and reporting a corrupt WAV as "nothing was said" is the
    /// silent failure the two cases above exist to avoid.
    func testAnUnreadableRecordingIsReportedInsteadOfPassingForSilence() async {
        let recorder = FakeRecorder()
        recorder.stopReturnsUnreadableFile = true
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard case .failed = await session.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    /// A dictation that produced no text must not leave the previous one behind as "the last
    /// transcript": the recovery menu item would then paste a transcript from two dictations ago
    /// into whatever is focused now.
    func testAFailedDictationDoesNotLeaveThePreviousTranscriptAsTheLastOne() async {
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("première dictée")),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        let afterSuccess = await session.lastTranscript
        XCTAssertEqual(afterSuccess, "première dictée")

        let failing = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .failure(TestError())),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await failing.toggle()
        await failing.toggle()
        let afterFailure = await failing.lastTranscript
        XCTAssertNil(afterFailure)
    }

    /// The state changes are the only thing the menu bar ever sees, so the sequence itself is the
    /// contract -- not just the state the session happens to end on.
    func testEveryTransitionIsReportedInOrder() async {
        let states = StateLog()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("bonjour")),
            inserter: SpyInserter(), refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(states.values, [
            .recording, .transcribing, .inserting,
            // "bonjour" -- 7 characters really pasted. Lot 3 T2 inserted this state between the
            // insertion and the idle: without it nothing downstream can tell a dictation that
            // landed from one that had nothing to say.
            .completed(insertedCharacters: 7),
            .idle,
        ])
    }

    /// An actor is re-entrant: while `toggle()` awaits the transcriber it releases the executor,
    /// so a third press really does land inside the running pipeline. It must be ignored rather
    /// than start a second recording on top of the first.
    func testAPressDuringTheRunningPipelineIsIgnored() async {
        let transcriber = GatedTranscriber()
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: transcriber,
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle() // start
        async let pipeline: Void = session.toggle() // stop; blocks inside the transcriber
        await transcriber.waitUntilTranscribing()

        await session.toggle() // the stray press
        let midState = await session.state
        XCTAssertEqual(midState, .transcribing)

        await transcriber.finish(with: "bonjour")
        await pipeline
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
    }

    // MARK: - Lot 2: the refinement seam

    /// The constraint the whole lot is measured against. `Voice` is the default mode and the
    /// daily driver, so its transcript reaches the inserter as it left the transcriber -- padding
    /// and interior spacing included -- and the model is never called at all. Not "called and
    /// expected to change nothing": never called.
    func testVoiceInsertsTheTranscriptByteForByteAndNeverReachesTheModel() async {
        let raw = "  bonjour   Murmure\n"
        let inserter = SpyInserter()
        let refiner = SpyRefiner(mode: .voice, answer: { _ in "reformulé" })
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success(raw)),
            inserter: inserter, refiner: refiner, recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(inserter.inserted, [raw])
        XCTAssertEqual(refiner.calls.refined, [], "Voice must not reach the model")
    }

    /// R-T5-2: the application Louis was looking at when he pressed is what picks the mode, so
    /// the resolution happens on the toggle that STARTS -- and once, not again on the one that
    /// stops.
    func testTheModeIsResolvedWhenTheRecordingStartsNotWhenItStops() async {
        let refiner = SpyRefiner()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("bonjour")),
            inserter: SpyInserter(), refiner: refiner, recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle() // start
        XCTAssertEqual(refiner.calls.modeResolutions, 1, "the mode is resolved at the start")
        await session.toggle() // stop + pipeline
        XCTAssertEqual(refiner.calls.modeResolutions, 1, "and not resolved a second time")
    }

    /// The corollary of the same ruling: there is no dictation to pick a mode for, so a refused
    /// microphone does not pay for a read of the modes folder.
    func testAMicrophoneThatRefusesToStartResolvesNoMode() async {
        let recorder = FakeRecorder()
        recorder.startError = TestError()
        let refiner = SpyRefiner()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: refiner, recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        guard case .failed = await session.state else { return XCTFail("expected failed state") }
        XCTAssertEqual(refiner.calls.modeResolutions, 0)
    }

    /// A mode with an LLM: what the model answered is what gets pasted, and what a re-paste will
    /// offer -- the raw transcript is not the dictation any more once it has been refined.
    func testAModeWithAnLLMInsertsTheRefinedTextRatherThanTheRawOne() async {
        let inserter = SpyInserter()
        let refiner = SpyRefiner(mode: .prompt, answer: { "reformulé : \($0)" })
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("euh bonjour")),
            inserter: inserter, refiner: refiner, recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(refiner.calls.refined, ["euh bonjour"])
        XCTAssertEqual(inserter.inserted, ["reformulé : euh bonjour"])
        let last = await session.lastTranscript
        XCTAssertEqual(last, "reformulé : euh bonjour")
    }

    /// R-T5-3. The refinement is its own state and not a longer hourglass: on the worst real case
    /// measured it lasts 57.5 s, and an icon that cannot tell "the model is working" from "the app
    /// is stuck" is the same as no icon.
    func testARefinementIsItsOwnStateInTheSequence() async {
        let states = StateLog()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("euh bonjour")),
            inserter: SpyInserter(), refiner: SpyRefiner(mode: .prompt),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(states.values, [
            .recording, .transcribing, .refining, .inserting,
            .completed(insertedCharacters: 11), // "euh bonjour", unchanged by the spy refiner
            .idle,
        ])
    }

    /// Whisper answers silence with an empty transcript, and the refiner's anti-refusal rule is a
    /// fraction of the transcript's LENGTH -- so against zero, every answer clears it. Whatever
    /// the model says to an empty prompt would be pasted into whatever Louis has focused as if he
    /// had dictated it. The call never leaves.
    func testAnEmptyTranscriptIsNeverSentToTheModel() async {
        let inserter = SpyInserter()
        let refiner = SpyRefiner(mode: .prompt, answer: { _ in "Bien sûr ! Voici le texte corrigé :" })
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("")),
            inserter: inserter, refiner: refiner, recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(refiner.calls.refined, [])
        XCTAssertEqual(inserter.inserted, [""], "a fabricated sentence must never reach the paste")
    }

    /// The same nothing, spelled with characters. `isEmpty` alone would let a transcript of one
    /// newline through, and nobody can see the difference on screen.
    func testATranscriptOfNothingButWhitespaceIsNeverSentToTheModelEither() async {
        let inserter = SpyInserter()
        let refiner = SpyRefiner(mode: .prompt, answer: { _ in "Voici le texte corrigé :" })
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success(" \n \t ")),
            inserter: inserter, refiner: refiner, recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(refiner.calls.refined, [])
        XCTAssertEqual(inserter.inserted, [" \n \t "])
    }

    /// The one window this lot opened. Resolving the mode is an `await` inside the branch lot 1
    /// kept atomic, and `state` is still `.idle` all the way through it -- so a second press
    /// landing inside is read as another START, not as a stop. `GatedRefiner` holds that window
    /// open on purpose; in production it is only ever as wide as a read of four small files, and
    /// the argument that a human cannot press twice inside it is a timing argument, not a lock.
    ///
    /// What must hold whatever the timing: exactly one recording, and a session that ends where
    /// the press that started it meant to leave it -- `.recording`.
    ///
    /// The `.failed` in the asserted sequence is real and deliberately NOT fixed. The second press
    /// is refused by the recorder, reports it, and the first press then overwrites it with
    /// `.recording` when it resumes -- so the menu bar can show a failure flash before the
    /// recording icon. It is benign, and pinning it here is what makes it a decision instead of a
    /// surprise: the day someone reorders these lines, this assertion tells them what they moved.
    func testASecondPressInsideTheModeResolutionCannotStartASecondRecording() async {
        let states = StateLog()
        let recorder = FakeRecorder()
        let refiner = GatedRefiner()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: refiner,
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        async let firstPress: Void = session.toggle()
        await refiner.waitUntilResolving() // the first press is parked inside the window

        await session.toggle() // the second press, inside it

        await refiner.finish()
        await firstPress

        let finalState = await session.state
        XCTAssertEqual(finalState, .recording)
        XCTAssertEqual(recorder.startCount, 1, "one press, one recording")
        let resolutions = await refiner.resolutions
        XCTAssertEqual(resolutions, 1, "the refused press resolves no mode")
        XCTAssertEqual(states.values, [
            .failed(message: "mic start failed: already recording", recoveredText: nil),
            .recording,
        ])
    }

    // MARK: - Lot 3: what a dictation ended up inserting, and abandoning one

    /// The state the whole notch rests on. A dictation that pasted text and one that pasted
    /// nothing both used to end in `.idle`, so the only surface Murmure has could not tell them
    /// apart -- and a green flash on `.idle` would congratulate Louis for a dictation that
    /// inserted nothing.
    func testASuccessfulDictationSaysHowManyCharactersItInserted() async {
        let states = StateLog()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("bonjour murmure")),
            inserter: SpyInserter(), refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertTrue(
            states.values.contains(.completed(insertedCharacters: 15)),
            "got \(states.values)")
    }

    /// The other half of the same fact, and the one that gives the notch its "nothing heard":
    /// pressing the hotkey twice in a row records a valid 0-frame WAV, transcribes nothing and
    /// pastes nothing. Zero characters, reported as such -- not a silent return to idle.
    func testAnEmptyRecordingCompletesWithZeroCharactersInsteadOfGoingIdleInSilence() async {
        let states = StateLog()
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(frames: 0),
            transcriber: FakeTranscriber(result: .success("hallucination sur du silence")),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(states.values, [.recording, .completed(insertedCharacters: 0), .idle])
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    /// The third silence: the recording had audio, Whisper returned nothing. `PasteInserter`
    /// refuses an empty string, so nothing reaches the pasteboard -- and the count says so
    /// rather than claiming a success of zero characters.
    func testATranscriptWhisperReturnedEmptyCompletesWithZeroCharacters() async {
        let states = StateLog()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("")),
            inserter: SpyInserter(), refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertTrue(
            states.values.contains(.completed(insertedCharacters: 0)),
            "got \(states.values)")
    }

    /// What is counted is what was INSERTED, so under a mode with an LLM it is the refined text
    /// -- the raw transcript is not what landed, and on a refinement that expands a mumble into a
    /// paragraph the two numbers are nowhere near each other.
    func testTheCountIsTheRefinedTextNotTheRawTranscript() async {
        let states = StateLog()
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("euh bonjour")),
            inserter: inserter,
            refiner: SpyRefiner(mode: .prompt, answer: { "reformulé : \($0)" }),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(inserter.inserted, ["reformulé : euh bonjour"]) // 23 characters, not 11
        XCTAssertTrue(
            states.values.contains(.completed(insertedCharacters: 23)),
            "got \(states.values)")
    }

    /// Cancel (lot 3 D8): the recording is abandoned, and abandoned means nothing downstream runs
    /// -- the transcriber here answers with a failure, so a cancel that transcribed anyway would
    /// end in `.failed` instead of `.idle`.
    func testCancellingARecordingReturnsToIdleWithoutTranscribingOrInserting() async {
        let states = StateLog()
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .failure(TestError())),
            inserter: inserter, refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.cancel()
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(states.values, [.recording, .cancelled, .idle])
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    /// **The machine has to SAY the dictation was abandoned, in the same shape `.completed`
    /// already uses**: one state that names what happened, then the `.idle` that says the session
    /// is free again, both in the same breath.
    ///
    /// Without the first of those, a cancel is a `.recording` followed by an `.idle` -- which is
    /// the state the app spends all day in -- and no surface downstream can tell it from a
    /// dictation that ended, a launch, or a press macOS never delivered. The notch would simply
    /// retract, and the one gesture whose whole feedback is that something STOPS would have no
    /// feedback at all.
    func testACancelSaysWhatHappenedBeforeItSaysTheSessionIsFree() async {
        // Given
        let states = StateLog()
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: FakeTranscriber(result: .success("bonjour")),
            inserter: SpyInserter(), refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.toggle()

        // When
        await session.cancel()

        // Then
        XCTAssertEqual(states.values.suffix(2), [.cancelled, .idle])
    }

    /// The microphone really stops. Without this the device would stay live for the rest of the
    /// session with nothing on screen saying so -- the worst possible outcome for a cancel.
    func testCancellingStopsTheMicrophone() async {
        let recorder = FakeRecorder()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.cancel()
        XCTAssertEqual(recorder.stopCount, 1)
    }

    /// And the audio is KEPT (D8). It is already on disk while the recording runs and lot 4 makes
    /// it a history entry, so there is nothing to destroy here -- which is also why a cancel asks
    /// for no confirmation.
    func testCancellingKeepsTheRecordingOnDisk() async {
        let recorder = FakeRecorder()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.url.path))
        try? FileManager.default.removeItem(at: recorder.url)
    }

    /// A cancel with nothing to cancel does nothing at all -- not even an `.idle` no consumer
    /// asked for. The button only exists while a dictation is on screen, but the method is public
    /// and a stray call must not retract a notch, stop a device or clear a warning.
    func testACancelWithNoRecordingRunningDoesNothing() async {
        let states = StateLog()
        let recorder = FakeRecorder()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(),
            recording: SpyRecording(), vocabulary: FakeVocabulary(),
            onStateChange: { states.append($0) }
        )
        await session.cancel()
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(states.values, [])
        XCTAssertEqual(recorder.stopCount, 0)
    }

    /// The same guard where it actually costs something: once the pipeline is running, the
    /// transcription is in flight and the paste is about to happen. Stopping the recorder there
    /// would stop nothing and returning to `.idle` would let the next press start a second
    /// recording under a running insertion.
    func testACancelDuringTheRunningPipelineIsIgnored() async {
        let transcriber = GatedTranscriber()
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: transcriber,
            inserter: inserter, refiner: SpyRefiner(), recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle() // start
        async let pipeline: Void = session.toggle() // stop; blocks inside the transcriber
        await transcriber.waitUntilTranscribing()

        await session.cancel() // the stray cancel
        let midState = await session.state
        XCTAssertEqual(midState, .transcribing)

        await transcriber.finish(with: "bonjour")
        await pipeline
        XCTAssertEqual(inserter.inserted, ["bonjour"], "the dictation ran to its end")
    }

    /// A cancelled dictation produced no text of its own, so the last dictation that DID produce
    /// text is still the right answer for a re-paste. The opposite of a dictation that runs and
    /// fails, which clears it -- there the pipeline really ran, and reaching back past it would
    /// paste an older transcript a second time.
    func testCancellingLeavesTheLastTranscriptOfTheDictationBeforeIt() async {
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("première dictée")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        await session.toggle() // a second dictation...
        await session.cancel() // ...abandoned
        let last = await session.lastTranscript
        XCTAssertEqual(last, "première dictée")
    }

    // MARK: - Lot 4: what the dictation leaves behind

    /// The whole of T4 in one assertion: a dictation that ran end to end leaves exactly one row.
    /// Not zero -- an archive that misses a dictation is the same lost text as a wrong one -- and
    /// not one per stage, which is what a record emitted from `transition` would produce.
    func testADictationWritesExactlyOneRecord() async {
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(recording.records.count, 1)
    }

    /// The success path, column by column: what was heard, what was inserted, and how much of it.
    func testASuccessfulDictationIsRecordedAsInsertedWithItsCharacterCount() async {
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .inserted)
        XCTAssertEqual(row.insertedCharacters, 19) // "une phrase inventée"
        XCTAssertEqual(row.rawTranscript, "une phrase inventée")
        XCTAssertEqual(row.modeKey, Mode.voice.key)
        XCTAssertEqual(row.modeName, Mode.voice.name)
        XCTAssertEqual(row.sttModel, Mode.voice.stt.model)
        XCTAssertNil(row.failureMessage)
    }

    /// The line this task exists to move: the raw transcript used to be overwritten by the
    /// refined text, and the archive keeps both. `insertedCharacters` counts what landed, which
    /// is the refined one.
    func testTheRawTranscriptIsKeptBesideTheRefinedTextRatherThanOverwrittenByIt() async {
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("euh une phrase inventée")),
            inserter: SpyInserter(),
            refiner: SpyRefiner(mode: .prompt, answer: { "reformulé : \($0)" }),
            recording: recording, vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.rawTranscript, "euh une phrase inventée")
        XCTAssertEqual(row.refinedText, "reformulé : euh une phrase inventée")
        XCTAssertEqual(row.insertedCharacters, 35)
        XCTAssertEqual(row.llmModel, Mode.prompt.llm.model)
    }

    /// D6, and the case it was written for: a refinement that could not happen returns the raw
    /// transcript, and the archive must not store that as a refinement. NULL, never a copy --
    /// otherwise a mode that never refines and a refiner that fell back read identically, and the
    /// Raw/Refined lens shows two identical panes.
    ///
    /// What separates them is `refinementSeconds`: a call really did leave.
    func testARefinementThatChangedNothingStoresTheRawTranscriptAndNoRefinedText() async {
        let clock = ManualClock()
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(),
            // The shape of a `TranscriptRefiner` that fell back: Ollama was down, so what comes
            // back is exactly what went in.
            refiner: SpyRefiner(mode: .prompt, answer: { clock.advance(3); return $0 }),
            recording: recording, vocabulary: FakeVocabulary(),
            now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.rawTranscript, "une phrase inventée")
        XCTAssertNil(row.refinedText, "a fallback is not a refinement")
        XCTAssertEqual(row.refinementSeconds, 3, "and it is still a refiner that ran")
    }

    /// The other half of the same rule: `Voice` never calls the model, so there is no refinement
    /// time either -- which is what makes the pair above readable.
    func testAModeWithNoRefinerRecordsNoLanguageModelAndNoRefinementTime() async {
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(), refiner: SpyRefiner(mode: .voice), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertNil(row.llmModel)
        XCTAssertNil(row.refinementSeconds)
        XCTAssertNil(row.refinedText)
    }

    /// Ruling L7's second silence: two presses in a row record a valid 0-frame WAV. It is a
    /// dictation that happened and heard nothing -- a row, with its duration and its audio, and
    /// no text at all. No row here would make the two presses invisible.
    func testAnEmptyRecordingIsRecordedAsNothingHeardWithItsAudioAndNoText() async {
        let clock = ManualClock()
        let recorder = FakeRecorder(frames: 0)
        recorder.onStop = { clock.advance(4) }
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("hallucination sur du silence")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .nothingHeard)
        XCTAssertEqual(row.durationSeconds, 4)
        XCTAssertEqual(row.audioFilename, recorder.url.lastPathComponent)
        XCTAssertNil(row.rawTranscript)
        XCTAssertNil(row.transcriptionSeconds, "nothing was transcribed")
        XCTAssertEqual(row.insertedCharacters, 0)
    }

    /// The third silence: the recording had audio and Whisper returned nothing. A transcription
    /// really ran -- so it has a time -- and there is still no text to store.
    func testATranscriptWhisperReturnedEmptyIsRecordedAsNothingHeard() async {
        let clock = ManualClock()
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success(""), onCall: { clock.advance(2) }),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .nothingHeard)
        XCTAssertNil(row.rawTranscript, "an empty string is not a transcript")
        XCTAssertEqual(row.transcriptionSeconds, 2)
        XCTAssertEqual(row.insertedCharacters, 0)
    }

    /// A failure is a row, and the row carries the sentence the notch showed. Without it a failed
    /// dictation reads as "something went wrong" for ever.
    func testAFailedTranscriptionIsRecordedWithItsMessageAndItsAudio() async {
        struct ModelMissing: LocalizedError { var errorDescription: String? { "model missing" } }
        let recorder = FakeRecorder()
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .failure(ModelMissing())),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.failureMessage, "transcription failed: model missing")
        XCTAssertEqual(row.audioFilename, recorder.url.lastPathComponent, "the WAV is still there")
        XCTAssertNil(row.rawTranscript)
    }

    /// The failure that costs the most, and the one spec §9 is about: the text existed and the
    /// paste refused it. The row carries both -- the message, and the text that could not be
    /// delivered. `AppState.recoveredText` holds the same text until the next dictation; this is
    /// the copy that is still there tomorrow.
    func testAFailedInsertionIsRecordedWithItsMessageAndTheTextItCouldNotDeliver() async {
        struct NoAccessibility: LocalizedError { var errorDescription: String? { "no access" } }
        let inserter = SpyInserter()
        inserter.error = NoAccessibility()
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("texte inventé et précieux")),
            inserter: inserter, refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.failureMessage, "insert failed: no access")
        XCTAssertEqual(row.rawTranscript, "texte inventé et précieux")
        XCTAssertEqual(row.insertedCharacters, 0, "nothing landed")
    }

    /// Ruling L7's first half, one layer down: the buffers never reached the disk, so there is no
    /// WAV to name. A filename here would point at a file that was never written.
    func testARecordingThatNeverReachedTheDiskIsRecordedWithNoAudio() async {
        struct DiskFull: LocalizedError { var errorDescription: String? { "disk full" } }
        let clock = ManualClock()
        let recorder = FakeRecorder()
        recorder.stopReturnsNil = true
        recorder.lastFailure = DiskFull()
        recorder.onStop = { clock.advance(4) }
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertNil(row.audioFilename)
        XCTAssertEqual(row.failureMessage, "recording failed: disk full")
        XCTAssertEqual(row.durationSeconds, 4, "the recording still happened")
    }

    /// A corrupt header is not an absent recording. The file is on disk, so the row points at it
    /// -- that is what lets it be found and salvaged rather than orphaned.
    func testAnUnreadableRecordingIsRecordedWithItsAudioSoTheFileCanStillBeFound() async {
        let recorder = FakeRecorder()
        recorder.stopReturnsUnreadableFile = true
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.audioFilename, recorder.url.lastPathComponent)
        XCTAssertNil(row.rawTranscript)
    }

    /// Lot 3 D8's promise, kept. A cancel destroys nothing and asks nothing, on the grounds that
    /// lot 4 would make the recording recoverable -- so a cancelled dictation is a row naming the
    /// WAV that is still on disk, with a duration and no text of any kind.
    func testACancelledDictationIsRecordedWithItsAudioAndNoTranscript() async {
        let clock = ManualClock()
        let recorder = FakeRecorder()
        recorder.onStop = { clock.advance(4) }
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.cancel()
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(recording.records.count, 1)
        XCTAssertEqual(row.outcome, .cancelled)
        XCTAssertEqual(row.audioFilename, recorder.url.lastPathComponent)
        XCTAssertEqual(row.durationSeconds, 4)
        XCTAssertNil(row.rawTranscript)
        XCTAssertNil(row.refinedText)
        XCTAssertNil(row.transcriptionSeconds)
        XCTAssertEqual(row.insertedCharacters, 0)
    }

    /// A stray cancel outside a recording is not a dictation, so it archives nothing. The method
    /// is public: a row here would be a dictation in the history that never happened.
    func testACancelWithNoRecordingRunningWritesNoRecord() async {
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.cancel()
        XCTAssertEqual(recording.records, [])
    }

    /// The same line the mode resolution already draws: a microphone that refused to start is not
    /// a dictation. No mode is resolved and no row is written.
    ///
    /// **The target IS now read, and that is a deliberate narrowing rather than a regression.**
    /// Until lot 4 it was read after a successful start, and this test asserted zero. The
    /// start-refusal guard needs it before the microphone opens, so a refused microphone pays for
    /// one read of the frontmost application -- a property access on `NSWorkspace`. What the old
    /// assertion was really protecting is the expensive read, and that is asserted here directly:
    /// the modes folder is still never touched.
    func testAMicrophoneThatRefusesToStartResolvesNoModeAndWritesNoRecord() async {
        let recorder = FakeRecorder()
        recorder.startError = TestError()
        let recording = SpyRecording()
        let refiner = SpyRefiner()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: refiner, recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        XCTAssertEqual(recording.records, [])
        XCTAssertEqual(refiner.calls.modeResolutions, 0, "the modes folder is not read")
        XCTAssertEqual(recording.targetResolutions, 1, "the guard needs it before the mic opens")
    }

    // MARK: - Lot 4: the dictation Murmure's own window would have swallowed

    /// **The refusal that D2 made necessary.** Murmure's window flips the activation policy to
    /// `.regular`, so for the first time in the app's life Murmure can be the frontmost
    /// application -- and the surface that puts it there is History, which is the pane Louis will
    /// open every day. A hotkey pressed there used to run the whole pipeline and fail at the very
    /// end, in `PasteInserter`.
    ///
    /// **`startCount` is the assertion, not the state.** A version that opened the microphone,
    /// noticed, and closed it again would reach `.failed` too, and a test reading only the state
    /// would call that a pass -- while Louis had thirty seconds of speech go nowhere.
    func testAPressWhileMurmureIsInFrontOpensNoMicrophoneAtAll() async {
        let states = StateLog()
        let recorder = FakeRecorder()
        let refiner = SpyRefiner()
        let recording = SpyRecording(
            target: DictationTarget(
                bundleID: "com.louiscourcier.Murmure", name: "Murmure", isSelf: true))
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("jamais atteint")),
            inserter: SpyInserter(), refiner: refiner, recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { states.append($0) }
        )

        await session.toggle()

        XCTAssertEqual(recorder.startCount, 0, "the microphone must never have opened")
        XCTAssertEqual(recorder.stopCount, 0, "and therefore never have been closed either")
        XCTAssertFalse(recorder.started)
        XCTAssertEqual(refiner.calls.modeResolutions, 0, "nothing downstream of the guard ran")
        XCTAssertEqual(recording.records, [], "no dictation happened, so there is no row")
        let state = await session.state
        guard case .failed(let message, let recovered) = state else {
            return XCTFail("expected a refusal, got \(state)")
        }
        XCTAssertNil(recovered, "there is no text to recover -- he never spoke")
        // The message has to say what to DO. A refusal naming only what went wrong leaves him
        // pressing the same key again.
        XCTAssertTrue(
            message.lowercased().contains("click into the app"),
            "the refusal must tell him what to do, got: \(message)")
        XCTAssertEqual(states.values.count, 1, "one state change, and it is the refusal")
    }

    /// The other half, and the one that stops the guard from being "refuse everything": an
    /// ordinary press, with an ordinary application in front, still opens the microphone.
    /// Without this a guard inverted by a stray `!` would pass the test above and break dictation
    /// entirely.
    func testAPressWithAnyOtherAppInFrontStillStartsRecording() async {
        let recorder = FakeRecorder()
        let recording = SpyRecording(
            target: DictationTarget(bundleID: "com.example.editor", name: "Éditeur"))
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )

        await session.toggle()

        XCTAssertEqual(recorder.startCount, 1)
        let state = await session.state
        XCTAssertEqual(state, .recording)
    }

    /// `.unknown` is what the app answers when nothing is in front or nothing could be read, and
    /// it must not be mistaken for Murmure. Reading a missing bundle identifier as "it is us"
    /// would refuse every dictation started from a desktop with no frontmost application.
    func testAnUnknownTargetIsNotReadAsMurmure() async {
        let recorder = FakeRecorder()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: SpyRecording(target: .unknown),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )

        await session.toggle()

        XCTAssertEqual(recorder.startCount, 1)
    }

    /// A press landing inside the running pipeline is ignored, and the ignoring has to reach the
    /// archive too: two rows for one dictation would show Louis a history of dictations he never
    /// made.
    func testAStrayPressInsideTheRunningPipelineDoesNotAddASecondRecord() async {
        let transcriber = GatedTranscriber()
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: transcriber,
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        async let pipeline: Void = session.toggle()
        await transcriber.waitUntilTranscribing()

        await session.toggle() // the stray press
        await session.cancel() // and a stray cancel, which is ignored for the same reason

        await transcriber.finish(with: "une phrase inventée")
        await pipeline
        XCTAssertEqual(recording.records.count, 1)
    }

    /// The application Louis was looking at when he SPOKE, which is not necessarily the one the
    /// text lands in: the spy answers one thing at the start and another by the time the paste
    /// happens, and the row has to carry the first. Reading it at insertion instead is a
    /// one-line change that nothing else in the suite would notice.
    func testTheTargetApplicationIsTheOneInFrontWhenTheRecordingStarted() async {
        let recording = SpyRecording(
            target: DictationTarget(bundleID: "com.example.editor", name: "Éditeur"))
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle() // start -- Louis is in his editor
        XCTAssertEqual(recording.targetResolutions, 1, "the target is read at the start")
        recording.target = DictationTarget(bundleID: "com.example.chat", name: "Chat")

        await session.toggle() // stop + pipeline -- he has switched to a chat window since
        XCTAssertEqual(recording.targetResolutions, 1, "and not read a second time")
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.targetBundleID, "com.example.editor")
        XCTAssertEqual(row.targetAppName, "Éditeur")
    }

    /// The three durations measure three different spans, and the recording's own is the one it
    /// is easiest to get wrong: it ends when the recorder stops, not when the paste lands. Here
    /// the pipeline costs 5 seconds after a 4-second recording, so a duration that swallowed the
    /// pipeline would read 9.
    func testTheDurationIsTheRecordingAndTheOtherTwoAreThePipeline() async {
        let clock = ManualClock()
        let recorder = FakeRecorder()
        recorder.onStop = { clock.advance(4) }
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(
                result: .success("une phrase inventée"), onCall: { clock.advance(2) }),
            inserter: SpyInserter(),
            refiner: SpyRefiner(
                mode: .prompt, answer: { _ in clock.advance(3); return "reformulé" }),
            recording: recording, vocabulary: FakeVocabulary(),
            now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.durationSeconds, 4)
        XCTAssertEqual(row.transcriptionSeconds, 2)
        XCTAssertEqual(row.refinementSeconds, 3)
    }

    /// `startedAt` is when the recording began, not when it ended and not when the row was
    /// written -- the history is read newest-first on this column, and a dictation stamped at the
    /// end of its own pipeline would sort past the one that followed it.
    func testTheRecordIsStampedWhenTheRecordingStartedNotWhenItEnded() async {
        let clock = ManualClock()
        let started = clock.now
        let recorder = FakeRecorder()
        recorder.onStop = { clock.advance(4) }
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(
                result: .success("une phrase inventée"), onCall: { clock.advance(2) }),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.startedAt, started)
    }

    /// D7: what is stored is a filename, never a path. The row has to resolve against whatever
    /// folder `recordings/` turns out to be -- a temporary one here, Louis's real one in the app
    /// -- and `HistoryStore.insert` refuses anything else outright.
    func testTheAudioIsRecordedAsAFilenameRelativeToRecordings() async {
        let recorder = FakeRecorder()
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("une phrase inventée")),
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.audioFilename, recorder.url.lastPathComponent)
        XCTAssertFalse(row.audioFilename?.contains("/") ?? true, "a path, not a filename")
        let base = URL(fileURLWithPath: "/somewhere/else/recordings")
        XCTAssertEqual(
            row.audioURL(inRecordings: base),
            base.appendingPathComponent(recorder.url.lastPathComponent))
    }

    /// Two dictations through ONE session, which is how Murmure is actually used -- and the
    /// second row carries none of the first one's numbers. The three timings are per-dictation
    /// state on an actor that lives for the whole process: a refinement time left behind by the
    /// dictation before would make a dictation that never reached the model read as one that did.
    func testASecondDictationThroughTheSameSessionInheritsNoneOfTheFirstOnesTimings() async {
        let clock = ManualClock()
        let recorder = FakeRecorder()
        recorder.onStop = { clock.advance(4) }
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(
                result: .success("une phrase inventée"), onCall: { clock.advance(2) }),
            inserter: SpyInserter(),
            refiner: SpyRefiner(
                mode: .prompt, answer: { clock.advance(3); return "reformulé : \($0)" }),
            recording: recording, vocabulary: FakeVocabulary(),
            now: { clock.now }, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        // The second one never reaches the disk, so it never reaches a transcription or a
        // refinement either -- and its row must say so.
        recorder.stopReturnsNil = true
        await session.toggle()
        await session.toggle()

        XCTAssertEqual(recording.records.count, 2)
        XCTAssertEqual(recording.records.first?.refinementSeconds, 3)
        let second = recording.records.last
        XCTAssertNil(second?.transcriptionSeconds, "the first dictation's, inherited")
        XCTAssertNil(second?.refinementSeconds, "the first dictation's, inherited")
        XCTAssertEqual(second?.durationSeconds, 4, "its own recording, not both of them")
    }

    // MARK: - Lot 4 T6: the vocabulary seam

    /// `language` is `activeMode.stt.language`, read at the moment of the call -- never the
    /// compiled-in `"fr"` `WhisperKitEngine` used to hard-code. A mode with a different language
    /// is what proves the value travelled rather than merely compiling.
    func testTheLanguageReachingTheTranscriberIsTheActiveModesNotAConstant() async {
        var englishMode = Mode.voice
        englishMode.stt = .init(model: englishMode.stt.model, language: "en")
        let transcriber = FakeTranscriber(result: .success("hello"))
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: transcriber,
            inserter: SpyInserter(), refiner: SpyRefiner(mode: englishMode),
            recording: SpyRecording(), vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        XCTAssertEqual(transcriber.calls.map(\.language), ["en"])
    }

    /// `initialPrompt` is `VocabularyPrompt.build(from:)`'s answer for the entries the provider
    /// handed back -- not built again here, and not a paraphrase of it: the two must be the exact
    /// same value, or a change to the prompt's shape could pass this test while the engine hears
    /// something else.
    func testTheInitialPromptIsVocabularyPromptBuiltFromTheProvidersEntries() async {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        let transcriber = FakeTranscriber(result: .success("open claude code"))
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: transcriber,
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: SpyRecording(),
            vocabulary: FakeVocabulary(entries: entries), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        XCTAssertEqual(
            transcriber.calls.map(\.initialPrompt), [VocabularyPrompt.build(from: entries)])
    }

    /// The other half of the same claim: an empty vocabulary must reach the engine as `nil`, not
    /// as an empty string -- `VocabularyPrompt.build(from:)`'s own distinction, and the one this
    /// pipeline must not flatten on the way through.
    func testTheInitialPromptIsNilForAnEmptyVocabulary() async {
        let transcriber = FakeTranscriber(result: .success("bonjour"))
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: transcriber,
            inserter: SpyInserter(), refiner: SpyRefiner(), recording: SpyRecording(),
            vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        XCTAssertEqual(transcriber.calls.map(\.initialPrompt), [nil])
    }

    /// The pipeline order spec §4.5 requires: the replacement runs on the transcriber's output
    /// and its result -- not the raw transcript -- is what the refiner is handed. Asserted on the
    /// refiner's own record of what it received, which is the only place this can be seen from
    /// the outside.
    func testTheVocabularyReplacementReachesTheRefinerBeforeItRuns() async {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        let refiner = SpyRefiner(mode: .prompt)
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("open cloud code now")),
            inserter: SpyInserter(), refiner: refiner, recording: SpyRecording(),
            vocabulary: FakeVocabulary(entries: entries), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        XCTAssertEqual(refiner.calls.refined, ["open Claude Code now"])
    }

    /// The team lead's decision: `rawTranscript` is the model's own output, forever -- never the
    /// vocabulary-corrected text -- because it is the corpus a future vocabulary-mining step
    /// reads, and baking the fix in would erase the evidence of the mis-hearing that justified
    /// the entry. `correctedText` is what closes the gap that decision leaves open on its own:
    /// `Voice` has no refiner, so `refinementSeconds` never gets set and `storedRefinement`
    /// stays nil regardless of what the vocabulary changed -- without a column of its own, the
    /// corrected text actually pasted below would be stored in NEITHER column of this row.
    func testTheArchivedRawTranscriptIsTheModelsOutputAndTheCorrectionLivesInItsOwnColumn() async {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        let inserter = SpyInserter()
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("open cloud code now")),
            inserter: inserter, refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(entries: entries), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        // What was pasted is the CORRECTED text -- the whole point of the replacement step.
        XCTAssertEqual(inserter.inserted, ["open Claude Code now"])
        // What the archive keeps as `rawTranscript` is the model's own output, uncorrected.
        XCTAssertEqual(recording.records.last?.rawTranscript, "open cloud code now")
        // And the corrected text that was actually pasted survives in its own column, in a mode
        // that never touches `refinedText` at all.
        XCTAssertEqual(recording.records.last?.correctedText, "open Claude Code now")
        XCTAssertNil(recording.records.last?.refinedText, "Voice has no refiner to attribute it to")
    }

    /// The second bug the same fix closes, and the reason `storedRefinement` compares against
    /// `corrected` rather than `rawTranscript`: in a mode that DOES refine, a refiner that echoes
    /// the vocabulary-corrected text back unchanged must not be stored as a refinement -- the LLM
    /// contributed nothing, and `refinedText` claiming otherwise would mislabel a vocabulary fix
    /// as the model's own work in every refining mode, not only in `Voice`.
    func testARefinerThatEchoesTheCorrectedTextStoresNoRefinement() async {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        let recording = SpyRecording()
        let refiner = SpyRefiner(mode: .prompt, answer: { $0 }) // echoes exactly what it is handed
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("open cloud code now")),
            inserter: SpyInserter(), refiner: refiner, recording: recording,
            vocabulary: FakeVocabulary(entries: entries), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()

        XCTAssertEqual(recording.records.last?.correctedText, "open Claude Code now")
        XCTAssertNil(
            recording.records.last?.refinedText,
            "the refiner changed nothing beyond the vocabulary's own correction")
    }

    /// **A broken archive must not cost a dictation** -- spec §9's rule for the refiner, one layer
    /// down, and the reason `DictationController` holds its `HistoryStore` as an optional.
    ///
    /// The store is opened against a real file that is not a database, so the nil below is
    /// SQLite's answer and not one this test chose. The double is shaped exactly like the app's
    /// `DictationArchive`: no store, nothing written, nothing said. A double that threw instead
    /// would be proving something about a shape the app does not have.
    func testABrokenArchiveDoesNotCostADictation() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BrokenArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("murmure.sqlite")
        try Data("this is not a database, it is a sentence".utf8).write(to: databaseURL)
        XCTAssertThrowsError(try HistoryStore(databaseURL: databaseURL)) { error in
            XCTAssertTrue(error is HistoryStoreError, "\(error)")
        }

        let archive = BrokenArchive(store: try? HistoryStore(databaseURL: databaseURL))
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("on relance le pipeline demain matin")),
            inserter: inserter, refiner: SpyRefiner(),
            recording: archive, vocabulary: FakeVocabulary(), onStateChange: { _ in }
        )
        await session.toggle() // start
        await session.toggle() // stop + pipeline

        // The dictation came out the far end: transcribed, and pasted into the target app.
        XCTAssertEqual(inserter.inserted, ["on relance le pipeline demain matin"])
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        // What it cost is exactly the row, and nothing else.
        XCTAssertEqual(archive.rowsWritten, 0, "there was no archive to write to")
    }

    // MARK: - Where the text actually went

    /// **The defect, as the three lies it told at once.** `PasteBehaviour.copyToClipboardOnly`
    /// puts the transcript on the clipboard and posts no ⌘V, and `insert` returns normally from
    /// that path -- so a session reading "it did not throw" as "it landed" sounded the
    /// confirmation cue, wrote `.inserted` into the archive, and put "Inserted 15 characters" on
    /// screen for a dictation that had reached no application at all.
    ///
    /// The archive one is the worst of the three and is why this is a correctness bug rather than
    /// a cosmetic one: the reason a row keeps its text is so a paste that did not arrive can be
    /// recovered, and a row claiming `.inserted` is false in the one place it exists to be
    /// trusted.
    ///
    /// One dictation is run end to end and all three surfaces are read off it, rather than three
    /// tests asserting three functions return a new enum case: what has to be true is that a
    /// SESSION says the same thing three times, and a per-function test would still pass with the
    /// session wired to the wrong one.
    func testACopyOnlyDictationTellsAllThreeSurfacesTheTextWasNotPasted() async {
        let states = StateLog()
        let recording = SpyRecording()
        let inserter = SpyInserter()
        inserter.delivery = .copiedToClipboard
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("bonjour murmure")),
            inserter: inserter, refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { states.append($0) }
        )

        await session.toggle()
        await session.toggle()

        // The text really was handed over -- this is a delivered dictation, not a refused one.
        XCTAssertEqual(inserter.inserted, ["bonjour murmure"])

        // 1. The archive.
        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .copiedToClipboard)
        XCTAssertNotEqual(row.outcome, .inserted, "nothing reached the application in front")
        XCTAssertEqual(row.insertedCharacters, 0, "the count is what LANDED, and nothing did")
        // The dictation is still fully recoverable from the row, which is the whole point of it.
        XCTAssertEqual(row.rawTranscript, "bonjour murmure")
        XCTAssertNil(row.failureMessage, "a setting doing its job is not a failure")

        // 2. The sound. Driven through the real `CueFeedback`, not through `FeedbackPolicy`
        // directly: what has to be silent is this dictation, and the states it emitted are what
        // the app hands the player.
        let player = SpyPlayer()
        let feedback = CueFeedback(player: player)
        for state in states.values { feedback.apply(state) }
        XCTAssertEqual(
            player.played, [.recordingStarted],
            "the insertion cue means the words are under the cursor, and they are not")

        // 3. The sentence on screen, composed the way the app composes it: every state change
        // through `NotchPresenter.phase(previous:current:)`, then the phase through the panel.
        let labels = phaseLabels(for: states.values)
        XCTAssertTrue(
            labels.contains("Copied 15 characters"), "got \(labels)")
        XCTAssertFalse(
            labels.contains(where: { $0.hasPrefix("Inserted") }),
            "the panel claimed an insertion: \(labels)")
        XCTAssertFalse(
            labels.contains("Nothing heard"),
            "the microphone got everything -- that sentence sends Louis to check hardware")
    }

    /// The control for the test above, and the reason it is not a tautology: the SAME dictation
    /// with the shipped paste behaviour has to still say "inserted" in all three places. Without
    /// this, a correction that simply stopped ever announcing an insertion would pass.
    func testTheSameDictationPastedNormallyStillSaysInsertedInAllThreePlaces() async {
        let states = StateLog()
        let recording = SpyRecording()
        let inserter = SpyInserter() // defaults to the paste
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("bonjour murmure")),
            inserter: inserter, refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { states.append($0) }
        )

        await session.toggle()
        await session.toggle()

        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .inserted)
        XCTAssertEqual(row.insertedCharacters, 15)

        let player = SpyPlayer()
        let feedback = CueFeedback(player: player)
        for state in states.values { feedback.apply(state) }
        XCTAssertEqual(player.played, [.recordingStarted, .textInserted])

        XCTAssertTrue(
            phaseLabels(for: states.values).contains("Inserted 15 characters"),
            "got \(phaseLabels(for: states.values))")
    }

    /// Emptiness outranks the delivery, and the ordering is deliberate (lot 4 D8: what is stored
    /// is decided by whether there was text to insert). `PasteInserter` returns
    /// `.copiedToClipboard` from its empty-transcript guard because nothing was pasted there
    /// either -- and a session that read the outcome off the delivery instead would archive a
    /// silence as a clipboard delivery, offering a re-paste of nothing.
    func testASilenceIsStillNothingHeardHoweverTheInserterAnswers() async {
        let states = StateLog()
        let recording = SpyRecording()
        let inserter = SpyInserter()
        inserter.delivery = .copiedToClipboard
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("")),
            inserter: inserter, refiner: SpyRefiner(), recording: recording,
            vocabulary: FakeVocabulary(), onStateChange: { states.append($0) }
        )

        await session.toggle()
        await session.toggle()

        guard let row = recording.records.first else { return XCTFail("no record written") }
        XCTAssertEqual(row.outcome, .nothingHeard)
        XCTAssertEqual(row.insertedCharacters, 0)
        XCTAssertTrue(states.values.contains(.completed(insertedCharacters: 0)), "got \(states.values)")
        XCTAssertFalse(
            states.values.contains(.copiedToClipboard(characters: 0)),
            "there was nothing to put on a clipboard")
    }

    /// Every sentence the panel would show for this run of state changes, composed the way the app
    /// composes it -- `NotchPresenter.phase(previous:current:)` fed each change in order, because
    /// a completion is emitted with its own `.idle` and only that function keeps it on screen.
    private func phaseLabels(for states: [DictationSession.State]) -> [String] {
        var previous = DictationSession.State.idle
        var labels: [String] = []
        for state in states {
            labels.append(
                StatusPanelText.label(for: NotchPresenter.phase(previous: previous, current: state)))
            previous = state
        }
        return labels
    }
}

/// Records what it was asked to play. A copy of `CueFeedbackTests`'s own spy rather than a shared
/// one, which is what every other double in this file is: the suites are read one at a time.
private final class SpyPlayer: CuePlaying {
    private(set) var played: [FeedbackCue] = []

    func play(_ cue: FeedbackCue) {
        played.append(cue)
    }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DictationSession.State] = []

    var values: [DictationSession.State] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ state: DictationSession.State) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(state)
    }
}

/// A transcriber that parks inside `transcribe` until the test lets it through, so a press can be
/// timed to land while the session is genuinely in `.transcribing`.
private actor GatedTranscriber: Transcriber {
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<String, Never>?
    private var hasEntered = false

    func transcribe(wav: URL, language: String, initialPrompt: String?) async -> String {
        hasEntered = true
        entered?.resume()
        entered = nil
        return await withCheckedContinuation { release = $0 }
    }

    func waitUntilTranscribing() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func finish(with text: String) {
        release?.resume(returning: text)
        release = nil
    }
}

/// `GatedTranscriber`'s counterpart for the other end of the pipeline: it parks inside
/// `modeForNewDictation()` until the test lets it through, so a press can be timed to land in the
/// window `toggle()` opens between `recorder.start()` and `.recording`.
///
/// Unlike `GatedTranscriber` it parks callers in a list rather than a single slot. Only one call
/// should ever reach the gate -- `resolutions` asserts it -- but if a future change lets two in, a
/// single slot would drop the first continuation and hang the whole suite instead of failing this
/// test.
private actor GatedRefiner: DictationRefining {
    private var entered: CheckedContinuation<Void, Never>?
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false
    private(set) var resolutions = 0

    func modeForNewDictation() async -> Mode {
        resolutions += 1
        hasEntered = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { parked.append($0) }
        return .voice
    }

    func refine(_ transcript: String, with mode: Mode) async -> String { transcript }

    func waitUntilResolving() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func finish() {
        for continuation in parked { continuation.resume() }
        parked = []
    }
}

/// The app's `DictationArchive` in the one state this file tests it in: `store` is nil because
/// `murmure.sqlite` refused to open, so there is nowhere to write a row and none is written. The
/// real one logs and moves on for the same reason -- an error raised at the end of a dictation
/// that otherwise worked perfectly is about an archive Louis was not thinking about.
private final class BrokenArchive: DictationRecording, @unchecked Sendable {
    private let store: HistoryStore?
    private let lock = NSLock()
    private var written = 0

    init(store: HistoryStore?) {
        self.store = store
    }

    var rowsWritten: Int { lock.withLock { written } }

    func targetForNewDictation() async -> DictationTarget { .unknown }

    func record(_ dictation: HistoryRecord) async {
        guard let store else { return }
        guard (try? store.insert(dictation)) != nil else { return }
        lock.withLock { written += 1 }
    }
}
