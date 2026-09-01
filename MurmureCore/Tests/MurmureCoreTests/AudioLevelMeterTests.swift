import XCTest
@testable import MurmureCore

/// The waveform is the only thing the notch shows while Louis speaks, and the app target that
/// draws it has no test bundle. So everything the eye could catch about it -- a wing that empties
/// on a pause, a bar that leaves the notch, a meter that lags behind the voice -- has to be a row
/// here, where the arithmetic lives.
final class AudioLevelMeterTests: XCTestCase {
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
        // A bar taller than 1 would be drawn outside the notch. Full scale is the top of the wing,
        // and anything a clipping microphone sends beyond it stays there.
        XCTAssertEqual(AudioLevelMeter.height(forRootMeanSquare: 1), 1)
        XCTAssertEqual(AudioLevelMeter.height(forRootMeanSquare: 4), 1)
        let saturated = [Float](repeating: 1, count: 2_048)
        XCTAssertEqual(AudioLevelMeter.height(forRootMeanSquare: AudioLevelMeter.rootMeanSquare(of: saturated)), 1)
    }

    func testOrdinarySpeechUsesTheMiddleOfTheWingRatherThanItsFirstFewPoints() {
        // The reason the scale is logarithmic. Louis's dictations sit around 0.02...0.15 RMS; on a
        // linear scale every one of them would be a bar under a fifth of the wing and the rest of
        // the height would be reserved for a shout nobody does.
        let speech = AudioLevelMeter.height(forRootMeanSquare: 0.05)
        XCTAssertGreaterThan(speech, 0.4)
        XCTAssertLessThan(speech, 0.8)
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
        XCTAssertGreaterThan(climbed, dropped * 2)
    }
}
