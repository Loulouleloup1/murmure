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
    let frames: AVAudioFrameCount
    private let url: URL

    init(frames: AVAudioFrameCount = 16_000) {
        self.frames = frames
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
    }

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func stop() -> URL? {
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
