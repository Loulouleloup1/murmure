import XCTest
@testable import MurmureCore

/// Every pair below is a real file, not an invented number: the gate's thresholds were calibrated
/// on 1 482 of Louis's dictations and the interesting cases are the ones that sit closest to the
/// line. A change to any constant that moves one of these rows is a change to what gets pasted
/// into his editor, so it has to fail here first.
final class SpeechGateTests: XCTestCase {
    private func accepts(voiced: TimeInterval, total: TimeInterval) -> Bool {
        if case .speech = SpeechGate.verdict(voicedSeconds: voiced, totalSeconds: total) {
            return true
        }
        return false
    }

    private func rejection(voiced: TimeInterval, total: TimeInterval) -> String? {
        if case .silence(let reason) = SpeechGate.verdict(voicedSeconds: voiced, totalSeconds: total) {
            return reason
        }
        return nil
    }

    // MARK: - The two files the gate exists to separate

    func testRejectsTheRoomToneThatHallucinated() {
        // rec-2026-08-31T18-11-02.106Z.wav: 3.1 s of room tone with half a second of sound at the
        // very end. Transcribed as `¿Qué es lo que se llama?` before the gate existed.
        XCTAssertFalse(accepts(voiced: 0.2, total: 3.1))
    }

    func testAcceptsTheQuietestRealDictationInTheCorpus() {
        // The global minimum of voiced audio across all 1 437 real dictations: 0.5 s in a 22.9 s
        // recording. If this row ever fails, the gate has started eating real speech.
        XCTAssertTrue(accepts(voiced: 0.5, total: 22.9))
    }

    func testAcceptsTheShortestRealDictationInTheCorpus() {
        // 1.336 s end to end, 0.7 s of it voiced -- the shortest thing Louis has ever dictated.
        XCTAssertTrue(accepts(voiced: 0.7, total: 1.336))
    }

    func testRejectsTheOneHonestFalseReject() {
        // A 0.524 s clip with 0.2 s of voice whose Superwhisper transcript is `Image`: a real
        // one-word dictation the gate drops. It has exactly as much voiced audio as the
        // hallucinating file, so it cannot be saved without also accepting that one. The trade is
        // pinned here rather than hidden, and it is rejected on VOICED time, not on duration.
        XCTAssertFalse(accepts(voiced: 0.2, total: 0.524))
        XCTAssertEqual(rejection(voiced: 0.2, total: 0.524)?.contains("of voice"), true)
    }

    // MARK: - Rejected on duration alone, without trusting any energy measurement

    func testRejectsEmptyAndBrushedHotkeyRecordings() {
        // A 0-frame WAV (the `kill -9` / instantly-released hotkey case) and 30 ms of audio.
        // Both must be rejected on length alone, before the VAD's numbers matter at all.
        XCTAssertFalse(accepts(voiced: 0.0, total: 0.0))
        XCTAssertFalse(accepts(voiced: 0.0, total: 0.03))
        XCTAssertEqual(rejection(voiced: 0.0, total: 0.0)?.contains("long"), true)
        XCTAssertEqual(rejection(voiced: 0.0, total: 0.03)?.contains("long"), true)
    }

    func testDurationIsCheckedBeforeVoicedTime() {
        // Even a recording that is all voice is rejected if it is too short to be a dictation,
        // and the log has to say so -- "0.4s long" and "0.4s of voice in 0.4s" are different bugs.
        XCTAssertEqual(rejection(voiced: 0.4, total: 0.4)?.contains("long"), true)
    }

    // MARK: - The boundaries themselves

    func testSittingExactlyOnAThresholdIsAccepted() {
        // Both comparisons are `>=`, not `>`: the gate errs towards transcribing.
        XCTAssertTrue(accepts(voiced: 0.3, total: 1.0))
        XCTAssertTrue(accepts(voiced: 1.0, total: 0.5))
    }

    func testJustBelowAThresholdIsRejected() {
        XCTAssertFalse(accepts(voiced: 0.29, total: 1.0))
        XCTAssertFalse(accepts(voiced: TimeInterval(0.3).nextDown, total: 1.0))
        XCTAssertFalse(accepts(voiced: 1.0, total: TimeInterval(0.5).nextDown))
    }

    func testThreeVoicedFramesClearTheVoicedThreshold() {
        // The app measures voiced time as (voiced frame count) x frameLength, and frameLength is a
        // Float because that is what WhisperKit's EnergyVAD takes. Three frames must land on the
        // accept side of a 0.3 s threshold after that Float -> Double widening; a frame length that
        // rounded a hair low would silently raise the gate to four frames.
        let threeFrames = Double(SpeechGate.frameLength) * 3
        XCTAssertTrue(accepts(voiced: threeFrames, total: 1.0))
    }

    // MARK: - What is worth decoding inside an accepted recording

    private func frames(_ pattern: [(voiced: Bool, seconds: Double)]) -> [Bool] {
        pattern.flatMap { chunk in
            Array(repeating: chunk.voiced, count: Int((chunk.seconds / 0.1).rounded()))
        }
    }

    func testAnOrdinaryDictationIsPassedThroughUntouched() {
        // Speech either side of a 26.6 s pause -- the longest silence inside any of the 1 437 real
        // dictations in the corpus. Nothing is removed, so the model gets exactly the audio it
        // gets today. This is the row that stops the silence removal from quietly rewriting the
        // normal case, and it is why the maximum is 30 s and not the 5 s first tried.
        let voiced = frames([(true, 4.0), (false, 26.6), (true, 5.0)])
        XCTAssertEqual(SpeechGate.framesWorthDecoding(voiced: voiced), [0..<voiced.count])
    }

    func testTheElevenMinuteReproKeepsOnlyTheSpeechAndItsPadding() {
        // The reviewer's file: 660 s of silence then 3.1 s of real speech. Before this, the model
        // saw 22 windows of silence and answered each with a fabricated `"Thank you."`.
        let voiced = frames([(false, 660.0), (true, 3.1)])
        let kept = SpeechGate.framesWorthDecoding(voiced: voiced)
        let keptSeconds = kept.reduce(0) { $0 + Double($1.count) * Double(SpeechGate.frameLength) }
        XCTAssertLessThan(keptSeconds, 10)
        // The speech itself survives whole, with its run-up in front of it.
        XCTAssertEqual(kept.last?.upperBound, 6631)
        XCTAssertEqual(kept.last?.lowerBound, 6600 - 15)
    }

    func testASilenceRunIsRemovedOnlyOnceItIsLongerThanTheMaximum() {
        // 30.0 s exactly is kept, 30.1 s is not: the boundary is a product decision, not an
        // accident of how the loop is written.
        let atTheLimit = frames([(true, 1.0), (false, 30.0), (true, 1.0)])
        XCTAssertEqual(SpeechGate.framesWorthDecoding(voiced: atTheLimit), [0..<atTheLimit.count])

        let overTheLimit = frames([(true, 1.0), (false, 30.1), (true, 1.0)])
        XCTAssertEqual(
            SpeechGate.framesWorthDecoding(voiced: overTheLimit),
            [0..<25, 296..<overTheLimit.count]
        )
    }

    func testSomeSilenceSurvivesOnEachSideOfWhatIsRemoved() {
        // A word that starts too quietly to register as voiced must not be clipped off by the
        // removal, and the pause has to still read as a pause -- with too little padding the model
        // runs the utterances either side of it into one sentence. The padding is part of the rule
        // rather than a nicety.
        let voiced = frames([(true, 1.0), (false, 120.0), (true, 1.0)])
        let kept = SpeechGate.framesWorthDecoding(voiced: voiced)
        XCTAssertEqual(kept.first?.upperBound, 10 + 15)
        XCTAssertEqual(kept.last?.lowerBound, 10 + 1200 - 15)
    }

    func testAllVoicedAudioSurvivesWhateverTheSilenceAroundIt() {
        // The property that actually matters: removal never eats a voiced frame.
        let voiced = frames([(false, 60.0), (true, 2.0), (false, 40.0), (true, 1.5), (false, 90.0)])
        let kept = SpeechGate.framesWorthDecoding(voiced: voiced)
        for (index, isVoiced) in voiced.enumerated() where isVoiced {
            XCTAssertTrue(kept.contains { $0.contains(index) }, "dropped voiced frame \(index)")
        }
    }

    func testThresholdsAreTheCalibratedOnes() {
        // The constants are the calibration result; changing one is a product decision, and this
        // is where it has to be made deliberately.
        XCTAssertEqual(SpeechGate.frameLength, 0.1)
        XCTAssertEqual(SpeechGate.energyThreshold, 0.005)
        XCTAssertEqual(SpeechGate.minimumVoicedDuration, 0.3)
        XCTAssertEqual(SpeechGate.minimumDuration, 0.5)
        XCTAssertEqual(SpeechGate.maximumSilenceRun, 30)
        XCTAssertEqual(SpeechGate.silencePadding, 1.5)
    }
}
