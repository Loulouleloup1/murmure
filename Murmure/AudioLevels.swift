import AVFoundation
import Foundation
import MurmureCore
import os

/// The waveform's data, written by the audio thread and **pulled** by the interface.
///
/// One direction only, and that is the whole design. The audio thread appends a bar height every
/// ~43 ms and never waits for anybody; the wings read the last few of them whenever they happen to
/// draw. A main thread stalled by a menu being tracked, a Space switch or a beachball can
/// therefore never back up the tap block -- there is no queue between them to fill, and no
/// callback into the interface to be blocked in.
///
/// Everything it decides is `AudioLevelMeter` and `LevelHistory`, in `MurmureCore`, where they are
/// tested. What is here is the lock, and the split of a tap buffer into blocks.
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
    /// Set once per recording, from the hardware format. 1 until the first `begin`.
    private var framesPerBlock = 1

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
        framesPerBlock = frames
        meter = AudioLevelMeter()
        // A dictation opens on a flat line, never on the tail of the previous one.
        history = LevelHistory()
    }

    /// Audio thread. Measures the buffer and records one bar height per block.
    ///
    /// Allocates nothing: the RMS is read straight out of the tap buffer's own memory, and the
    /// ring writes in place. This is the constraint `AudioRecorder`'s doc comment guards, and it
    /// is why `AudioLevelMeter.rootMeanSquare` takes a buffer pointer rather than an array.
    func measure(_ buffer: AVAudioPCMBuffer) {
        // Non-interleaved float is what `AVAudioEngine` delivers; the first channel is enough to
        // say how loud the room is. `nil` would mean an integer format, which this Mac never
        // produces -- and a waveform is not worth a conversion on the audio thread.
        guard let samples = buffer.floatChannelData?.pointee else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        // Rounded, so a buffer worth 1.7 blocks is cut in two rather than measured as one block
        // plus a 60 % sliver that would read as a quieter bar every time.
        let blocks = max(1, Int((Double(frames) / Double(framesPerBlock)).rounded()))
        let size = frames / blocks
        for block in 0..<blocks {
            let start = block * size
            // The last block takes the remainder, so no sample is left unmeasured.
            let end = block == blocks - 1 ? frames : start + size
            let rms = AudioLevelMeter.rootMeanSquare(
                of: UnsafeBufferPointer(start: samples + start, count: end - start)
            )
            history.append(meter.accept(rootMeanSquare: rms))
        }
    }

    /// Interface. The bars to draw, oldest first.
    ///
    /// The array is built here, on the reader's thread: the ring's own storage stays uniquely
    /// referenced, so the next `measure` writes into it in place instead of paying for a
    /// copy-on-write on the audio thread.
    func bars() -> [Float] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return history.values
    }
}
