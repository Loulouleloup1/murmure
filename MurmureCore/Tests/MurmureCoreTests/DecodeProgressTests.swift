import XCTest
@testable import MurmureCore

/// Louis asked for a bar that shows where the transcription has got to, and chose it over an
/// animation on the explicit understanding that the number would be true. Every row below is one
/// way the number stops being true -- and every one of them was measured against WhisperKit 1.1.0
/// on his own recordings, not imagined.
final class DecodeProgressTests: XCTestCase {
    // MARK: - The fraction itself

    func testStartsAtZeroWithNothingMeasured() {
        let progress = DecodeProgress()
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertEqual(progress.steps, 0)
    }

    func testAnAdvanceIsKeptAndCounted() {
        var progress = DecodeProgress()
        progress.observe(0.33)
        XCTAssertEqual(progress.fraction, 0.33, accuracy: 1e-12)
        XCTAssertEqual(progress.steps, 1)
    }

    func testTheBarNeverGoesBackwards() {
        // The measured case, on all four recordings it was tried on: `WhisperKit.progress` is
        // replaced by a fresh `Progress` the instant the call returns, so a reader that re-reads
        // the property goes 0.9042 → 0. Whatever else changes, the bar must not run backwards
        // under Louis's eyes.
        var progress = DecodeProgress()
        progress.observe(0.9042)
        progress.observe(0)
        XCTAssertEqual(progress.fraction, 0.9042, accuracy: 1e-12)
        XCTAssertEqual(progress.steps, 1, "a reading that is not an advance is not a step")
    }

    func testAReadingAboveOneIsClamped() {
        // Not hypothetical: a transcription that throws leaves its unfinished child attached to
        // WhisperKit's parent `Progress`, and the next one adds a second child with the same
        // pending unit count to the same total of 1. Measured against Foundation: a child
        // abandoned at 40 % makes the next transcription's last reading 1.4.
        var progress = DecodeProgress()
        progress.observe(1.4)
        XCTAssertEqual(progress.fraction, 1)
    }

    func testANegativeReadingCannotEmptyTheBar() {
        var progress = DecodeProgress()
        progress.observe(0.5)
        progress.observe(-0.2)
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 1e-12)
    }

    func testANonFiniteReadingIsDropped() {
        // It would become the width of a bar, and a NaN width draws nothing at all.
        var progress = DecodeProgress()
        progress.observe(0.4)
        progress.observe(.nan)
        progress.observe(.infinity)
        XCTAssertEqual(progress.fraction, 0.4, accuracy: 1e-12)
        XCTAssertEqual(progress.steps, 1)
    }

    func testARepeatedReadingIsNotAStep() {
        // The interface pulls at its redraw rate; the decoder moves at most once every 0.66 s.
        // Most pulls therefore read the same number, and none of them is a progression.
        var progress = DecodeProgress()
        progress.observe(0.25)
        progress.observe(0.25)
        progress.observe(0.25)
        XCTAssertEqual(progress.steps, 1)
    }

    // MARK: - The two endpoints

    func testSuccessAlwaysReachesOne() {
        // A 500 Hz poll missed WhisperKit's final update on three recordings out of four; the
        // 87.8 s one was left reading 0.9042 after it had in fact finished. A bar that stops at
        // 90 % on every success is the defect this line exists to prevent.
        var progress = DecodeProgress()
        progress.observe(0.9042)
        progress.finish()
        XCTAssertEqual(progress.fraction, 1)
    }

    func testAOneWindowDictationSucceedsHavingMeasuredNothing() {
        // 3.1 s, 4.2 s, 7.3 s and 13.7 s recordings each decode inside a single 30 s window and
        // produce no intermediate update at all. They still end full -- and `steps` still has to
        // say that nothing was ever measured, so the interface can tell this apart from a
        // dictation that really did progress.
        var progress = DecodeProgress()
        progress.finish()
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.steps, 0)
    }

    func testAStaleReadingAfterSuccessCannotUnfillTheBar() {
        var progress = DecodeProgress()
        progress.finish()
        progress.observe(0)
        XCTAssertEqual(progress.fraction, 1)
    }

    // MARK: - The box the interface pulls from

    func testNothingToDrawBeforeTheFirstTranscription() {
        XCTAssertNil(DecodeProgressBox().current())
    }

    func testATranscriptionOpensEmpty() throws {
        let box = DecodeProgressBox()
        box.begin()
        let reading = try XCTUnwrap(box.current())
        XCTAssertEqual(reading.fraction, 0)
        XCTAssertEqual(reading.steps, 0)
    }

    func testTheNextDictationDoesNotOpenOnThePreviousOnesFullBar() throws {
        // `begin()` is called at the top of the transcription, `follow()` only once the decoder is
        // reachable. On the first dictation of a session the gap between them is the model load --
        // 112 s, measured cold. During it the box must forget both halves of the last dictation:
        // the reading it reached, and the finished `Progress` that would keep answering 1.0.
        let box = DecodeProgressBox()
        let (parent, child) = Self.whisperKitProgressGraph()
        box.begin()
        box.follow(parent)
        child.completedUnitCount = 100
        box.finish()
        XCTAssertEqual(try XCTUnwrap(box.current()).fraction, 1, "the dictation that just ended")

        box.begin()
        let opening = try XCTUnwrap(box.current())
        XCTAssertEqual(opening.fraction, 0)
        XCTAssertEqual(opening.steps, 0)
    }

    func testItReportsWhatTheDecoderHasDecoded() throws {
        let box = DecodeProgressBox()
        let (parent, child) = Self.whisperKitProgressGraph()
        box.begin()
        box.follow(parent)
        child.completedUnitCount = 25
        XCTAssertEqual(try XCTUnwrap(box.current()).fraction, 0.25, accuracy: 1e-9)
        child.completedUnitCount = 75
        XCTAssertEqual(try XCTUnwrap(box.current()).fraction, 0.75, accuracy: 1e-9)
    }

    func testATranscriptionAfterAFailedOneStillStartsAtZero() throws {
        // The real graph after a throw: WhisperKit only resets `progress` when it finished or was
        // cancelled, so the abandoned child stays attached and the next transcription adds a
        // second one beside it. Raw, this dictation reads 0.4 → 1.4. Louis must see 0 → 1.
        let parent = Progress()
        parent.totalUnitCount = max(1, parent.totalUnitCount)
        let abandoned = Progress()
        parent.addChild(abandoned, withPendingUnitCount: 1)
        abandoned.totalUnitCount = 100
        abandoned.completedUnitCount = 40

        let box = DecodeProgressBox()
        box.begin()
        // Captured before WhisperKit attaches this transcription's child, exactly as the engine
        // captures it before the call.
        box.follow(parent)
        parent.totalUnitCount = max(1, parent.totalUnitCount)
        let child = Progress()
        parent.addChild(child, withPendingUnitCount: 1)
        child.totalUnitCount = 100

        XCTAssertEqual(try XCTUnwrap(box.current()).fraction, 0, accuracy: 1e-9)
        child.completedUnitCount = 50
        XCTAssertEqual(try XCTUnwrap(box.current()).fraction, 0.5, accuracy: 1e-9)
        child.completedUnitCount = 100
        XCTAssertEqual(try XCTUnwrap(box.current()).fraction, 1, accuracy: 1e-9)
    }

    func testSuccessFillsTheBarEvenWhenTheDecoderWasNeverSeenToFinish() throws {
        let box = DecodeProgressBox()
        let (parent, child) = Self.whisperKitProgressGraph()
        box.begin()
        box.follow(parent)
        child.completedUnitCount = 90
        _ = box.current()
        box.finish()
        XCTAssertEqual(try XCTUnwrap(box.current()).fraction, 1)
    }

    /// WhisperKit's own object graph for one transcription: `runTranscribeTask` raises the parent
    /// to at least one unit and attaches a child worth that unit (`WhisperKit.swift:1141-1142`),
    /// and `TranscribeTask` gives the child the clip length as its total.
    private static func whisperKitProgressGraph() -> (parent: Progress, child: Progress) {
        let parent = Progress()
        parent.totalUnitCount = max(1, parent.totalUnitCount)
        let child = Progress()
        parent.addChild(child, withPendingUnitCount: 1)
        child.totalUnitCount = 100
        return (parent, child)
    }
}
