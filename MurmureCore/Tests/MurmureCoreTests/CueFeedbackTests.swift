import XCTest
@testable import MurmureCore

/// Records what it was asked to play, so a test can assert on silence as easily as on sound --
/// which is most of what there is to assert here.
private final class SpyPlayer: CuePlaying {
    private(set) var played: [FeedbackCue] = []

    func play(_ cue: FeedbackCue) {
        played.append(cue)
    }
}

final class CueFeedbackTests: XCTestCase {
    // MARK: - What each state earns

    func testRecordingEarnsTheStartCue() {
        XCTAssertEqual(FeedbackPolicy.cue(for: .recording), .recordingStarted)
    }

    func testAnInsertionThatDeliveredTextEarnsTheInsertCue() {
        XCTAssertEqual(FeedbackPolicy.cue(for: .completed(insertedCharacters: 12)), .textInserted)
    }

    /// The distinction `.completed`'s payload exists for: a dictation that ran to its end and
    /// pasted NOTHING must not sound like one that pasted something. Louis dictates without
    /// looking, so the sound is the whole of what he knows about the outcome.
    func testACompletionThatInsertedNothingIsSilent() {
        XCTAssertNil(FeedbackPolicy.cue(for: .completed(insertedCharacters: 0)))
    }

    /// A failure never makes the sound that means "speak now". A microphone that refused, a
    /// transcription that threw and a paste that was blocked all arrive here.
    func testAFailureIsSilent() {
        XCTAssertNil(
            FeedbackPolicy.cue(for: .failed(message: "mic start failed", recoveredText: nil)))
        XCTAssertNil(
            FeedbackPolicy.cue(for: .failed(message: "insert failed", recoveredText: "hi")))
    }

    /// The three states in the middle of a running dictation. They are progress, not outcomes, and
    /// the surfaces already draw them.
    func testThePipelineStatesAreSilent() {
        XCTAssertNil(FeedbackPolicy.cue(for: .transcribing))
        XCTAssertNil(FeedbackPolicy.cue(for: .refining))
        XCTAssertNil(FeedbackPolicy.cue(for: .inserting))
    }

    /// **Silent, and it is a decision rather than an omission.** `FeedbackCue` has two cases
    /// because this fires dozens of times a day into headphones, and a cancellation is the one
    /// outcome Louis already knows about before it happens -- he pressed the key. The notch and
    /// the panel say it in words; a third sound would be a noise he cannot switch off, earned by
    /// the one event he is never surprised by.
    func testACancellationIsSilent() {
        XCTAssertNil(FeedbackPolicy.cue(for: .cancelled))
    }

    func testIdleIsSilent() {
        XCTAssertNil(FeedbackPolicy.cue(for: .idle))
    }

    // MARK: - The wiring

    /// One dictation end to end, in the exact order `DictationSession` emits it -- including the
    /// `.idle` that follows `.completed` in the same breath. Two sounds, not three: the notch
    /// keeps a completion alive across that `.idle` on purpose, and a driver that copied it would
    /// play the insertion cue twice.
    func testAWholeSuccessfulDictationMakesExactlyTwoSounds() {
        // Given
        let player = SpyPlayer()
        let feedback = CueFeedback(player: player)

        // When
        for state in [
            DictationSession.State.recording, .transcribing, .refining, .inserting,
            .completed(insertedCharacters: 42), .idle,
        ] {
            feedback.apply(state)
        }

        // Then
        XCTAssertEqual(player.played, [.recordingStarted, .textInserted])
    }

    /// A dictation whose microphone was refused. The state machine never reaches `.recording`, so
    /// nothing should tell Louis to start speaking into a device that is not listening.
    func testADictationThatNeverStartedRecordingMakesNoSound() {
        // Given
        let player = SpyPlayer()
        let feedback = CueFeedback(player: player)

        // When
        feedback.apply(.failed(message: "mic start failed", recoveredText: nil))
        feedback.apply(.idle)

        // Then
        XCTAssertEqual(player.played, [])
    }

    /// A dictation that recorded and then failed to paste. The start cue was earned and keeps it --
    /// the microphone really was live -- but nothing confirms an insertion that did not happen.
    func testAPasteFailureKeepsTheStartCueAndAddsNoConfirmation() {
        // Given
        let player = SpyPlayer()
        let feedback = CueFeedback(player: player)

        // When
        feedback.apply(.recording)
        feedback.apply(.transcribing)
        feedback.apply(.inserting)
        feedback.apply(.failed(message: "insert failed", recoveredText: "les mots"))

        // Then
        XCTAssertEqual(player.played, [.recordingStarted])
    }

    /// A dictation Louis cancelled, and one Whisper answered with nothing: both end in
    /// `.completed(0)`, and both must be as silent at the end as they were loud at the start.
    func testASilentDictationSoundsOnlyAtItsStart() {
        // Given
        let player = SpyPlayer()
        let feedback = CueFeedback(player: player)

        // When
        feedback.apply(.recording)
        feedback.apply(.completed(insertedCharacters: 0))
        feedback.apply(.idle)

        // Then
        XCTAssertEqual(player.played, [.recordingStarted])
    }

    /// Two dictations in a row, which is how Louis actually works. Each start is announced: the cue
    /// is per-dictation, not a one-off at launch.
    func testEveryDictationGetsItsOwnStartCue() {
        // Given
        let player = SpyPlayer()
        let feedback = CueFeedback(player: player)

        // When
        for _ in 0..<2 {
            feedback.apply(.recording)
            feedback.apply(.transcribing)
            feedback.apply(.completed(insertedCharacters: 7))
            feedback.apply(.idle)
        }

        // Then
        XCTAssertEqual(
            player.played, [.recordingStarted, .textInserted, .recordingStarted, .textInserted])
    }
}
