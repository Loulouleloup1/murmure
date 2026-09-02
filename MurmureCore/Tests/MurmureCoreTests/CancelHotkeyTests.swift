import AVFoundation
import XCTest
@testable import MurmureCore

/// Stands in for the Carbon registration, and counts both halves of it.
///
/// The counts are the point rather than a convenience. The failure this whole type exists to
/// prevent is a registration that OUTLIVES its recording -- Escape silently stopping working in
/// every application on the Mac, with no error and nothing to connect it to a dictation app -- and
/// the only shape of that failure a test can see is `takes > releases` at the end of a sequence.
private final class SpyCancelKey: CancelKeyRegistering {
    private(set) var takes = 0
    private(set) var releases = 0
    /// What the system answers. `false` is the case that matters: a refused registration must
    /// still be released, or the bookkeeping and the OS disagree the moment it starts working.
    var systemAccepts = true

    func registerCancelKey() -> Bool {
        takes += 1
        return systemAccepts
    }

    func releaseCancelKey() {
        releases += 1
    }

    /// Whether the OS is holding the key right now, as far as this spy can tell.
    var isTaken: Bool { takes > releases }
}

/// Every state, so the assertions that quantify over all of them quantify over a real domain and
/// a state added later has to be added here rather than being silently untested.
private let everyState: [DictationSession.State] = [
    .idle, .recording, .transcribing, .refining, .inserting,
    .completed(insertedCharacters: 42), .completed(insertedCharacters: 0),
    .cancelled,
    .failed(message: "insert failed", recoveredText: "bonjour"),
    .failed(message: "mic start failed", recoveredText: nil),
]

/// Deliver a state change the way the app does when nothing is racing: stamped at the emission
/// point, applied straight after.
///
/// Written as a helper rather than inlined so the tests below read as sequences of dictation
/// states, and so the ONE thing that separates the ordering tests from the rest -- that they stamp
/// and apply at different moments -- is visible in the tests that do it.
private extension CancelHotkey {
    func deliver(_ state: DictationSession.State) {
        apply(stamp(state))
    }
}

final class CancelHotkeyTests: XCTestCase {
    // MARK: - The combination itself

    /// Escape, bare. The key code is Carbon's `kVK_Escape`, and the modifier mask is empty on
    /// purpose: a chord would not be the gesture, and Escape with a modifier is a different key
    /// as far as `RegisterEventHotKey` is concerned.
    func testTheCancelKeyIsBareEscape() {
        XCTAssertEqual(KeyCombo.cancelRecording.keyCode, 53)
        XCTAssertEqual(KeyCombo.cancelRecording.carbonModifiers, 0)
    }

    /// The two registrations must never be the same combination: they are held by two managers at
    /// the same instant while a recording runs, and a collision would be one of them refused.
    func testTheCancelKeyIsNotTheToggle() {
        XCTAssertNotEqual(KeyCombo.cancelRecording, KeyCombo.defaultToggle)
    }

    // MARK: - When the key is live

    /// **The whole of the policy, and the reason it is a function over a value rather than a pair
    /// of calls.** A globally registered Escape is taken from every application on the machine, so
    /// the set of states that hold it has to be exactly one, and it has to be checkable.
    func testOnlyARecordingHoldsTheKey() {
        for state in everyState {
            let expected = state == .recording
            XCTAssertEqual(
                CancelHotkeyPolicy.isLive(during: state), expected,
                "\(state) answers the wrong thing about holding Escape")
        }
    }

    /// The pipeline is the case this rules out deliberately. A refinement runs 19 s at the p-high
    /// of the measured calls and 57.5 s at the worst, and holding Escape for that long would take
    /// it from whatever Louis is reading while he waits -- to cancel work that is already done.
    func testThePipelineDoesNotHoldTheKey() {
        XCTAssertFalse(CancelHotkeyPolicy.isLive(during: .transcribing))
        XCTAssertFalse(CancelHotkeyPolicy.isLive(during: .refining))
        XCTAssertFalse(CancelHotkeyPolicy.isLive(during: .inserting))
    }

    // MARK: - The binding

    func testARecordingTakesTheKey() {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)

        // When
        hotkey.deliver(.recording)

        // Then
        XCTAssertEqual(key.takes, 1)
        XCTAssertEqual(key.releases, 0)
    }

    /// An actor is re-entrant and the state stream is not promised to be free of repeats, so the
    /// binding has to be idempotent in both directions. Two takes would leave the second
    /// registration refused (`eventHotKeyExistsErr`) and the first one held by a handle nothing
    /// points at any more.
    func testASecondRecordingDoesNotTakeTheKeyTwice() {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)

        // When
        hotkey.deliver(.recording)
        hotkey.deliver(.recording)

        // Then
        XCTAssertEqual(key.takes, 1)
    }

    /// **The property that matters, quantified over every way a recording can end.** Not "the
    /// release is called on the paths I listed" -- every state that is not a recording releases,
    /// so a state added later cannot become a leak by being forgotten.
    func testEveryStateThatIsNotARecordingReleasesTheKey() {
        for state in everyState where state != .recording {
            // Given
            let key = SpyCancelKey()
            let hotkey = CancelHotkey(key: key)
            hotkey.deliver(.recording)

            // When
            hotkey.deliver(state)

            // Then
            XCTAssertFalse(key.isTaken, "\(state) left Escape registered")
            XCTAssertEqual(key.releases, 1, "\(state) released it \(key.releases) times")
        }
    }

    /// Releasing what was never taken is churn, not safety: `HotkeyManager.unregister()` is
    /// idempotent, but a release on every idle state change would call into Carbon dozens of times
    /// a day for nothing, and it would hide a real double-release in the noise.
    func testAKeyThatWasNeverTakenIsNotReleased() {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)

        // When
        hotkey.deliver(.idle)
        hotkey.deliver(.failed(message: "mic start failed", recoveredText: nil))

        // Then
        XCTAssertEqual(key.takes, 0)
        XCTAssertEqual(key.releases, 0)
    }

    /// **The fail-safe direction, chosen deliberately.** When the system refuses the registration
    /// the binding still considers the key held, so the exit still releases it. Releasing
    /// something nobody holds costs one no-op call into Carbon; believing a refusal means nothing
    /// is held -- when the refusal was a lie, a race, or a future change to `HotkeyManager` -- is
    /// how Escape stops working across the whole Mac.
    func testARegistrationTheSystemRefusedIsStillReleased() {
        // Given
        let key = SpyCancelKey()
        key.systemAccepts = false
        let hotkey = CancelHotkey(key: key)

        // When
        hotkey.deliver(.recording)
        hotkey.deliver(.idle)

        // Then
        XCTAssertEqual(key.takes, 1)
        XCTAssertEqual(key.releases, 1, "a refused registration was never released")
    }

    /// Two dictations in a row take and release once each, rather than the second one inheriting
    /// the first one's registration.
    func testTwoDictationsTakeAndReleaseTheKeyOnceEach() {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)

        // When
        for _ in 0..<2 {
            hotkey.deliver(.recording)
            hotkey.deliver(.transcribing)
            hotkey.deliver(.completed(insertedCharacters: 12))
            hotkey.deliver(.idle)
        }

        // Then
        XCTAssertEqual(key.takes, 2)
        XCTAssertEqual(key.releases, 2)
        XCTAssertFalse(key.isTaken)
    }

    // MARK: - Delivery that arrives out of order

    /// **The failure this guard exists for, and it is the failure of the whole task.** The app
    /// hops each state change onto the main actor with its own `Task { @MainActor in ... }`, and
    /// separate unstructured tasks carry NO ordering guarantee -- whether they happen to run in
    /// order today is a property of the runtime, not one a test can pin.
    ///
    /// Everywhere else that costs a wrong frame the next state corrects. Here it would cost
    /// Escape held across the whole of macOS, indefinitely, with no error and nothing on screen:
    /// a `.recording` overtaking the `.idle` that ended it would re-take the key after the release
    /// had already run, and nothing would ever release it again.
    ///
    /// So the order is not assumed. Each change is stamped where the session EMITS it -- inside
    /// the actor, synchronously, before any hop -- and an application whose stamp is older than
    /// one already applied is dropped.
    func testAStaleRecordingOvertakingTheEndDoesNotRetakeTheKey() {
        // Given -- a whole dictation, stamped in the order the session emitted it
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)
        let recording = hotkey.stamp(.recording)
        let transcribing = hotkey.stamp(.transcribing)
        let idle = hotkey.stamp(.idle)

        // When -- the recording's hop loses the race and arrives last, after the dictation has
        // already ended. Every other state releases, so this is the ONE ordering that hurts: the
        // take happens after the last release, and nothing will ever run to undo it.
        hotkey.apply(transcribing)
        hotkey.apply(idle)
        hotkey.apply(recording)

        // Then
        XCTAssertFalse(key.isTaken, "a stale recording re-took Escape and nothing will release it")
        XCTAssertEqual(key.takes, 0)
    }

    /// **The guard drops what is stale, it does not wedge shut.** A binding that stopped acting
    /// after its first out-of-order delivery would trade a stolen key for a cancel key that
    /// quietly stops working, which is the same class of silent failure one door down.
    func testTheNextDictationStillTakesTheKeyAfterAStaleDeliveryWasDropped() {
        // Given -- a dictation whose recording arrived too late and was dropped
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)
        let recording = hotkey.stamp(.recording)
        hotkey.apply(hotkey.stamp(.idle))
        hotkey.apply(recording)
        XCTAssertEqual(key.takes, 0)

        // When -- the next dictation, delivered in order
        hotkey.deliver(.recording)

        // Then
        XCTAssertEqual(key.takes, 1)
        XCTAssertTrue(key.isTaken)
        hotkey.deliver(.idle)
        XCTAssertFalse(key.isTaken)
    }

    /// The stale application is dropped **entirely**, not merely made harmless. A guard that let
    /// the state through and relied on `.recording` being idempotent would still be wrong the day
    /// a state added later is not.
    func testAStaleApplicationIsDroppedRatherThanAbsorbed() {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)
        let recording = hotkey.stamp(.recording)
        let idle = hotkey.stamp(.idle)
        hotkey.apply(idle)

        // When -- the recording arrives after the idle that should have ended it
        hotkey.apply(recording)

        // Then
        XCTAssertEqual(key.takes, 0, "a state older than one already applied reached the key")
        XCTAssertFalse(key.isTaken)
    }

    /// **Strictly greater, not greater-or-equal.** The same change delivered twice is the same
    /// information twice, and applying it again would take a key that is already held -- which
    /// Carbon refuses with `eventHotKeyExistsErr`, leaving the first registration held by a handle
    /// nothing points at.
    func testTheSameChangeAppliedTwiceIsAppliedOnce() {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)
        let recording = hotkey.stamp(.recording)

        // When
        hotkey.apply(recording)
        hotkey.apply(recording)

        // Then
        XCTAssertEqual(key.takes, 1)
    }

    /// The stamp is what carries the order, so it has to rise on every call and never repeat --
    /// including across two dictations, where a counter reset would make the second dictation's
    /// `.recording` look stale against the first one's `.idle`.
    func testEveryStampIsNewerThanTheOneBeforeIt() {
        // Given
        let hotkey = CancelHotkey(key: SpyCancelKey())

        // When
        let stamps = [
            hotkey.stamp(.recording), hotkey.stamp(.idle),
            hotkey.stamp(.recording), hotkey.stamp(.idle),
        ].map(\.sequence)

        // Then
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, stamps.count, "two changes share a stamp: \(stamps)")
    }

    /// A stamp carries the state it was taken of, unchanged. It is an envelope, not a decision:
    /// what the state MEANS is still `CancelHotkeyPolicy`'s alone.
    func testAStampCarriesTheStateItWasTakenOf() {
        let hotkey = CancelHotkey(key: SpyCancelKey())
        XCTAssertEqual(hotkey.stamp(.recording).state, .recording)
        XCTAssertEqual(hotkey.stamp(.cancelled).state, .cancelled)
    }

    /// **The guard must not cost the ordinary case anything.** Every dictation in this suite is
    /// delivered in order, and this is the statement that they still are: a whole run of them,
    /// end to end, takes and releases exactly once each.
    func testDeliveryInOrderIsUnaffectedByTheGuard() {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)

        // When
        for _ in 0..<3 {
            hotkey.deliver(.recording)
            hotkey.deliver(.transcribing)
            hotkey.deliver(.completed(insertedCharacters: 8))
            hotkey.deliver(.idle)
        }

        // Then
        XCTAssertEqual(key.takes, 3)
        XCTAssertEqual(key.releases, 3)
        XCTAssertFalse(key.isTaken)
    }

    // MARK: - Against the real session, on every path out of a recording

    /// **The enumeration, done by the machine rather than by hand.** The task's real hazard is a
    /// path out of `.recording` that nobody thought of, so this drives the REAL `DictationSession`
    /// through each of its exits, feeds every state it emits to the binding exactly as
    /// `DictationController` does, and asks one question at the end: is Escape still registered?
    ///
    /// A list of call sites reviewed by eye would prove nothing here -- that is the shape of the
    /// bug, not of the fix.
    func testEveryExitFromARecordingReleasesTheKey() async {
        for path in DictationPath.all {
            // Given
            let key = SpyCancelKey()
            let hotkey = CancelHotkey(key: key)
            // Stamped in the closure the session calls -- synchronously, inside the actor,
            // before any hop -- which is exactly where `DictationController` stamps it.
            let session = path.session { state in hotkey.apply(hotkey.stamp(state)) }

            // When
            await session.toggle()
            XCTAssertTrue(key.isTaken, "\(path.name): the recording never took Escape")
            await path.finish(session)

            // Then
            XCTAssertFalse(key.isTaken, "\(path.name) left Escape registered")
            XCTAssertEqual(key.takes, 1, "\(path.name) took Escape \(key.takes) times")
        }
    }

    /// A press the microphone refused is not a recording, so it never takes the key at all -- the
    /// same line `DictationSession` already draws for the mode resolution and the history row.
    func testAMicrophoneThatRefusedNeverTakesTheKey() async {
        // Given
        let key = SpyCancelKey()
        let hotkey = CancelHotkey(key: key)
        let recorder = CancelFakeRecorder()
        recorder.startError = CancelTestFailure()
        let session = DictationSession(
            recorder: recorder, transcriber: CancelFakeTranscriber(result: .success("")),
            inserter: CancelSpyInserter(), refiner: CancelSpyRefiner(),
            recording: CancelSpyRecording(), onStateChange: { hotkey.apply(hotkey.stamp($0)) })

        // When
        await session.toggle()

        // Then
        XCTAssertEqual(key.takes, 0)
        XCTAssertEqual(key.releases, 0)
    }
}

// MARK: - The paths a recording can leave by

/// One way a dictation can end, as the pair of things a test needs: a session wired to produce it,
/// and the call that produces it.
private struct DictationPath {
    let name: String
    let make: (@escaping @Sendable (DictationSession.State) -> Void) -> DictationSession
    /// What ends the recording. `toggle()` for every ordinary end, `cancel()` for the one this
    /// task adds.
    let finish: @Sendable (DictationSession) async -> Void

    func session(
        _ onStateChange: @escaping @Sendable (DictationSession.State) -> Void
    ) -> DictationSession {
        make(onStateChange)
    }

    static let all: [DictationPath] = [
        DictationPath(name: "cancelled") { onStateChange in
            build(onStateChange: onStateChange)
        } finish: { await $0.cancel() },

        DictationPath(name: "inserted") { onStateChange in
            build(transcript: .success("bonjour"), onStateChange: onStateChange)
        } finish: { await $0.toggle() },

        DictationPath(name: "nothing heard -- an empty recording") { onStateChange in
            build(frames: 0, onStateChange: onStateChange)
        } finish: { await $0.toggle() },

        DictationPath(name: "nothing heard -- an empty transcript") { onStateChange in
            build(transcript: .success(""), onStateChange: onStateChange)
        } finish: { await $0.toggle() },

        DictationPath(name: "no audio reached the disk") { onStateChange in
            let recorder = CancelFakeRecorder()
            recorder.stopReturnsNil = true
            return build(recorder: recorder, onStateChange: onStateChange)
        } finish: { await $0.toggle() },

        DictationPath(name: "an unreadable recording") { onStateChange in
            let recorder = CancelFakeRecorder()
            recorder.stopReturnsUnreadableFile = true
            return build(recorder: recorder, onStateChange: onStateChange)
        } finish: { await $0.toggle() },

        DictationPath(name: "a transcription that threw") { onStateChange in
            build(transcript: .failure(CancelTestFailure()), onStateChange: onStateChange)
        } finish: { await $0.toggle() },

        DictationPath(name: "a paste that was refused") { onStateChange in
            let inserter = CancelSpyInserter()
            inserter.error = CancelTestFailure()
            return build(
                transcript: .success("bonjour"), inserter: inserter, onStateChange: onStateChange)
        } finish: { await $0.toggle() },
    ]

    private static func build(
        recorder: CancelFakeRecorder? = nil,
        frames: AVAudioFrameCount = 16_000,
        transcript: Result<String, Error> = .success("bonjour"),
        inserter: CancelSpyInserter = CancelSpyInserter(),
        onStateChange: @escaping @Sendable (DictationSession.State) -> Void
    ) -> DictationSession {
        DictationSession(
            recorder: recorder ?? CancelFakeRecorder(frames: frames),
            transcriber: CancelFakeTranscriber(result: transcript),
            inserter: inserter,
            refiner: CancelSpyRefiner(),
            recording: CancelSpyRecording(),
            onStateChange: onStateChange)
    }
}

// MARK: - Doubles

private struct CancelTestFailure: Error {}

/// The same shape as `DictationSessionTests`' recorder, kept separate rather than shared: that one
/// is `private` to its file, and a double reaching across two test files is a double two tests can
/// break each other through.
private final class CancelFakeRecorder: Recorder {
    var stopReturnsNil = false
    var stopReturnsUnreadableFile = false
    var startError: Error?
    var lastFailure: Error?
    private let frames: AVAudioFrameCount
    private let url: URL

    init(frames: AVAudioFrameCount = 16_000) {
        self.frames = frames
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
    }

    func start() throws {
        if let startError { throw startError }
        FileManager.default.createFile(atPath: url.path, contents: nil)
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

private struct CancelFakeTranscriber: Transcriber {
    let result: Result<String, Error>
    func transcribe(wav: URL) async throws -> String { try result.get() }
}

private final class CancelSpyInserter: TextInserter, @unchecked Sendable {
    var error: Error?
    func insert(_ text: String) async throws {
        if let error { throw error }
    }
}

private struct CancelSpyRefiner: DictationRefining {
    func modeForNewDictation() async -> Mode { .voice }
    func refine(_ transcript: String, with mode: Mode) async -> String { transcript }
}

private struct CancelSpyRecording: DictationRecording {
    func targetForNewDictation() async -> DictationTarget {
        DictationTarget(bundleID: "com.apple.Terminal", name: "Terminal")
    }

    func record(_ dictation: HistoryRecord) async {}
}
