import Foundation

/// How far into a dictation's audio the transcription has got, and how many real measurements
/// that number is built from.
///
/// `fraction` is a fraction of AUDIO, not of decoder steps, and that is the whole point of the
/// type. WhisperKit's `Progress` counts samples seeked over out of samples handed in
/// (`TranscribeTask.swift:100` sets the total to the clip length, `:274` moves the completed count
/// to the current seek), so 0.5 means "half of what you recorded has been decoded" and nothing
/// else. The other thing WhisperKit offers -- the per-token `TranscriptionCallback` -- has no
/// denominator at all: its only ceiling is `DecodingOptions.sampleLength`, 224 by default, and
/// measured over eleven real recordings a window ends somewhere between 20 and 170 tokens. A bar
/// drawn as tokens/224 would therefore stop between 9 % and 76 % at the exact instant a window
/// finished. That is an animation with a number written on it, which is the one thing this must
/// not be.
///
/// `steps` is how many times the pulled value has actually MOVED, and it is what tells the
/// interface whether there is a progression to draw at all. WhisperKit advances its progress once
/// per decoding window, and a window is 30 s of audio: measured, the 3.1 s, 4.2 s, 7.3 s and
/// 13.7 s recordings each decoded in a single window and produced ZERO intermediate updates,
/// going from 0 to 1 in 0.43-0.60 s. Above that it is real motion -- 4 windows and 3 updates for
/// an 87.8 s dictation, 19 windows and 19 updates for a 478.9 s one, one every 0.66-1.5 s.
public struct DecodeProgress: Equatable, Sendable {
    /// 0…1, and never anything else. What the interface draws.
    public private(set) var fraction: Double = 0

    /// How many real advances this fraction is made of. Zero means nothing has been measured yet
    /// -- either the transcription has barely started, or its audio fits in one window and
    /// nothing ever will be.
    public private(set) var steps: Int = 0

    public init() {}

    /// Takes a raw reading and keeps it only if it is a real advance.
    ///
    /// Clamped, because the raw number really does exceed 1. WhisperKit resets its `Progress` only
    /// when a transcription FINISHED or was cancelled (`WhisperKit.swift:1167-1178`), so a
    /// transcription that threw leaves its unfinished child attached and the next one adds a
    /// second child with the same pending unit count to the same total of 1. Measured against
    /// Foundation directly: a child abandoned at 40 % makes the following transcription read 0.4
    /// at its first token and **1.4** at its last.
    ///
    /// Monotonic, because the raw number really does go backwards. `WhisperKit.progress` is
    /// REPLACED by a fresh `Progress` the instant the call returns, so a reader that re-reads that
    /// property watches the bar fall from 0.90 to 0 -- measured on four real recordings, every one
    /// of them. Following one captured object is what avoids it; this guard is what makes the
    /// avoidance a rule instead of a habit.
    ///
    /// A non-finite reading is dropped rather than clamped, because it ends up as the width of a
    /// bar: a NaN width is not a bar that is wrong, it is a bar that is not there.
    ///
    /// Only the upper end is clamped. A `max(raw, 0)` would be unreachable code: `fraction` starts
    /// at 0 and this is the only thing that raises it, so a negative reading is already rejected
    /// below as "not an advance". The behaviour is still pinned by a test, because it is the
    /// behaviour that matters and not the line that happens to provide it.
    public mutating func observe(_ raw: Double) {
        guard raw.isFinite else { return }
        let clamped = min(raw, 1)
        guard clamped > fraction else { return }
        fraction = clamped
        steps += 1
    }

    /// The transcription succeeded, so the bar is full whatever the last reading said.
    ///
    /// Not a cosmetic rounding-up. WhisperKit writes its final `completedUnitCount = totalUnitCount`
    /// and then replaces the object, and a 500 Hz poll of the property missed that instant on three
    /// recordings out of four -- leaving the last reading at 0.9042 on an 87.8 s dictation that had
    /// in fact finished. A bar stuck at 90 % on every success is exactly the visible defect.
    ///
    /// Deliberately not counted as a step: a dictation whose audio fits in one window measured
    /// nothing, and `steps == 0` has to keep saying so after it has succeeded.
    public mutating func finish() {
        fraction = 1
    }
}

/// The transcription's progress, advanced by whoever is decoding and **pulled** by the interface.
///
/// `AudioLevels`'s shape, and for the same reason: one direction only. The decoder never calls
/// into the interface and never waits for it, and the interface reads whatever is there whenever
/// it happens to draw. Unlike the waveform there is no audio thread here, so the lock is a plain
/// `NSLock` rather than a raw `os_unfair_lock` -- nothing on either side of it is real-time.
///
/// `@unchecked Sendable` because it stores a `Progress`, which Foundation does not declare
/// `Sendable`, and that object is read from the interface's thread while WhisperKit's decoder
/// advances it from its own. The claim was measured rather than assumed: under ThreadSanitizer,
/// 1 000 000 writes to a child's `completedUnitCount` racing 200 000 reads of the parent's
/// `fractionCompleted` produced no report, while a deliberately racy control in the same build
/// did. Foundation locks `Progress` internally; the lock below protects only this type's own
/// fields.
public final class DecodeProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: DecodeProgress?
    private var source: Progress?
    /// What `source` already read at `follow`, subtracted from every reading afterwards.
    private var baseline: Double = 0

    public init() {}

    /// A dictation is about to be transcribed.
    ///
    /// Separate from `follow` because the two happen at different moments and the gap between
    /// them is not small: the recording still has to be read off disk, measured for silence and,
    /// on the first dictation of a session, the model has to load -- 112 s, measured cold. Both
    /// lines below are what stops the interface from spending all of that showing the PREVIOUS
    /// dictation's full bar -- forgetting the reading, and forgetting the decoder that filled it.
    public func begin() {
        lock.lock()
        defer { lock.unlock() }
        reading = DecodeProgress()
        source = nil
    }

    /// The decoder's own measure of how far into the audio it has got.
    ///
    /// The `Progress` must be captured BEFORE the transcription starts and this same object kept
    /// throughout -- never re-read from `WhisperKit.progress`, which is a different object by the
    /// time the call returns (measured: `captured === kit.progress` is false afterwards, the
    /// captured one reads 1.0 and the property reads 0).
    ///
    /// The baseline is what makes a second transcription honest after a first one threw: the
    /// abandoned child stays attached to the same parent, so the raw reading starts at whatever it
    /// reached and ends 1.0 above it. Foundation adds each child's own fraction to the parent
    /// whole, so the difference is exactly this transcription's share -- 0.4 → 1.4 becomes 0 → 1.
    public func follow(_ progress: Progress) {
        lock.lock()
        defer { lock.unlock() }
        source = progress
        baseline = progress.fractionCompleted
    }

    /// The transcription succeeded, so the bar is full.
    ///
    /// It deliberately does NOT drop the decoder it was following. That would look tidier and
    /// would be unreachable code: the reading can only ever rise, it is now at 1, and nothing the
    /// abandoned `Progress` can report afterwards is an advance on that. `begin()` is where the
    /// dropping has to happen, because that is where it changes what Louis sees.
    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        reading?.finish()
    }

    /// Interface. What to draw, or nil while nothing has ever been transcribed.
    ///
    /// The reading is taken HERE, on the puller's thread, rather than pushed by a timer: the
    /// decoder's progress moves at most once every 0.66 s (the shortest gap between two updates,
    /// measured on the 478.9 s recording) and the interface redraws far faster than that, so a
    /// timer would only add a second rate to reconcile with the first.
    public func current() -> DecodeProgress? {
        lock.lock()
        defer { lock.unlock() }
        if let source {
            reading?.observe(source.fractionCompleted - baseline)
        }
        return reading
    }
}
