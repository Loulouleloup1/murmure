import AVFoundation
import Foundation
import MurmureCore
import os

/// The waveform's data, written by the audio thread and **pulled** by the interface.
///
/// One direction only, and that is the whole design. The audio thread appends a bar height every
/// 43 ms and never waits for anybody; the wings read the last few of them whenever they happen to
/// draw. A main thread stalled by a menu being tracked, a Space switch or a beachball can
/// therefore never back up the tap block -- there is no queue between them to fill, and no
/// callback into the interface to be blocked in.
///
/// **Every 43 ms, and no longer "about" every 43 ms.** A tap buffer used to be rounded to the
/// nearest whole number of blocks, which is only harmless while the buffer happens to be close to
/// a multiple of one: `installTap`'s `bufferSize` is a hint, and a device handing back 512 frames
/// would have had each of them promoted to a whole 43 ms bar and run the waveform four times too
/// fast. The remainder of a buffer is carried into the next one instead, so a level is worth
/// exactly one block of audio whatever the tap does -- and the reader can therefore treat the ring
/// as a signal sampled at a known, constant rate, which is what `WaveformScroll` needs to slide it
/// continuously.
///
/// Everything it decides is `AudioLevelMeter`, `LevelHistory`, `BlockCutter` and `WaveformReading`,
/// in `MurmureCore`, where they are tested. What is here is the lock, the clock, and the wiring
/// between them.
///
/// Its lock is deliberately NOT `TapSink`'s. The two protect state with different lifetimes and no
/// shared invariant -- the writer must not be released mid-write, these numbers must not be torn --
/// and nesting them would put the audio thread inside the writer's critical section while it waits
/// for a lock the main thread takes twenty times a second. `AudioRecorder.stop()` waits behind that
/// same writer lock to close the file, so the nesting would have built exactly the path this type
/// exists to avoid: a slow interface delaying the end of a recording. They are taken one after the
/// other, never one inside the other.
final class AudioLevels: @unchecked Sendable {
    /// How much audio each bar measures, and therefore how far back the waveform reaches.
    ///
    /// The constant itself is `WaveformLayout.blockDuration`, in the package: `LevelHistory`'s
    /// capacity is derived from it -- how many bars fit inside `WaveformLayout.window` -- and a
    /// derivation with one half here and one half there is one the app target cannot test.
    static let blockDuration = WaveformLayout.blockDuration

    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var meter = AudioLevelMeter()
    private var history = LevelHistory()
    /// Sized once per recording, from the hardware format. Carries a part-measured block from one
    /// tap buffer to the next, which is what makes a level worth exactly `blockDuration` of audio
    /// whatever frame count the tap chooses to hand over.
    private var cutter = BlockCutter(framesPerBlock: 1)
    /// When the latest buffer arrived, on the same monotonic clock `reading()` reads. Every
    /// buffer, including one too short to complete a block: it times the *audio*, not the levels.
    ///
    /// The *callback's* instant, deliberately, and not the buffer's own `AVAudioTime`. A capture
    /// timestamp would be the more accurate description of when the sound happened, but it sits an
    /// unknown and variable capture-to-callback latency in the past, and `WaveformScroll.margin`
    /// would then have to cover that latency as well or the read head would clamp and freeze.
    /// Measured from the callback, the age of the newest level is bounded by the buffer's own
    /// length, which is a thing this type observes. The callback's own jitter -- a millisecond or
    /// two -- lands as a sub-point wobble in the read head, and the margin's half-block of slack
    /// is what covers it.
    private var lastBufferAt: TimeInterval = 0

    /// This recording's sample rate. Turns the cutter's carried part-block into the age it
    /// represents, which is the term that makes the read head advance smoothly -- the sum is
    /// `WaveformReading.since`, in the package, where it is tested.
    private var sampleRate: Double = 0
    /// The most levels a single callback has ever appended. `WaveformScroll.margin` reads it.
    private var burst = 0

    init() {
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// A recording is starting: forget the last one's waveform and size the blocks for this
    /// device's sample rate. Called from `AudioRecorder.start()`, before the tap is installed.
    func begin(sampleRate: Double) {
        let frames = max(1, Int((sampleRate * Self.blockDuration).rounded()))
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        cutter = BlockCutter(framesPerBlock: frames)
        self.sampleRate = sampleRate
        meter = AudioLevelMeter()
        // A dictation opens on a flat line, never on the tail of the previous one.
        history = LevelHistory()
        // Not zero: the read head is a distance behind this, and a zero here would put it a whole
        // epoch behind and clamp the first frames of every dictation to the oldest slot.
        lastBufferAt = Self.now()
        // Forgotten with the rest, so a recording on a device with a small buffer does not inherit
        // the margin a previous recording on a large one needed.
        burst = 0
    }

    /// The monotonic clock both sides of this type read. Safe on the audio thread: a multiply by a
    /// cached timebase, no lock and no allocation.
    private static func now() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// Audio thread. Measures the buffer and records one bar height per block.
    ///
    /// Allocates nothing: the RMS is read straight out of the tap buffer's own memory, and the
    /// ring writes in place. This is the constraint `AudioRecorder`'s doc comment guards, and it
    /// is why `AudioLevelMeter.sumOfSquares` takes a buffer pointer rather than an array and why
    /// `BlockCutter` reports its completed blocks through a non-escaping closure rather than an
    /// array of them.
    func measure(_ buffer: AVAudioPCMBuffer) {
        // Non-interleaved float is what `AVAudioEngine` delivers; the first channel is enough to
        // say how loud the room is. `nil` would mean an integer format, which this Mac never
        // produces -- and a waveform is not worth a conversion on the audio thread.
        guard let samples = buffer.floatChannelData?.pointee else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Read before the lock, so what is recorded is when the buffer reached this thread rather
        // than when it got past whatever the interface was doing.
        let arrived = Self.now()

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        // The cut, the carry and the arithmetic are `BlockCutter`'s, in the package, where they are
        // tested; the closure is non-escaping, so appending from inside it costs no allocation.
        let appended = cutter.accept(UnsafeBufferPointer(start: samples, count: frames)) { rms in
            history.append(meter.accept(rootMeanSquare: rms))
        }
        // The clock moves on every buffer, including one too short to complete a block: what it
        // times is how far the audio has run, and the cutter's carry is what says how much of that
        // has not become a level yet. Only the burst is a fact about levels.
        burst = max(burst, appended)
        lastBufferAt = arrived
    }

    /// Interface. The bars to draw and how old the newest of them is.
    ///
    /// The array is built here, on the reader's thread: the ring's own storage stays uniquely
    /// referenced, so the next `measure` writes into it in place instead of paying for a
    /// copy-on-write on the audio thread.
    ///
    /// The age is what turns a ring into something that can be drawn continuously; everything done
    /// with it is `WaveformScroll`, in the package, where it is tested.
    func reading() -> WaveformReading {
        let asked = Self.now()
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        // The part-block the cutter is still carrying is audio that has already happened and has
        // not become a level yet, so it is part of how old the newest level is; leaving it out is
        // what would make the head lurch backwards at the buffers that complete only one level.
        // The sum is `WaveformReading.since`, in the package, so it is arithmetic under test
        // rather than four lines in a target that has no test bundle.
        return WaveformReading.since(
            levels: history.values,
            sinceLastBuffer: asked - lastBufferAt,
            pendingFrames: cutter.pendingFrames,
            sampleRate: sampleRate,
            burst: burst)
    }
}
