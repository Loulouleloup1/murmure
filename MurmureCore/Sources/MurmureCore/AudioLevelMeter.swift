import Foundation

/// Turns the loudness of a block of audio into the height of a waveform bar, 0…1.
///
/// The whole of the waveform's arithmetic lives here, in the package, because the wings that draw
/// it live in the app target and the app target has no test bundle. What the view is left with is
/// a multiplication by a point size.
///
/// Three properties are deliberate, and each of them is a thing the eye would otherwise catch:
///
/// - **Silence is the floor, not zero.** A bar of height 0 is a bar that is not there, so a silent
///   moment would empty the wings and the notch would read as "nothing is happening" during the
///   very pause Louis takes mid-sentence. The floor is a visible flat line -- Superwhisper's Mini
///   at rest is exactly that, a thin dark bar (design notes §3), and it is the register the
///   recording state needs when the voice drops.
/// - **The floor is `SpeechGate.energyThreshold`** (lot 3 D12), the RMS measured over Louis's
///   1 482 dictations as the level below which a frame is not voiced. Reusing it means the
///   waveform is flat exactly when the gate would reject what it is drawing, so what he sees
///   predicts what he gets.
/// - **The scale is logarithmic, between two measured RMS values.** A linear map would leave
///   ordinary speech in the bottom tenth of the wing; but a log map that still ran to *digital*
///   full scale wasted just as much, in the other direction — a MacBook's own microphone never
///   comes near 1.0, so the top half of the wing was reserved for a level the hardware cannot
///   produce. Both ends are now levels Louis's voice actually reaches (`floorRootMeanSquare`,
///   `ceilingRootMeanSquare`).
///
/// A consequence worth naming because it is the second thing Louis will look at: everything at or
/// below the floor maps to *exactly* the same height, so a silent wing does not shimmer. Noise
/// under the threshold cannot move a bar by a fraction of a point.
public struct AudioLevelMeter: Equatable {
    /// The RMS at which the scale bottoms out (lot 3 D12). Not a display choice: it is the gate's
    /// own voiced-frame threshold, and the two must not drift apart.
    public static let floorRootMeanSquare: Float = SpeechGate.energyThreshold

    /// The height a bar has at and below the floor.
    ///
    /// Not zero (see the type's note). ~0.2 of the wing's height is what makes a silent bar read
    /// as a deliberate flat line rather than as a rendering artefact; below that it disappears
    /// into the black of the notch.
    public static let floorHeight: Float = 0.18

    /// The RMS at which the scale tops out. **Measured, not 1.0.**
    ///
    /// Full scale used to be the top of the wing, and that was the bug Louis reported as "much too
    /// discreet": a MacBook's built-in microphone does not saturate on a voice. Over his own 26
    /// Murmure recordings that carry signal, scored with this app's exact block layout (2 048
    /// frames at 48 kHz), the RMS of a voiced block runs p10 = 0.0072, p50 = 0.0158, p90 = 0.0306,
    /// p99 = 0.0482 — the whole of ordinary speech inside 0.005…0.05, three percent of the range the
    /// scale was drawn against. Ninety percent of the wing's height was unreachable.
    ///
    /// 0.06 is just above that p99, which is what makes the top *reachable but not permanent*: on
    /// those recordings no file spends more than 18 % of its speech at full height and the median
    /// file spends 0 %, so a loud sentence tops out and a normal one visibly does not. Lowering it
    /// further (0.05, 0.04) buys a point of height and starts pinning whole quiet-room sessions.
    public static let ceilingRootMeanSquare: Float = 0.06

    /// How much of the distance to a *louder* level is covered per block. High: a syllable has to
    /// be on screen while it is being said, and a 20 Hz meter that took five blocks to rise would
    /// lag a quarter of a second behind the voice.
    public static let attack: Float = 0.7

    /// How much of the distance to a *quieter* level is covered per block. Lower than the attack:
    /// the gaps between syllables are real silence, and a fall as fast as the rise would make the
    /// wings strobe on every consonant.
    ///
    /// It is nonetheless faster than it was (0.2), and the reason is measured. Fed the real
    /// recordings, a release of 0.2 took 516 ms to give up nine tenths of a drop — longer than a
    /// whole wing is wide in time (six bars × 43 ms = 258 ms), so every bar on screen held the
    /// loudest thing said in the last half-second and the six of them were one flat plateau. At
    /// 0.3 that fall takes 344 ms and the plateau breaks up. The two coefficients are still
    /// asymmetric better than 2:1, which is the property that keeps a consonant from strobing.
    public static let release: Float = 0.3

    /// The root mean square of a block of samples, 0 for an empty one.
    ///
    /// The empty case is the whole reason this is a function and not two lines at the call site:
    /// `sqrt(0/0)` is `NaN`, a `NaN` height propagates through the smoothing into the view, and
    /// SwiftUI draws a `NaN` frame as nothing at all -- a waveform that vanishes when a buffer
    /// arrives short. An input device being unplugged mid-recording is how that buffer arrives.
    ///
    /// Takes a buffer pointer rather than an array because the caller is the audio thread, which
    /// must not allocate: this reads the tap buffer's own memory in place.
    public static func rootMeanSquare(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (sumOfSquares(of: samples) / Float(samples.count)).squareRoot()
    }

    /// The sum of the squares of a run of samples — half a root mean square, and the half that
    /// can be added up across calls.
    ///
    /// It exists because a block of audio is no longer guaranteed to arrive in one piece.
    /// `AudioLevels` measures exactly `blockDuration` of audio per level whatever frame count the
    /// tap hands it, so a block routinely spans two tap buffers; the sum survives that boundary,
    /// where an RMS could only have been averaged with an RMS — which is not the RMS of the two
    /// runs together unless they happen to be the same length.
    public static func sumOfSquares(of samples: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sum
    }

    /// Array overload, for callers that already hold one (the tests).
    public static func rootMeanSquare(of samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rootMeanSquare(of: $0) }
    }

    /// The bar height an RMS deserves: `floorHeight` at or below the floor, 1 at or above the
    /// ceiling, and a decibel-linear ramp across the ~21.6 dB in between.
    ///
    /// The comparison is written as `rms > floorRootMeanSquare` rather than as a clamp so that a
    /// `NaN` -- every comparison against which is false -- takes the floor branch instead of
    /// reaching `log10`. The second guard is `>=` for the same shape of reason: it catches
    /// everything a clipping microphone could send, up to and past digital full scale.
    public static func height(forRootMeanSquare rms: Float) -> Float {
        guard rms > floorRootMeanSquare else { return floorHeight }
        guard rms < ceilingRootMeanSquare else { return 1 }
        let floorDecibels = 20 * log10(floorRootMeanSquare)
        let ceilingDecibels = 20 * log10(ceilingRootMeanSquare)
        let fraction = (20 * log10(rms) - floorDecibels) / (ceilingDecibels - floorDecibels)
        return floorHeight + (1 - floorHeight) * fraction
    }

    /// The height as it stands, after every block accepted so far.
    public private(set) var height: Float

    public init(height: Float = AudioLevelMeter.floorHeight) {
        self.height = height
    }

    /// Advances the meter by one block, and returns the height to draw.
    ///
    /// A first-order filter, asymmetric by design (see `attack`/`release`). It cannot overshoot:
    /// both coefficients are in `0…1`, so the result always lies between the previous height and
    /// the target, which is what keeps the wings inside the notch whatever the microphone does.
    @discardableResult
    public mutating func accept(rootMeanSquare rms: Float) -> Float {
        let target = Self.height(forRootMeanSquare: rms)
        let coefficient = target > height ? Self.attack : Self.release
        height += (target - height) * coefficient
        return height
    }
}
