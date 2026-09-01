import XCTest
@testable import MurmureCore

/// A fixed instant to count from, for the same reason `NotchPresenterTests` uses one: at
/// `timeIntervalSinceReferenceDate: 0` the boundary arithmetic below is exact.
private let t0 = Date(timeIntervalSinceReferenceDate: 0)

/// The shortest angular distance between two hues, in degrees.
private func hueDistance(_ a: Double, _ b: Double) -> Double {
    let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(raw, 360 - raw)
}

final class NotchAppearanceTests: XCTestCase {
    // MARK: - Whether there is a shape at all

    /// Only `hidden` costs zero pixels (lot 3 D4). `nothingHeard` in particular must have a
    /// window: it is the phase whose whole job is to be seen saying that nothing got through.
    func testEveryPhaseButHiddenHasAShape() {
        XCTAssertFalse(NotchAppearance.showsShape(in: .hidden))
        let visible: [NotchPhase] = [
            .recording, .transcribing, .refining, .inserting,
            .completed(insertedCharacters: 12), .nothingHeard,
            .failed(message: "boom", recoveredText: nil), .alert(message: "accessibility"),
        ]
        for phase in visible {
            XCTAssertTrue(NotchAppearance.showsShape(in: phase), "\(phase) must have a window")
        }
    }

    // MARK: - Which family of drawing a phase belongs to

    func testEachPhaseDrawsItsOwnFamily() {
        XCTAssertEqual(NotchAppearance.mark(for: .hidden), .none)
        XCTAssertEqual(NotchAppearance.mark(for: .recording), .waveform)
        XCTAssertEqual(NotchAppearance.mark(for: .refining), .pulsing)
        XCTAssertEqual(NotchAppearance.mark(for: .completed(insertedCharacters: 3)), .success)
        XCTAssertEqual(NotchAppearance.mark(for: .nothingHeard), .quiet)
        XCTAssertEqual(
            NotchAppearance.mark(for: .failed(message: "boom", recoveredText: nil)), .warning)
        XCTAssertEqual(NotchAppearance.mark(for: .alert(message: "revoked")), .warning)
    }

    /// The plan gives `inserting` no appearance of its own -- it lasts one CGEvent round-trip. So
    /// it must draw what `transcribing` draws, not something briefly different: a crossfade lasting
    /// two frames in the middle of a sequence whose one criterion is that it never jumps is exactly
    /// the flicker that criterion forbids.
    func testInsertingIsDrawnAsATranscriptionAndNotAsItsOwnThing() {
        XCTAssertEqual(NotchAppearance.mark(for: .transcribing), .travelling)
        XCTAssertEqual(NotchAppearance.mark(for: .inserting), .travelling)
    }

    /// A silence must never be drawn the way a success is. This is the same decision
    /// `NotchPhase.nothingHeard` exists for, held one layer further down: even if the phases were
    /// confused upstream, the two families are not the same family.
    func testASilenceIsNeverDrawnAsASuccess() {
        XCTAssertNotEqual(
            NotchAppearance.mark(for: .nothingHeard),
            NotchAppearance.mark(for: .completed(insertedCharacters: 1)))
    }

    // MARK: - Whether the drawing is mirrored

    /// **The waveform is the only mark that is data over time, and the only one drawn once.**
    /// Mirroring it drew the newest level twice, against the join, on both sides -- and made every
    /// peak appear in the middle and travel outward in both directions, which is the ripple Louis
    /// asked three times to be rid of. A mark that is not data -- a dot, a pulse, a tick -- has no
    /// direction to read, so its symmetry is a shape rather than a claim about time.
    func testOnlyTheWaveformIsDrawnAsASingleUnmirroredRun() {
        XCTAssertFalse(NotchAppearance.isMirrored(.waveform))
        for mark in [NotchAppearance.Mark.none, .travelling, .pulsing, .success, .quiet, .warning] {
            XCTAssertTrue(NotchAppearance.isMirrored(mark), "\(mark) must stay mirrored")
        }
    }

    /// Asked of a phase it goes through the mark, so two phases that share a family share the
    /// answer and the two surfaces cannot disagree about a phase either.
    func testAPhaseInheritsTheAnswerFromItsMark() {
        XCTAssertFalse(NotchAppearance.isMirrored(for: .recording))
        XCTAssertTrue(NotchAppearance.isMirrored(for: .transcribing))
        XCTAssertEqual(
            NotchAppearance.isMirrored(for: .inserting),
            NotchAppearance.isMirrored(for: .transcribing))
        XCTAssertTrue(NotchAppearance.isMirrored(for: .completed(insertedCharacters: 4)))
        XCTAssertTrue(NotchAppearance.isMirrored(for: .nothingHeard))
    }

    // MARK: - The clock a mark's animation counts from

    /// The point of the family split: the `transcribing` → `inserting` hand-off must not restart
    /// the travelling mark, which would send it back behind the cutout mid-flight on every single
    /// dictation.
    func testAPhaseChangeInsideTheSameFamilyKeepsTheAnimationRunning() {
        XCTAssertEqual(
            NotchAppearance.animationStart(
                previousMark: .travelling, previousStart: t0,
                newMark: .travelling, now: t0.addingTimeInterval(4)),
            t0)
    }

    /// And a change of family does restart it, or a pulse would open at whatever point of its
    /// breath the previous phase happened to leave the clock at.
    func testAChangeOfFamilyRestartsTheAnimation() {
        let now = t0.addingTimeInterval(4)
        XCTAssertEqual(
            NotchAppearance.animationStart(
                previousMark: .travelling, previousStart: t0, newMark: .pulsing, now: now),
            now)
    }

    // MARK: - transcribing, the travelling mark

    /// It leaves the cutout and runs outwards, in that order. Reversed, the notch would look like
    /// it was swallowing something during the phase where it is producing one.
    func testTheMarkTravelsFromTheCutoutOutwards() {
        let early = NotchAppearance.markDistanceOutward(
            elapsed: NotchAppearance.travelPeriod * 0.25)
        let late = NotchAppearance.markDistanceOutward(
            elapsed: NotchAppearance.travelPeriod * 0.75)
        XCTAssertLessThan(early, late)
    }

    /// The mark is teleported from the far end back to the near one at the end of every cycle.
    /// The only thing that keeps that from being seen is that it is entirely outside the wing at
    /// both instants -- so both ends are asserted with the mark's own length taken into account,
    /// not just its centre.
    func testTheMarkIsCompletelyOutOfTheWingAtBothEndsOfItsCycle() {
        let half = NotchAppearance.markWidth / 2
        let atStart = NotchAppearance.markDistanceOutward(elapsed: 0)
        XCTAssertLessThanOrEqual(atStart + half, 0, "the mark is still visible when it wraps back")
        let atEnd = NotchAppearance.markDistanceOutward(
            elapsed: NotchAppearance.travelPeriod * 0.9999)
        XCTAssertGreaterThanOrEqual(
            atEnd - half, 1, "the mark is still visible when it is teleported away")
    }

    /// It repeats. A sweep that ran once and stopped would say "something happened", where the
    /// whole message of this phase is "something is still happening".
    func testTheSweepRepeatsEveryPeriod() {
        XCTAssertEqual(
            NotchAppearance.markDistanceOutward(elapsed: 0.2),
            NotchAppearance.markDistanceOutward(
                elapsed: 0.2 + NotchAppearance.travelPeriod * 3),
            accuracy: 1e-9)
    }

    /// A display link can hand the view a date a hair ahead of the instant the phase was recorded,
    /// which arrives here as a negative elapsed. It reads as the start of the cycle, not as a mark
    /// wrapped round to somewhere in the middle of one.
    func testANegativeElapsedReadsAsTheStartOfTheSweep() {
        // -3.5 rather than a whole number of periods on purpose: a negative elapsed that happens to
        // be a whole cycle wraps to the start anyway, and would pass with no clamp at all.
        XCTAssertEqual(
            NotchAppearance.markDistanceOutward(elapsed: -3.5),
            NotchAppearance.markDistanceOutward(elapsed: 0),
            accuracy: 1e-12)
    }

    // MARK: - refining, the breath

    /// It uses the whole of the range the view maps onto an opacity. Half a range would be a bar
    /// that never quite dims and never quite brightens, i.e. a bar the eye stops reading as moving
    /// at all -- which during a 19 s wait is the same as showing nothing.
    ///
    /// Swept rather than sampled at the two instants a cosine happens to peak, so that a *shape*
    /// other than this one -- the sawtooth the seam test below refuses, say -- is still measured
    /// on its range rather than failing here for the wrong reason.
    func testThePulseSpansItsWholeRangeWithinOnePeriod() {
        var lowest = Double.infinity
        var highest = -Double.infinity
        for step in 0...2000 {
            let value = NotchAppearance.pulse(
                elapsed: NotchAppearance.pulsePeriod * Double(step) / 2000)
            lowest = min(lowest, value)
            highest = max(highest, value)
        }
        XCTAssertEqual(lowest, 0, accuracy: 0.001)
        XCTAssertEqual(highest, 1, accuracy: 0.001)
    }

    /// Bounded, at every instant of a 57.5 s worst-case refinement. An opacity outside 0…1 is a
    /// clamp somewhere else deciding what the wing looks like.
    func testThePulseStaysInsideItsRangeForTheWholeOfTheWorstRefinement() {
        for step in 0...5750 {
            let value = NotchAppearance.pulse(elapsed: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    /// The one property that makes it a breath rather than a blink: the cycle ends where it began,
    /// so the loop has no seam. A sawtooth would satisfy every other test here and flick the wing
    /// from full to nothing once every period.
    func testThePulseEndsTheCycleWhereItStartedIt() {
        XCTAssertEqual(
            NotchAppearance.pulse(elapsed: NotchAppearance.pulsePeriod * 0.999),
            NotchAppearance.pulse(elapsed: 0),
            accuracy: 0.001)
    }

    /// It opens at its minimum, so the accent fades up out of the white mark that preceded it.
    /// Starting at full strength would put a bright violet bar on screen in the same frame the
    /// travelling mark left, which is a pop inside a shape that is meant to have merely changed
    /// its mind.
    func testThePulseOpensAtItsMinimum() {
        for step in 0...260 {
            XCTAssertGreaterThanOrEqual(
                NotchAppearance.pulse(elapsed: Double(step) / 100),
                NotchAppearance.pulse(elapsed: 0))
        }
    }

    /// Half of what tells `refining` from `transcribing` is tempo. A pulse only slightly slower
    /// than the sweep would read as the same motion running a little differently, which is to say
    /// as nothing at all -- and this is the phase that has to survive a 19 s median wait being
    /// told apart from a transcription of seconds.
    func testTheBreathIsAtLeastTwiceAsSlowAsTheSweep() {
        XCTAssertGreaterThanOrEqual(
            NotchAppearance.pulsePeriod, 2 * NotchAppearance.travelPeriod)
    }

    // MARK: - The one accent

    /// Anti-goal §8: no sampled brand colours. Design notes §2 measured Superwhisper's accent as
    /// `#3C7FF5` (hue 218°) and its indigo as `#7675E4` (240°); the completion's green (~120°) and
    /// a failure's orange (~30°) are system semantics already spoken for. The accent has to stay
    /// clear of all four, and this is the constraint rather than the taste -- 292° is one answer
    /// inside it and Louis may pick another, but not one of these.
    func testTheAccentIsNobodyElsesColourAndNotOneAlreadyMeaningSomething() {
        let accent = NotchAppearance.accentHue * 360
        for theirs in [218.0, 240.0] {
            XCTAssertGreaterThan(
                hueDistance(accent, theirs), 50, "the accent is Superwhisper's, at \(theirs)°")
        }
        for taken in [120.0, 30.0] {
            XCTAssertGreaterThan(
                hueDistance(accent, taken), 90, "the accent collides with the \(taken)° semantic")
        }
    }

    /// Every component is a value SwiftUI's `Color(hue:saturation:brightness:)` accepts. Outside
    /// 0…1 it clamps silently, and a hue that clamped would be a colour nobody chose.
    func testTheAccentComponentsAreExpressedTheWaySwiftUICountsThem() {
        for component in [
            NotchAppearance.accentHue, NotchAppearance.accentSaturation,
            NotchAppearance.accentBrightness, NotchAppearance.pulseFloor,
        ] {
            XCTAssertGreaterThanOrEqual(component, 0)
            XCTAssertLessThanOrEqual(component, 1)
        }
    }

    /// The pulse never reaches nothing. An empty wing is what `hidden` looks like, and offering it
    /// once every 2.6 s during the longest wait in the app -- the one moment Louis is asking
    /// whether it is still alive -- answers the question wrongly twice a minute.
    func testTheBreathNeverEmptiesTheWing() {
        XCTAssertGreaterThan(NotchAppearance.pulseFloor, 0)
    }
}
