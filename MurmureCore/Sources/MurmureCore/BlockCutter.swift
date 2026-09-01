import Foundation

/// Cuts an arriving stream of audio into blocks of a **fixed** number of frames, across the
/// boundaries of the buffers it arrives in.
///
/// **The fixed part is the whole reason it exists.** The waveform's levels used to be made by
/// dividing each tap buffer into the nearest whole number of blocks, which is exact only while the
/// buffer happens to be near a multiple of one. `AVAudioEngine.installTap` takes its `bufferSize`
/// as a *hint*: it may hand back any frame count it likes, and the app never checked which. A
/// device delivering 512 frames would have had each of those promoted to a whole 43 ms level and
/// scrolled the waveform four times too fast; one delivering 3 000 would have had every level
/// stretched by half. Both are silent, both look plausible on screen, and neither is visible in
/// any test that only looks at one buffer.
///
/// So the remainder of a buffer is carried into the next one instead, and a level is worth exactly
/// `framesPerBlock` frames of audio whatever size the tap chooses. That is what lets
/// `WaveformScroll` treat the ring as a signal sampled at a known constant rate -- without it, the
/// read head would advance at one speed and the levels arrive at another, and the waveform would
/// drift or bunch instead of sliding.
///
/// What is carried is the **sum of squares**, not a root mean square: two RMS values cannot be
/// averaged back into the RMS of the runs behind them unless the runs are the same length, and
/// here they are precisely not. See `AudioLevelMeter.sumOfSquares(of:)`.
///
/// Allocates nothing and reads the caller's memory in place: this runs on the audio thread.
public struct BlockCutter: Equatable {
    /// How many frames make one block. At least one, so a degenerate sample rate cannot hang the
    /// loop below.
    public let framesPerBlock: Int

    /// How much of the block in progress has been measured. Zero exactly when nothing is carried.
    public private(set) var pendingFrames: Int = 0

    private var pendingSumOfSquares: Float = 0

    public init(framesPerBlock: Int) {
        self.framesPerBlock = max(1, framesPerBlock)
    }

    /// Feeds one buffer, calling `whenComplete` with the root mean square of each block it
    /// completes -- none, one, or several -- and carrying whatever is left over.
    ///
    /// The callback is non-escaping, so it costs no allocation; the caller appends to the ring
    /// from inside it rather than being handed an array it would have had to allocate.
    @discardableResult
    public mutating func accept(
        _ samples: UnsafeBufferPointer<Float>, whenComplete: (Float) -> Void
    ) -> Int {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var offset = 0
        var completed = 0
        while offset < samples.count {
            // Never zero: `pendingFrames` is always below `framesPerBlock` here, and `offset`
            // always below `count`, so the loop cannot spin.
            let taken = min(framesPerBlock - pendingFrames, samples.count - offset)
            pendingSumOfSquares += AudioLevelMeter.sumOfSquares(
                of: UnsafeBufferPointer(start: base + offset, count: taken))
            pendingFrames += taken
            offset += taken
            guard pendingFrames == framesPerBlock else { continue }
            whenComplete((pendingSumOfSquares / Float(framesPerBlock)).squareRoot())
            pendingFrames = 0
            pendingSumOfSquares = 0
            completed += 1
        }
        return completed
    }

    /// Array overload, for callers that already hold one (the tests).
    @discardableResult
    public mutating func accept(_ samples: [Float], whenComplete: (Float) -> Void) -> Int {
        var copy = self
        let completed = samples.withUnsafeBufferPointer {
            copy.accept($0, whenComplete: whenComplete)
        }
        self = copy
        return completed
    }
}
