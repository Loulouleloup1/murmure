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
    var lastFailure: Error?
    /// How many recordings actually began. One is the whole point of the concurrency test below:
    /// two would be two taps on one microphone.
    private(set) var startCount = 0
    let frames: AVAudioFrameCount
    private var isRecording = false
    private let url: URL

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
    }

    func stop() -> URL? {
        isRecording = false
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

private struct FakeTranscriber: Transcriber {
    var result: Result<String, Error>
    func transcribe(wav: URL) async throws -> String { try result.get() }
}

private final class SpyInserter: TextInserter, @unchecked Sendable {
    var inserted: [String] = []
    var error: Error?
    func insert(_ text: String) async throws {
        if let error { throw error }
        inserted.append(text)
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
            onStateChange: { _ in }
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
            onStateChange: { _ in }
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
            onStateChange: { _ in }
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
            onStateChange: { _ in }
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
            onStateChange: { _ in }
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
            onStateChange: { _ in }
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
            onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        let afterSuccess = await session.lastTranscript
        XCTAssertEqual(afterSuccess, "première dictée")

        let failing = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .failure(TestError())),
            inserter: inserter, refiner: SpyRefiner(),
            onStateChange: { _ in }
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
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(states.values, [.recording, .transcribing, .inserting, .idle])
    }

    /// An actor is re-entrant: while `toggle()` awaits the transcriber it releases the executor,
    /// so a third press really does land inside the running pipeline. It must be ignored rather
    /// than start a second recording on top of the first.
    func testAPressDuringTheRunningPipelineIsIgnored() async {
        let transcriber = GatedTranscriber()
        let session = DictationSession(
            recorder: FakeRecorder(), transcriber: transcriber,
            inserter: SpyInserter(), refiner: SpyRefiner(), onStateChange: { _ in }
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
            inserter: inserter, refiner: refiner, onStateChange: { _ in }
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
            inserter: SpyInserter(), refiner: refiner, onStateChange: { _ in }
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
            inserter: SpyInserter(), refiner: refiner, onStateChange: { _ in }
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
            inserter: inserter, refiner: refiner, onStateChange: { _ in }
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
            onStateChange: { states.append($0) }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertEqual(states.values, [.recording, .transcribing, .refining, .inserting, .idle])
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
            inserter: inserter, refiner: refiner, onStateChange: { _ in }
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
            inserter: inserter, refiner: refiner, onStateChange: { _ in }
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

    func transcribe(wav: URL) async -> String {
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
