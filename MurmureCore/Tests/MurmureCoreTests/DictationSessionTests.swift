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
    var lastFailure: Error?
    let frames: AVAudioFrameCount
    private let url: URL

    init(frames: AVAudioFrameCount = 16_000) {
        self.frames = frames
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
    }

    func start() throws { started = true }

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

private struct TestError: Error {}

final class DictationSessionTests: XCTestCase {
    func testFullToggleCycleInsertsTranscriptAndReturnsToIdle() async {
        let inserter = SpyInserter()
        let recorder = FakeRecorder()
        let session = DictationSession(
            recorder: recorder,
            transcriber: FakeTranscriber(result: .success("bonjour murmure")),
            inserter: inserter, onStateChange: { _ in }
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
            inserter: inserter, onStateChange: { _ in }
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
            inserter: inserter, onStateChange: { _ in }
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
            inserter: SpyInserter(), onStateChange: { _ in }
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
            inserter: inserter, onStateChange: { _ in }
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
            inserter: inserter, onStateChange: { _ in }
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
            inserter: inserter, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        let afterSuccess = await session.lastTranscript
        XCTAssertEqual(afterSuccess, "première dictée")

        let failing = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .failure(TestError())),
            inserter: inserter, onStateChange: { _ in }
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
            inserter: SpyInserter(), onStateChange: { states.append($0) }
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
            inserter: SpyInserter(), onStateChange: { _ in }
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
