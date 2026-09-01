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
/// - **The scale is logarithmic.** A linear map of RMS would leave ordinary speech (0.02…0.15 RMS)
///   in the bottom seventh of the wing and reserve the rest for a shout.
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

    /// How much of the distance to a *louder* level is covered per block. High: a syllable has to
    /// be on screen while it is being said, and a 20 Hz meter that took five blocks to rise would
    /// lag a quarter of a second behind the voice.
    public static let attack: Float = 0.6

    /// How much of the distance to a *quieter* level is covered per block. Much lower than the
    /// attack: the gaps between syllables are real silence, and a fall as fast as the rise would
    /// make the wings strobe on every consonant.
    public static let release: Float = 0.2

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
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Array overload, for callers that already hold one (the tests).
    public static func rootMeanSquare(of samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rootMeanSquare(of: $0) }
    }

    /// The bar height an RMS deserves: `floorHeight` at or below the floor, 1 at full scale, and a
    /// decibel-linear ramp in between.
    ///
    /// The comparison is written as `rms > floorRootMeanSquare` rather than as a clamp so that a
    /// `NaN` -- every comparison against which is false -- takes the floor branch instead of
    /// reaching `log10`.
    public static func height(forRootMeanSquare rms: Float) -> Float {
        guard rms > floorRootMeanSquare else { return floorHeight }
        guard rms < 1 else { return 1 }
        let floorDecibels = 20 * log10(floorRootMeanSquare)
        let fraction = (20 * log10(rms) - floorDecibels) / -floorDecibels
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
