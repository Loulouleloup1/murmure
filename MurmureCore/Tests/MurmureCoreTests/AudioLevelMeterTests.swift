import XCTest
@testable import MurmureCore

/// The waveform is the only thing the notch shows while Louis speaks, and the app target that
/// draws it has no test bundle. So everything the eye could catch about it -- a wing that empties
/// on a pause, a bar that leaves the notch, a meter that lags behind the voice -- has to be a row
/// here, where the arithmetic lives.
final class AudioLevelMeterTests: XCTestCase {
    /// What a voiced block of Louis's own dictations actually measures, at this app's block size.
    ///
    /// From the 26 recordings in `~/Library/Application Support/Murmure/recordings` that carry a
    /// signal, scored with `AudioLevels`' exact layout (2 048 frames at 48 kHz): 4 812 blocks above
    /// the gate's threshold. These are the inputs the calibration below has to be right about --
    /// every earlier number in this file was a guess at them.
    private enum MeasuredSpeech {
        static let p10: Float = 0.0072
        static let p50: Float = 0.0158
        static let p90: Float = 0.0306
        static let p99: Float = 0.0482
        /// The level between his phrases: p50 0.0006, p99 0.0047, none of it above the gate.
        static let roomTone: [Float] = [0, 0.0002, 0.0006, 0.001, 0.0026, 0.0047, 0.0049]
    }

    // MARK: - What silence looks like

    func testSilenceIsTheFloorAndNotZeroHeight() {
        // A bar of height 0 is a bar that is not there: the wings would empty on every pause
        // mid-sentence and the notch would say the dictation had stopped. Silence is a flat line.
        for silent: Float in [0, 0.0001, 0.001, AudioLevelMeter.floorRootMeanSquare] {
            XCTAssertEqual(AudioLevelMeter.height(forRootMeanSquare: silent), AudioLevelMeter.floorHeight)
        }
        XCTAssertGreaterThan(AudioLevelMeter.floorHeight, 0)
    }

    func testEverythingUnderTheFloorHasTheSameHeightSoASilentWingCannotShimmer() {
        // Room tone is not a constant: it wanders between blocks. If it moved the bars at all,
        // the notch would twitch for the whole of a pause. The clamp is what makes it still.
        let quiet = (0..<20).map { Float($0) * AudioLevelMeter.floorRootMeanSquare / 20 }
        let heights = Set(quiet.map { AudioLevelMeter.height(forRootMeanSquare: $0) })
        XCTAssertEqual(heights, [AudioLevelMeter.floorHeight])
    }

    func testTheFloorIsTheGateSOwnVoicedThreshold() {
        // Lot 3 D12. The waveform is flat exactly where `SpeechGate` stops counting a frame as
        // voiced, so what Louis sees predicts what he gets. Two constants that drift apart would
        // show him a moving bar for audio the gate is about to reject.
        XCTAssertEqual(AudioLevelMeter.floorRootMeanSquare, SpeechGate.energyThreshold)
        XCTAssertGreaterThan(
            AudioLevelMeter.height(forRootMeanSquare: SpeechGate.energyThreshold * 1.5),
            AudioLevelMeter.floorHeight
        )
    }

    // MARK: - What loud looks like

    func testFullScaleIsOne() {
        // A bar taller than 1 would be drawn outside the notch. Digital full scale is now far past
        // the top of the wing rather than at it, so this is no longer the calibration -- it is the
        // clamp: anything a clipping microphone sends stays at 1, up to and beyond 1.0 RMS.
        XCTAssertEqual(AudioLevelMeter.height(forRootMeanSquare: 1), 1)
        XCTAssertEqual(AudioLevelMeter.height(forRootMeanSquare: 4), 1)
        let saturated = [Float](repeating: 1, count: 2_048)
        XCTAssertEqual(AudioLevelMeter.height(forRootMeanSquare: AudioLevelMeter.rootMeanSquare(of: saturated)), 1)
    }

    func testOrdinarySpeechUsesTheMiddleOfTheWingRatherThanItsFirstFewPoints() {
        // The reason the scale is logarithmic -- and the reason it stops at a measured ceiling.
        // This row used to read 0.05 RMS as "ordinary speech"; the recordings say 0.05 is his 99th
        // percentile and his median is 0.0158, so the scale was being judged three times louder
        // than he speaks. At the median he has to land near the middle of the wing, with height
        // left above him.
        let speech = AudioLevelMeter.height(forRootMeanSquare: MeasuredSpeech.p50)
        XCTAssertGreaterThan(speech, 0.45)
        XCTAssertLessThan(speech, 0.7)
    }

    func testTheBandHeActuallySpeaksInFillsMostOfTheWing() {
        // The defect Louis reported, written as a number. Against a scale that ran to digital full
        // scale, p10...p90 of his voiced blocks spanned 0.22 of the wing -- 3.5 pt of 16, with the
        // top half reserved for a saturation a MacBook microphone cannot produce.
        let quiet = AudioLevelMeter.height(forRootMeanSquare: MeasuredSpeech.p10)
        let loud = AudioLevelMeter.height(forRootMeanSquare: MeasuredSpeech.p90)
        XCTAssertGreaterThan(loud - quiet, 0.45)
        // And both ends stay inside the wing: the quiet one above the flat line so it reads as
        // speech, the loud one below the top so there is somewhere left to go.
        XCTAssertGreaterThan(quiet, AudioLevelMeter.floorHeight)
        XCTAssertLessThan(loud, 1)
    }

    func testTheTopIsReachableWithoutBeingWhereOrdinarySpeechAlreadySits() {
        // Both halves of "no permanent clipping". The ceiling is a level his voice does reach, so
        // the top of the wing is not dead height; and it is above his 99th percentile, so a loud
        // sentence is still taller than a normal one rather than both being pinned at 1.
        XCTAssertLessThan(AudioLevelMeter.ceilingRootMeanSquare, 1)
        XCTAssertEqual(
            AudioLevelMeter.height(forRootMeanSquare: AudioLevelMeter.ceilingRootMeanSquare), 1
        )
        XCTAssertGreaterThan(AudioLevelMeter.ceilingRootMeanSquare, MeasuredSpeech.p99)
        let normal = AudioLevelMeter.height(forRootMeanSquare: MeasuredSpeech.p50)
        let loud = AudioLevelMeter.height(forRootMeanSquare: MeasuredSpeech.p90)
        let shouted = AudioLevelMeter.height(forRootMeanSquare: MeasuredSpeech.p99)
        XCTAssertLessThan(normal, loud)
        XCTAssertLessThan(loud, shouted)
        XCTAssertLessThan(shouted, 1)
    }

    // MARK: - The buffer that arrives short

    func testAnEmptyBufferYieldsNoNaN() {
        // An input device unplugged mid-recording delivers one. `sqrt(0/0)` is NaN, SwiftUI draws
        // a NaN frame as nothing, and the NaN would then live in the meter for the rest of the
        // dictation -- the waveform would not come back when the device did.
        XCTAssertEqual(AudioLevelMeter.rootMeanSquare(of: [Float]()), 0)
        var meter = AudioLevelMeter()
        let height = meter.accept(rootMeanSquare: AudioLevelMeter.rootMeanSquare(of: []))
        XCTAssertFalse(height.isNaN)
        XCTAssertEqual(height, AudioLevelMeter.floorHeight)
    }

    func testRootMeanSquareIsTheEnergyOfTheBlockAndNotItsAverageLevel() {
        // A block that is one loud sample and silence has an RMS of 0.5, not 0.25: a plosive is
        // meant to move the bar. This is also what makes the constant blocks below exact.
        XCTAssertEqual(AudioLevelMeter.rootMeanSquare(of: [1, 0, 0, 0]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioLevelMeter.rootMeanSquare(of: [0.2, -0.2, 0.2, -0.2]), 0.2, accuracy: 1e-6)
    }

    // MARK: - Smoothing

    func testTheRiseIsMonotonicAndStopsAtTheLevelItIsChasing() {
        // Monotonic because a bar that overshot and came back would read as a second syllable;
        // bounded because the target is the top of the wing and there is no notch above it.
        let target = AudioLevelMeter.height(forRootMeanSquare: 0.3)
        var meter = AudioLevelMeter()
        var previous = meter.height
        for _ in 0..<12 {
            let height = meter.accept(rootMeanSquare: 0.3)
            XCTAssertGreaterThan(height, previous)
            XCTAssertLessThanOrEqual(height, target)
            previous = height
        }
        XCTAssertEqual(previous, target, accuracy: 0.01)
    }

    func testTheFallIsMonotonicAndStopsAtTheFloor() {
        // The other half: nothing the microphone stops sending can push a bar below the flat line.
        var meter = AudioLevelMeter(height: 1)
        var previous = meter.height
        for _ in 0..<30 {
            let height = meter.accept(rootMeanSquare: 0)
            XCTAssertLessThan(height, previous)
            XCTAssertGreaterThanOrEqual(height, AudioLevelMeter.floorHeight)
            previous = height
        }
        XCTAssertEqual(previous, AudioLevelMeter.floorHeight, accuracy: 0.01)
    }

    func testRoomToneCannotMoveABarThatHasSettledOnTheFloor() {
        // The invariant Louis validated by eye, checked through the filter and not only through
        // the scale: the level between his phrases wanders, and every value of it has to leave the
        // bar exactly where it is. Not nearly -- exactly, or the wing shimmers for the whole of a
        // pause, and a taller scale would only make that shimmer easier to see.
        var meter = AudioLevelMeter()
        for tone in MeasuredSpeech.roomTone {
            XCTAssertEqual(meter.accept(rootMeanSquare: tone), AudioLevelMeter.floorHeight)
        }
    }

    func testTheSixBarsOfAWingMoveApartWhileASentenceIsSpoken() throws {
        // "Too discreet" is two defects, and this row is the second one. However tall the bars are,
        // a wing whose six bars are all the same height is a plateau; it is the release that
        // decides whether the gap after a syllable reaches the screen before the next syllable
        // covers it. A syllable and its gap, 43 ms each, through the real ring: the six bars span
        // 0.10 of the wing as shipped, 0.07 at the old release of 0.2, and 0.03 on the old scale.
        var meter = AudioLevelMeter()
        var wing = LevelHistory()
        for _ in 0..<12 {
            wing.append(meter.accept(rootMeanSquare: MeasuredSpeech.p50))
            wing.append(meter.accept(rootMeanSquare: 0))
        }
        let bars = wing.values
        let tallest = try XCTUnwrap(bars.max())
        let shortest = try XCTUnwrap(bars.min())
        XCTAssertGreaterThan(tallest - shortest, 0.08)
    }

    func testItCatchesTheVoiceInOneBlockAndLetsGoMoreSlowly() {
        // Asymmetric on purpose, and this is the pair of numbers Louis will judge by eye. A single
        // block -- about 43 ms -- has to carry the bar past the middle of the wing, or the
        // waveform visibly trails the syllable being said. The fall is slow because the gaps
        // between syllables are real silence, and letting go as fast as it grabs would strobe.
        var rising = AudioLevelMeter()
        var falling = AudioLevelMeter(height: 1)
        let climbed = rising.accept(rootMeanSquare: 1) - AudioLevelMeter.floorHeight
        let dropped = 1 - falling.accept(rootMeanSquare: 0)
        XCTAssertGreaterThan(rising.height, 0.5)
        // Strictly more than twice, *with room*. The bare `climbed > dropped * 2` this replaces was
        // satisfied at exactly 2.0 by floating-point luck, so the pair 0.6/0.3 -- a release raised
        // without the attack following it -- would have landed on the boundary and still passed.
        // A ratio that has to clear 2.2 is the same property, said so that it cannot be reached by
        // accident.
        XCTAssertGreaterThan(climbed / dropped, 2.2)
    }
}
