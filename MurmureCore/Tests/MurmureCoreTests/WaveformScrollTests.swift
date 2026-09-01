import XCTest
@testable import MurmureCore

/// **The one assertion this file exists for: consecutive drawn frames differ by a bounded amount,
/// instead of repeating five times and then jumping two bars.**
///
/// Louis reported the waveform as "très saccadé" three times. Two rounds answered by raising a
/// rate -- the turnover, then the redraw -- and neither could have worked, because the levels only
/// ever changed 11.7 times a second whatever the drawing did with them. So what is pinned here is
/// not that an interpolation function exists; it is the property that was actually missing, checked
/// against the cadence this Mac's audio device really produces and compared, on the same input,
/// with the drawing that was there before.
final class WaveformScrollTests: XCTestCase {
    private static let sampleRate = 48_000.0
    /// The hint `AudioRecorder` passes to `installTap`. What the tap really delivers is measured
    /// separately; the simulation below is written so the conclusion does not depend on it, and
    /// `testItIsJustAsContinuousWhateverSizeTheTapHandsBack` is where that is checked.
    private static let tapFrames = 4_096
    private static let tick = 1.0 / 60

    // MARK: - The pipeline, off the audio thread

    /// Everything between the microphone and the drawing, run on a clock the test controls: the
    /// real `BlockCutter`, the real `AudioLevelMeter`, the real `LevelHistory`, and the reading
    /// `AudioLevels` builds -- including the carried part-block, which is the term that keeps the
    /// read head from lurching.
    private struct Pipeline {
        let bufferFrames: Int
        var cutter: BlockCutter
        var meter = AudioLevelMeter()
        var history = LevelHistory()
        var burst = 0
        var lastBufferAt: Double = 0
        var buffersDelivered = 0
        var levelsAppended = 0
        /// Every level the meter has produced, so a bound can be taken over the whole run rather
        /// than over whatever happens to be in the ring at the end of it.
        var everyLevel: [Float] = []

        init(bufferFrames: Int) {
            self.bufferFrames = bufferFrames
            cutter = BlockCutter(
                framesPerBlock: Int((sampleRate * WaveformLayout.blockDuration).rounded()))
        }

        /// Delivers every buffer whose last frame has been recorded by `now`.
        mutating func run(to now: Double, voice: (Int) -> Float) {
            while Double((buffersDelivered + 1) * bufferFrames) / sampleRate <= now {
                let start = buffersDelivered * bufferFrames
                let buffer = (start..<(start + bufferFrames)).map(voice)
                let appended = cutter.accept(buffer) { rms in
                    let height = meter.accept(rootMeanSquare: rms)
                    history.append(height)
                    everyLevel.append(height)
                    levelsAppended += 1
                }
                burst = max(burst, appended)
                buffersDelivered += 1
                lastBufferAt = Double(buffersDelivered * bufferFrames) / sampleRate
            }
        }

        /// Built through the real factory, not by hand: the sum of the elapsed time and the
        /// carried part-block is the term the continuity depends on, so the simulation must go
        /// through the code that does it rather than reproduce it.
        func reading(at now: Double) -> WaveformReading {
            WaveformReading.since(
                levels: history.values,
                sinceLastBuffer: now - lastBufferAt,
                pendingFrames: cutter.pendingFrames,
                sampleRate: sampleRate,
                burst: burst)
        }

        /// What `DictationPhaseView.bars` did before this change: the newest `count` levels off
        /// the end of the ring, with nothing said about where between two arrivals we are.
        func staircase(count: Int) -> [Float] {
            Array(history.values.suffix(count))
        }
    }

    /// A voice-shaped signal: a tone whose amplitude sweeps the meter's whole range at 1.7 Hz, so
    /// the levels move the way syllables move rather than sitting at one height.
    private static func voice(_ frame: Int) -> Float {
        let seconds = Double(frame) / sampleRate
        let envelope = 0.004 + 0.05 * (0.5 + 0.5 * sin(2 * .pi * 1.7 * seconds))
        // Amplitude x 1/sqrt(2) is the RMS of a sine, so the envelope IS the level being fed in.
        return Float(envelope * 1.414_213_6 * sin(2 * .pi * 220 * seconds))
    }

    /// Runs that voice past the pipeline and draws a row every 1/60 s, discarding the opening.
    ///
    /// **`settling` is not a fudge and it is worth saying why.** A dictation opens on a ring
    /// prefilled with the meter's floor, so until a second of audio has been through it the row is
    /// genuinely a flat line -- and a flat line drawn twice IS the same picture, correctly. On top
    /// of that, `burst` is only learnt from the buffers that have arrived, so the margin steps up
    /// once or twice in the first fifth of a second and the head steps back with it. Both happen
    /// while the row is flat and neither is visible; measuring continuity through them would be
    /// measuring the prefill. Two seconds puts every sample in the ring past that.
    private func rows(
        bufferFrames: Int = tapFrames, count: Int, seconds: Double = 6, settling: Double = 2
    ) -> (drawn: [[Float]], staircase: [[Float]], heads: [Double], levels: [Float]) {
        var pipeline = Pipeline(bufferFrames: bufferFrames)
        var drawn: [[Float]] = []
        var staircase: [[Float]] = []
        var heads: [Double] = []
        var levels: [Float] = []
        var ticks = 0
        while Double(ticks) * Self.tick < seconds {
            let now = Double(ticks) * Self.tick
            pipeline.run(to: now, voice: Self.voice)
            ticks += 1
            guard now >= settling else { continue }
            let reading = pipeline.reading(at: now)
            drawn.append(WaveformScroll.heights(reading, count: count))
            staircase.append(pipeline.staircase(count: count))
            // The head in absolute level numbers, so it can be compared across arrivals: slot i of
            // the ring is level `levelsAppended - capacity + i`.
            heads.append(
                Double(pipeline.levelsAppended - reading.levels.count)
                    + WaveformScroll.head(reading))
            levels = pipeline.everyLevel
        }
        return (drawn, staircase, heads, levels)
    }

    private func maximumStep(_ rows: [[Float]]) -> Float {
        zip(rows, rows.dropFirst()).reduce(0) { worst, pair in
            max(worst, zip(pair.0, pair.1).reduce(0) { max($0, abs($1.1 - $1.0)) })
        }
    }

    private func repeatedFrames(_ rows: [[Float]]) -> Int {
        zip(rows, rows.dropFirst()).count { $0 == $1 }
    }

    // MARK: - The complaint

    func testEveryDrawnFrameDiffersFromTheOneBeforeIt() {
        // The staircase, stated as a number: at 60 draws a second against levels that change 11.7
        // times a second, roughly five draws in six were the identical picture.
        let card = rows(count: WaveformLayout.maximumBars)

        XCTAssertEqual(repeatedFrames(card.drawn), 0, "a frame that repeats is a frame that steps")
        XCTAssertGreaterThan(
            repeatedFrames(card.staircase), card.staircase.count * 3 / 4,
            "the drawing this replaces repeated most of its frames -- if this fails, the "
                + "simulation has stopped reproducing the thing being fixed")
    }

    func testConsecutiveFramesDifferByAtMostTheDistanceTheHeadTravelsInOne() {
        // The bound is arithmetic, not a tolerance: in 1/60 s the read head covers
        // (1/60)/0.043 = 0.388 of a level, and between two levels the height is linear, so no bar
        // can move more than 0.388 of the biggest step in the level sequence itself.
        let card = rows(count: WaveformLayout.maximumBars)
        let steepest = zip(card.levels, card.levels.dropFirst())
            .reduce(Float(0)) { max($0, abs($1.1 - $1.0)) }
        let reachable = Float(Self.tick / WaveformLayout.blockDuration) * steepest

        XCTAssertGreaterThan(steepest, 0.05, "the fixture has to actually move for this to mean anything")
        XCTAssertLessThanOrEqual(maximumStep(card.drawn), reachable + 1e-5)
        XCTAssertGreaterThan(
            maximumStep(card.staircase), maximumStep(card.drawn) * 4,
            "and the drawing this replaces jumped several times further, in one frame")
    }

    func testTheRowSlidesAtExactlyOneBarPerBlockAndNeverBackwards() {
        // This is the test that caught the design's own bug. Anchoring the head on the number of
        // levels appended -- without the part-block the cutter still carries -- makes it lurch
        // 0.98 of a bar BACKWARDS at the buffers that complete one level instead of two, about
        // every five and a half seconds. Every increment being near the ideal is what forbids it.
        let card = rows(count: WaveformLayout.maximumBars, seconds: 14)
        let ideal = Self.tick / WaveformLayout.blockDuration
        let steps = zip(card.heads, card.heads.dropFirst()).map { $1 - $0 }

        XCTAssertGreaterThan(steps.count, 700)
        XCTAssertEqual(steps.min() ?? 0, ideal, accuracy: 0.02, "no frame stalls or runs backwards")
        XCTAssertEqual(steps.max() ?? 0, ideal, accuracy: 0.02, "and none sprints")
    }

    func testTheHeadNeverReachesALevelThatHasNotLandedYet() {
        // A head clamped at the newest slot is a frozen picture, which is the staircase again --
        // so the margin has to cover the whole time between two buffers, carry included.
        var pipeline = Pipeline(bufferFrames: Self.tapFrames)
        var ticks = 0
        while Double(ticks) * Self.tick < 8 {
            let now = Double(ticks) * Self.tick
            pipeline.run(to: now, voice: Self.voice)
            ticks += 1
            // Past the prefill, where the margin is still being learnt and the row is flat.
            guard now >= 2 else { continue }
            let reading = pipeline.reading(at: now)
            let head = WaveformScroll.head(reading)
            XCTAssertLessThan(head, Double(reading.levels.count - 1), "clamped at the newest")
            if pipeline.levelsAppended > reading.levels.count {
                XCTAssertGreaterThan(head, 0, "clamped at the oldest")
            }
        }
    }

    func testItIsJustAsContinuousWhateverSizeTheTapHandsBack() {
        // `installTap`'s bufferSize is a hint. 512 frames is what a device may hand back instead,
        // and 8 192 is what it may hand back the other way; neither must reintroduce the step.
        for bufferFrames in [512, 1_024, 4_096, 8_192] {
            let card = rows(bufferFrames: bufferFrames, count: WaveformLayout.maximumBars)
            XCTAssertEqual(
                repeatedFrames(card.drawn), 0, "repeated a frame at \(bufferFrames) frames")
            let steps = zip(card.heads, card.heads.dropFirst()).map { $1 - $0 }
            XCTAssertEqual(
                steps.min() ?? 0, Self.tick / WaveformLayout.blockDuration, accuracy: 0.02,
                "the row stalled or ran backwards at \(bufferFrames) frames")
        }
    }

    // MARK: - The shape it must not change

    func testANarrowSurfaceStillShowsTheNEWESTLevelsAndNotTheOldest() {
        // The panel draws twelve of the twenty-three levels kept. Showing the start of the ring
        // would be a waveform running a second behind the voice, which is what `suffix` was for.
        let panel = rows(count: 12)
        let card = rows(count: WaveformLayout.maximumBars)

        XCTAssertEqual(panel.drawn.count, card.drawn.count)
        for (narrow, wide) in zip(panel.drawn, card.drawn) {
            XCTAssertEqual(narrow.count, 12)
            XCTAssertEqual(narrow, Array(wide.suffix(12)), "the panel is the card's right-hand end")
        }
    }

    func testASurfaceAlwaysGetsExactlyTheBarsItAskedFor() {
        // The row's width is `WaveformLayout`'s decision and this must never quietly change it:
        // a short row would redraw the shape narrower, which is the one thing lot 3 forbids.
        let reading = WaveformReading(levels: [0.2, 0.4, 0.6], sinceNewest: 0.01, burst: 2)
        for count in [1, 3, 12, 23, 60] {
            XCTAssertEqual(WaveformScroll.heights(reading, count: count).count, count)
        }
    }

    // MARK: - Reading the ring at a fraction

    func testAFractionalPositionMixesTheTwoLevelsItFallsBetween() {
        let levels: [Float] = [0, 0.4, 1]

        XCTAssertEqual(WaveformScroll.level(in: levels, at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(WaveformScroll.level(in: levels, at: 0.25), 0.1, accuracy: 1e-6)
        XCTAssertEqual(WaveformScroll.level(in: levels, at: 1), 0.4, accuracy: 1e-6)
        XCTAssertEqual(WaveformScroll.level(in: levels, at: 1.5), 0.7, accuracy: 1e-6)
        XCTAssertEqual(WaveformScroll.level(in: levels, at: 2), 1, accuracy: 1e-6)
    }

    func testTheMixIsLinearBecauseAnEaseWouldPulseTheSpeed() {
        // Linear and NOT a smoothstep, which is the shape a "smoother" instinct reaches for: an
        // ease starts and ends at rest, so the row would stop dead at every level boundary and
        // sprint through the middle -- a 23 Hz pulsation in the scroll speed, i.e. a new stutter
        // in place of the old one. Halfway between two levels must be halfway, not eased.
        let levels: [Float] = [0, 1]
        for fraction in stride(from: 0.0, through: 1.0, by: 0.125) {
            XCTAssertEqual(
                WaveformScroll.level(in: levels, at: fraction), Float(fraction), accuracy: 1e-6)
        }
    }

    func testAPositionOutsideTheRingClampsRatherThanWrapping() {
        // Wrapping would run the oldest end of the window back over the newest: a second ago
        // drawn as if it were now.
        let levels: [Float] = [0.1, 0.5, 0.9]
        XCTAssertEqual(WaveformScroll.level(in: levels, at: -5), 0.1)
        XCTAssertEqual(WaveformScroll.level(in: levels, at: 99), 0.9)
        XCTAssertEqual(WaveformScroll.level(in: [], at: 1), AudioLevelMeter.floorHeight)
    }

    // MARK: - Assembling the reading

    func testTheAgeOfTheNewestLevelIncludesTheBlockStillBeingMeasured() {
        // The part-block is audio that has already happened. Counting only the time since the
        // buffer arrived is what makes the head lurch backwards at the buffers that complete one
        // level instead of two.
        let reading = WaveformReading.since(
            levels: [0.2, 0.4], sinceLastBuffer: 0.01, pendingFrames: 2_064,
            sampleRate: 48_000, burst: 2)

        XCTAssertEqual(reading.sinceNewest, 0.01 + 0.043, accuracy: 1e-9)
    }

    func testWithNothingCarriedTheAgeIsSimplyTheTimeSinceTheBuffer() {
        let reading = WaveformReading.since(
            levels: [0.2], sinceLastBuffer: 0.02, pendingFrames: 0, sampleRate: 48_000, burst: 1)

        XCTAssertEqual(reading.sinceNewest, 0.02, accuracy: 1e-9)
    }

    func testAReadingTakenBeforeTheFirstBufferHasNoNegativeAge() {
        let reading = WaveformReading.since(
            levels: [0.2], sinceLastBuffer: -0.5, pendingFrames: 0, sampleRate: 48_000, burst: 0)

        XCTAssertEqual(reading.sinceNewest, 0)
    }

    func testASampleRateOfZeroDoesNotDivideItsWayToAnInfiniteAge() {
        // `begin` is called with the hardware format, and an unplugged device reports zero.
        let reading = WaveformReading.since(
            levels: [0.2, 0.5], sinceLastBuffer: 0.01, pendingFrames: 900, sampleRate: 0, burst: 1)

        XCTAssertEqual(reading.sinceNewest, 0.01, accuracy: 1e-9)
        XCTAssertFalse(WaveformScroll.heights(reading, count: 4).contains { $0.isNaN })
    }

    // MARK: - The margin

    func testTheMarginCoversAWholeBufferPlusSlackForALateOne() {
        // A margin at or below the burst clamps once per buffer, every buffer.
        XCTAssertGreaterThan(WaveformScroll.margin(burst: 2), 2 + 1)
        XCTAssertGreaterThan(WaveformScroll.margin(burst: 1), 1 + 1)
        XCTAssertGreaterThan(WaveformScroll.margin(burst: 5), 5 + 1)
    }

    func testARecordingThatHasDeliveredNothingYetStillHasAMargin() {
        // `burst` is 0 until the first buffer, and a margin of 0 would put the head on a level
        // that does not exist.
        XCTAssertEqual(WaveformScroll.margin(burst: 0), WaveformScroll.margin(burst: 1))
        XCTAssertGreaterThanOrEqual(WaveformScroll.margin(burst: 0), 2)
    }

    func testAMarginGrowsWithTheBurstSoASlowerDeviceStillSlides() {
        XCTAssertGreaterThan(WaveformScroll.margin(burst: 4), WaveformScroll.margin(burst: 2))
    }

    func testTheMarginIsAlsoBoundedAbove_BecauseItIsLatency() {
        // The margin IS the delay between the microphone and the drawing, and nothing else in this
        // file would notice it growing: every continuity assertion passes just as well with the
        // head parked further back. At this Mac's burst of two it must stay under four levels, i.e.
        // under 172 ms at the worst phase and 86 ms on average -- past that the waveform stops
        // reading as a response to the voice, which is a different complaint from the one being
        // fixed and would be just as real.
        XCTAssertLessThanOrEqual(WaveformScroll.margin(burst: 2), 4)
        XCTAssertLessThanOrEqual(
            WaveformScroll.margin(burst: 2) * WaveformLayout.blockDuration, 0.172)
    }

    func testTheHeadIsAlwaysAPositionInsideTheRing() {
        // It is documented as a fractional index into `levels` and `heights` offsets from it, so a
        // value outside the ring would be a contract broken quietly -- the row would still draw,
        // because reading a level clamps too, and nothing would say the head had left.
        for count in [2, 3, 31] {
            for burst in [0, 2, 40] {
                for age in [0.0, 0.02, 0.5, 90.0] {
                    let reading = WaveformReading(
                        levels: [Float](repeating: 0.3, count: count), sinceNewest: age,
                        burst: burst)
                    let head = WaveformScroll.head(reading)
                    XCTAssertGreaterThanOrEqual(head, 0, "count \(count), burst \(burst)")
                    XCTAssertLessThanOrEqual(head, Double(count - 1))
                }
            }
        }
    }

    func testAMarginNeverExceedsTheLookBackTheRingKeeps() {
        // Past the headroom the oldest bar of a full row reads off the end of the history and
        // clamps -- a stepping left edge, which is worse than the occasional freeze the cap trades
        // it for. Unreachable by any buffer size a Mac hands out; pinned because it is silent.
        XCTAssertEqual(
            WaveformScroll.margin(burst: 40), Double(WaveformLayout.scrollHeadroom))
    }

    // MARK: - Nothing here may produce a NaN or an empty row

    func testAStalledRecordingFreezesOnTheNewestLevelRatherThanRunningOffTheEnd() {
        // The engine stopping, or the view being drawn after `stop()`: the age grows without
        // bound and the head must simply sit at the newest level.
        let levels: [Float] = [0.2, 0.4, 0.6, 0.8]
        let stalled = WaveformReading(levels: levels, sinceNewest: 600, burst: 2)

        let drawn = WaveformScroll.heights(stalled, count: 4)
        XCTAssertEqual(drawn, levels)
        XCTAssertFalse(drawn.contains { $0.isNaN })
    }

    func testADegenerateBlockDurationFreezesOnTheNewestLevel() {
        // Dividing an age by it would be an infinity or, at an age of zero, a NaN -- and SwiftUI
        // draws a NaN frame as nothing at all. Freezing on the newest level draws the ring, which
        // is the row the waveform had before any of this.
        let reading = WaveformReading(levels: [0.3, 0.7], sinceNewest: 0.01, burst: 1)
        let drawn = WaveformScroll.heights(reading, count: 2, blockDuration: 0)

        XCTAssertEqual(drawn, [0.3, 0.7])
        XCTAssertFalse(drawn.contains { $0.isNaN })

        let atZeroAge = WaveformScroll.heights(
            WaveformReading(levels: [0.3, 0.7], sinceNewest: 0, burst: 1),
            count: 2, blockDuration: 0)
        XCTAssertEqual(atZeroAge, [0.3, 0.7])
    }

    func testNoLevelsMeansTheFloorAndNotAnEmptyRow() {
        // An empty row is a surface with nothing drawn on it, which reads as a failure. A flat
        // row at the floor is what silence looks like anyway.
        let drawn = WaveformScroll.heights(
            WaveformReading(levels: [], sinceNewest: 0, burst: 0), count: 6)

        XCTAssertEqual(drawn, [Float](repeating: AudioLevelMeter.floorHeight, count: 6))
    }

    func testASingleLevelIsARowOfThatLevel() {
        let drawn = WaveformScroll.heights(
            WaveformReading(levels: [0.55], sinceNewest: 0.02, burst: 1), count: 4)

        XCTAssertEqual(drawn, [0.55, 0.55, 0.55, 0.55])
    }

    func testAskingForNoBarsIsNotACrash() {
        XCTAssertEqual(
            WaveformScroll.heights(
                WaveformReading(levels: [0.3], sinceNewest: 0, burst: 1), count: 0),
            [])
    }

    func testANegativeAgeIsTreatedAsNoAgeAtAll() {
        // Two reads of a monotonic clock cannot invert, but nothing here should depend on that.
        let levels: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let backwards = WaveformReading(levels: levels, sinceNewest: -1, burst: 1)

        XCTAssertEqual(
            WaveformScroll.head(backwards),
            WaveformScroll.head(WaveformReading(levels: levels, sinceNewest: 0, burst: 1)))
    }
}
