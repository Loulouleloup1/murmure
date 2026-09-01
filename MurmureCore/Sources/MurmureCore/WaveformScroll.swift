import Foundation

/// What the waveform knows at the instant it draws: the levels, and how old the newest one is.
///
/// The age is the whole point. A ring of levels on its own can only be drawn as a staircase --
/// the same picture for every frame between two arrivals, then a jump -- because nothing in it
/// says *where between two arrivals we are*. `sinceNewest` is that missing coordinate, and
/// `WaveformScroll` is what it is for.
public struct WaveformReading: Equatable {
    /// The ring, oldest first, always exactly its capacity long (`LevelHistory.values`).
    public let levels: [Float]

    /// How long ago the newest of them was appended, on a monotonic clock -- **counted from the
    /// audio, not from the callback that delivered it.**
    ///
    /// That distinction is the correction that stops the waveform lurching backwards once every few
    /// seconds, and it was found by working out what the read head does across an arrival rather
    /// than by watching it. A 4 096-frame buffer at 48 kHz is 1.9845 blocks, so most buffers
    /// complete two levels and about one in sixty-five completes only one. Anchor the head on
    /// "levels appended so far" and it advances 1.9845 blocks' worth of clock between arrivals but
    /// gains only *one* level at those buffers -- a backward jump of 0.98 of a bar, roughly every
    /// five and a half seconds, which is precisely the kind of periodic lurch that gets reported as
    /// stutter.
    ///
    /// The quantisation cancels exactly if the age includes the frames of the block still in
    /// progress: the newest level ended `BlockCutter.pendingFrames` frames before the end of the
    /// latest buffer, and `levels appended x framesPerBlock + pendingFrames` is the total frame
    /// count, which is continuous. So this is *(now - when the latest buffer arrived) +
    /// pendingFrames / sampleRate*, and the head then advances at exactly one level per
    /// `blockDuration` with no sawtooth left in it. `since(levels:sinceLastBuffer:...)` below is
    /// where that sum is done, so no caller has to remember to do it.
    public let sinceNewest: TimeInterval

    /// The most levels a single tap callback has ever appended in this recording.
    ///
    /// Not a constant, because the tap's buffer size is not one: `bufferSize` in `installTap` is
    /// a *hint*, AVAudioEngine may hand back any frame count, and the number it actually hands
    /// back is the one this has to survive. Observed rather than assumed, it makes the margin
    /// below adapt to whatever this Mac's device does, including a device swapped mid-recording.
    public let burst: Int

    public init(levels: [Float], sinceNewest: TimeInterval, burst: Int) {
        self.levels = levels
        self.sinceNewest = sinceNewest
        self.burst = burst
    }

    /// Builds the reading from what the recorder actually holds, doing the one piece of arithmetic
    /// that would otherwise live in the app target, where there is no test bundle to hold it.
    ///
    /// `sinceLastBuffer` is measured from the arrival of the latest tap buffer -- every buffer,
    /// including one too short to complete a block -- and `pendingFrames` is the part-block
    /// `BlockCutter` is still carrying. Adding the second to the first is what makes `sinceNewest`
    /// the age of the newest level rather than the age of the last arrival, and therefore what
    /// makes the read head advance without a sawtooth. See the note on `sinceNewest`.
    public static func since(
        levels: [Float],
        sinceLastBuffer: TimeInterval,
        pendingFrames: Int,
        sampleRate: Double,
        burst: Int
    ) -> WaveformReading {
        let carried = sampleRate > 0 ? Double(max(0, pendingFrames)) / sampleRate : 0
        return WaveformReading(
            levels: levels, sinceNewest: max(0, sinceLastBuffer) + carried, burst: burst)
    }
}

/// Reads the level ring at a *continuous* instant, so the waveform slides instead of stepping.
///
/// **This is the answer to the third report of the same complaint** -- "je trouve ça même très
/// saccadé" -- and the two rounds before it are why it is written here rather than as another
/// number. The first raised the turnover (`WaveformLayout.window`, 2 s to 1 s), the second raised
/// the redraw (`DictationPhaseView.sampleInterval`, 20 Hz to 60 Hz), and neither touched the thing
/// that was wrong, because the thing that was wrong was never the rate at which the picture was
/// *drawn*. It was the rate at which the picture *changed*.
///
/// A level is one `WaveformLayout.blockDuration` of audio, so levels exist at about 23 a second
/// and they arrive in lumps -- a 4 096-frame tap buffer at 48 kHz is 85 ms, i.e. two levels at a
/// time, 11.7 times a second. Drawing sixty frames a second on top of that produced sixty frames
/// of which fifty were identical to the one before them. Redrawing an unchanged picture faster
/// does not make it move.
///
/// Two things had to change, and only the second is here:
///
/// - **A level must be worth exactly one block of audio**, whatever the tap hands over. That is
///   `AudioLevels`, which now carries the remainder of a buffer into the next one instead of
///   rounding a buffer to a whole number of blocks.
/// - **A bar's height at time *t* must be a function of *t***, not of which levels have landed.
///   That is this type. The read head advances at exactly one level per `blockDuration` of wall
///   clock, and a bar reads the ring at a *fractional* position, interpolating between the two
///   levels it falls between. Sixty frames a second are then sixty different pictures.
///
/// **The interpolation is linear, deliberately, and "ease between the samples" is the thing this
/// is NOT.** Easing is right when a value is settling onto a target: it starts and ends at rest,
/// which is what makes a step look considered. But this is not a settle, it is a translation --
/// the same shape sliding leftwards at a constant 353 pt/s -- and an ease-in-out applied to a
/// translation makes the shape stop dead at every sample boundary and sprint through the middle.
/// That is a 23 Hz pulsation in the apparent speed, which is a new stutter in place of the old
/// one. Linear interpolation of the value *is* constant-velocity translation of the shape, which
/// is why it is the right curve here and why a smoothstep was tried and dropped.
///
/// (The kink linear leaves -- each bar's height changes direction at a sample boundary -- is a
/// second-derivative discontinuity in one bar, not a velocity change in the shape, and the eye
/// tracks the shape. A Catmull-Rom spline through four levels would remove even that at constant
/// rate; it is the next step if one is ever wanted, and it is not taken now because it can
/// overshoot the meter's range and needs clamping to be safe, for a difference nobody has asked
/// about.)
public enum WaveformScroll {
    /// How far behind the newest level the read head is held, in levels.
    ///
    /// **A jitter buffer, and it cannot be zero.** The head advances with the clock, the levels
    /// arrive in lumps of `burst`, and reading a level that has not landed yet is the one thing
    /// this must never do -- it would clamp, and a clamped head is a frozen picture, which is the
    /// staircase again.
    ///
    /// The two terms are each one thing:
    ///
    /// - **`burst + 1` is the worst age the newest level can reach.** Just before a buffer lands,
    ///   the audio has run on by that buffer's own length -- at most `burst` blocks -- plus the
    ///   part-block `BlockCutter` is still carrying, which is under one. Park the head any closer
    ///   than that and it clamps once per buffer, every buffer.
    /// - **The half-block on top is slack for a callback that comes late**, 21 ms at this Mac's
    ///   43 ms blocks. `burst` covers the schedule; nothing else covers the schedule slipping.
    ///
    /// The cost is latency, and it is worth naming rather than discovering: at a burst of two the
    /// head sits between half a level and three and a half behind the microphone -- 21 to 150 ms,
    /// averaging 86. That is the price of a waveform that never freezes, and it is paid against a
    /// drawing that already carried every bar through 50 ms of implicit animation before it could
    /// finish showing a new height. **A smaller tap buffer would halve it** -- 1 024 frames makes
    /// the burst 1 and the average lag 54 ms -- and that is the lever to reach for if the delay is
    /// ever the complaint; it is not reached for here, because it buys no smoothness at all and it
    /// pays in callbacks on the thread that also writes the WAV.
    ///
    /// `max(1, burst)` because a recording that has not delivered a buffer yet reports zero, and a
    /// margin still has to be one.
    ///
    /// Capped at `WaveformLayout.scrollHeadroom`, which is the look-back the ring actually keeps: a
    /// margin past it would push the oldest bar of a full row off the end of the history, where it
    /// would clamp and step. A device bursting harder than the headroom therefore gets an
    /// occasional freeze at the newest bar instead of a permanently stepping left edge -- the
    /// better of the two failures, and neither is reachable by any buffer size seen in practice.
    public static func margin(burst: Int) -> Double {
        min(Double(WaveformLayout.scrollHeadroom), Double(max(1, burst)) + 1.5)
    }

    /// Where the newest bar drawn reads from, as a fractional index into `levels`.
    ///
    /// Continuous across an arrival, which is the property the whole design rests on and the one
    /// worth checking by hand. Say the ring is 31 long (23 drawn, 8 of look-back), the margin 3.5,
    /// and a buffer of 1.9845
    /// blocks lands every 85.3 ms. Just before an arrival `sinceNewest` has grown by 1.9845 blocks
    /// since the last one, so the head is 1.9845 further along than it was. The buffer lands: two
    /// levels are appended, so the ring shifts left by two and the head's index drops by two --
    /// and `sinceNewest` drops by the same 1.9845 it grew, because the carried part-block it
    /// counts is what the two new levels consumed. Net movement across the seam: `1.9845 - 2 + the
    /// new carry`, which is zero. It does not jump back and it does not jump on; it keeps going at
    /// the speed it was going, and it does so at the buffers that complete one level exactly as at
    /// the buffers that complete two.
    public static func head(
        _ reading: WaveformReading,
        blockDuration: Double = WaveformLayout.blockDuration
    ) -> Double {
        let newest = Double(reading.levels.count - 1)
        guard newest > 0 else { return 0 }
        // A block of no duration is a caller's mistake, not a state a recording reaches. Freezing
        // on the NEWEST level is the harmless answer -- the drawing is then simply the ring, which
        // is what it was before any of this; freezing on the oldest would show a second-old row and
        // look like a hung waveform.
        guard blockDuration > 0 else { return newest }
        let advanced = max(0, reading.sinceNewest) / blockDuration
        return min(newest, max(0, newest - margin(burst: reading.burst) + advanced))
    }

    /// The heights of `count` bars, oldest first — one row of the waveform at this instant.
    ///
    /// Slot by slot the row is the ring read at `head`, `head - 1`, `head - 2` … so as the head
    /// advances by one the row becomes what its right-hand neighbour was: a translation, at one
    /// bar per `blockDuration`. A position before the start of the ring clamps to its oldest level,
    /// which `WaveformLayout.scrollHeadroom` exists to make unreachable for any surface Murmure
    /// draws: it is a guard against a caller asking for more bars than are kept, not a case the
    /// card or the panel ever lands in.
    public static func heights(
        _ reading: WaveformReading,
        count: Int,
        blockDuration: Double = WaveformLayout.blockDuration
    ) -> [Float] {
        guard count > 0 else { return [] }
        guard !reading.levels.isEmpty else {
            return [Float](repeating: AudioLevelMeter.floorHeight, count: count)
        }
        let head = head(reading, blockDuration: blockDuration)
        return (0..<count).map { slot in
            level(in: reading.levels, at: head - Double(count - 1 - slot))
        }
    }

    /// The ring at a fractional index: the level below it and the level above it, mixed.
    ///
    /// Clamped at both ends rather than wrapped. The ring is a window on the last second of
    /// speech, not a loop, and wrapping it would run the beginning of the window back over the
    /// end of it — one second ago drawn as if it were now.
    public static func level(in levels: [Float], at position: Double) -> Float {
        guard let first = levels.first, let last = levels.last else {
            return AudioLevelMeter.floorHeight
        }
        guard position > 0 else { return first }
        guard position < Double(levels.count - 1) else { return last }
        let low = Int(position.rounded(.down))
        let fraction = Float(position - Double(low))
        return levels[low] + (levels[low + 1] - levels[low]) * fraction
    }
}
