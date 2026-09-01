import Foundation

/// How many bars a waveform draws in a frame of a given width, and how far apart they sit.
///
/// **The bar count used to be a constant, and that was the bug.** Lot 3 T3 sized `LevelHistory` at
/// six bars per half because the only surface then was a 32 pt notch wing, and six bars at 3 pt
/// with 2.5 pt gaps is 30.5 pt -- the wing exactly. When T9 grew the notch into a 400 pt card the
/// count came along unchanged, so the card drew a 61 pt clump of twelve bars marooned in the middle
/// of a 340 pt row. Louis, on the built-in display: *"je trouve ça très resserré vers le centre, ça
/// ne prend pas tout l'espace... j'aimerais quelque chose qui prend plus d'espace sur la largeur et
/// qui est un peu plus aéré."*
///
/// So the count is now a function of the frame, and the pair of numbers below is the contract:
///
/// - **A surface draws as many bars as fit, up to `maximumBars`.** The panel's 64 pt row fits
///   twelve and gets twelve. The card's 340 pt row would fit sixty-two and is capped at
///   twenty-three, because the cap is a duration and the duration is the dynamism.
/// - **The leftover width goes into the gaps, and the bars widen with them.** The row fills its
///   frame exactly instead of centring a fixed-width block in it, which is what removes the clump;
///   and the bar keeps `inkFraction` of its own slot, so a wide surface gets bigger bars rather
///   than the same hairlines further apart.
///
/// **The two surfaces differ, and the axis they differ on is time.** Both draw the same bars at the
/// same 43 ms cadence -- nothing is stretched, compressed or resampled -- but the card is a wider
/// window onto that signal: about a second of speech where the panel shows a quarter of one. That
/// is the right way round. A 64 pt strip cannot show a second of anything, and forcing the card
/// down to the panel's window would mean twelve bars at 28 pt apiece, which is a different design.
///
public enum WaveformLayout {
    // MARK: - The bar itself

    /// The thinnest a bar is ever drawn, in points, on any surface.
    ///
    /// It is the width every bar had when `barWidth` was a constant, so a surface narrow enough
    /// for the floor to bind -- the floating panel, at 64 pt -- draws exactly the bars it always
    /// did. Nothing gets thinner than it has been; only wider.
    public static let minimumBarWidth: Double = 3

    /// The closest two bars may ever sit. The gap the panel has always drawn at, and the floor the
    /// count is derived against.
    public static let minimumBarSpacing: Double = 2.5

    /// How much of the space one bar occupies should be the bar, on a surface wide enough to
    /// choose.
    ///
    /// **This is what replaced an absolute bar width, and the reason is the contract's own.**
    /// `DictationPhaseView` says line weights are absolute points "so the same design does not read
    /// as a hairline in one surface and a slab in the other" -- and read literally, at a 5:1 ratio
    /// between the panel's 64 pt and the card's 340 pt, it produced precisely that: a 3 pt bar is
    /// half the pitch on the panel and a fifth of it on the card. Holding the *proportion* is what
    /// the sentence was actually asking for; holding the *number* was how it got broken.
    ///
    /// 0.4 is **arbitrary in its digit** and is what the card already drew at 46 bars, which is
    /// the density nobody objected to. The floor above means the panel never reaches it -- it sits
    /// at about 0.54, where it has always been -- so this fraction only ever governs surfaces wide
    /// enough that a 3 pt bar would be a hair.
    public static let inkFraction: Double = 0.4

    // MARK: - How much time is on screen

    /// How much audio one bar measures.
    ///
    /// ~43 ms, i.e. 23.3 bars a second. It is a *fraction of a tap buffer*, not a buffer: at the
    /// 48 kHz of this Mac a 4 096-frame buffer is 85.3 ms, so one level per callback would give a
    /// syllable a single bar.
    ///
    /// (The lot-3 plan says "100 ms sub-blocks … so the level updates at ~20 Hz". Those two are
    /// not the same statement: a 100 ms block is *longer* than the 85.3 ms buffer it would have to
    /// be cut from, and would have lowered the rate to 10 Hz. The 20 Hz is the intent worth
    /// keeping, so it is the number implemented.)
    ///
    /// **It is a duration and not a buffer count, and `AudioLevels` now honours that literally.**
    /// The rate used to be a consequence of the tap's frame count -- two blocks per 4 096-frame
    /// buffer -- which made it hostage to a number `installTap` is only ever *asked* for. The
    /// buffer's remainder is carried now, so a level is one block of audio at any buffer size and
    /// this constant alone sets the rate.
    ///
    /// **23.3 a second is not, and never was, a frame rate.** It was once defended as "above the
    /// 20 Hz the eye reads as continuous", and that defence was wrong twice over: the levels
    /// arrived in lumps of two so the picture only changed 11.7 times a second, and a picture that
    /// changes 23 times a second is a picture that steps 23 times a second. What makes the waveform
    /// continuous is `WaveformScroll`, which slides between these samples; this number is the
    /// waveform's *time resolution*, and raising it would mean more bars in the same window rather
    /// than smoother motion.
    ///
    /// It lives here rather than in `AudioLevels`, where it was written, because it is now the
    /// waveform's time resolution and not merely the recorder's block size: `maximumBars` is
    /// derived from it, and a derivation whose two halves sit in different targets is one the app
    /// target cannot test.
    public static let blockDuration: Double = 0.043

    /// How far back the waveform shows, at most.
    ///
    /// **This is the dynamism knob, and getting it wrong is what Louis reported**: "ça fait
    /// vraiment des grandes ondes qui se propagent très longuement -- ça n'a pas du tout le
    /// dynamisme de ce qu'on avait juste avant". He read it as a frame-rate problem; it is not.
    /// The tick rate is untouched at 60 Hz, and one frame of the widest waveform Murmure draws
    /// measures 0.63 ms to lay out and rasterise -- 3.8 % of a 60 Hz budget, and 0.22 ms more than
    /// the six-bar wing he called fluid. What changed is how long a level stays on screen, which is
    /// exactly this number: **the whole picture turns over `1 / window` times a second**, and the
    /// wing turned over 3.9 times a second where a 2 s window turns over 0.5.
    ///
    /// One second. **Arbitrary in its digit**, bounded on both sides by things that are not:
    ///
    /// - Below it, the card stops reading as a waveform. The count a window buys is
    ///   `window / blockDuration`, so a 0.85 s window puts 19 bars across 340 pt and a 0.5 s
    ///   window puts 11: at that point the row is a handful of blocks and the shape of a word is
    ///   no longer in it. A test holds the card above twenty bars.
    /// - Above it, the ripple Louis saw. Two seconds was the previous value and it was chosen
    ///   backwards -- to keep a *3 pt* bar from looking like a stick at a wide pitch, i.e. a line
    ///   weight was allowed to set the dynamics. `inkFraction` is what removed that constraint:
    ///   the bar widens with the pitch now, so the window is free to be chosen for the motion.
    ///
    /// It cannot go all the way back to the wing's 0.26 s and that is arithmetic, not taste: six
    /// bars across 340 pt is a pitch of 57 pt. A row five times wider holds more of the past at any
    /// scroll speed; what this buys back is the speed itself -- 353 pt/s against the wing's 128.
    public static let window: TimeInterval = 1

    /// The most bars any surface draws.
    ///
    /// Truncating rather than rounding, so the window is a ceiling that is never exceeded.
    public static let maximumBars = Int(window / blockDuration)

    /// How many levels are kept **beyond** the widest row, so the read head can look back.
    ///
    /// It used to be none: the ring held exactly `maximumBars` because that was exactly what the
    /// widest surface drew. `WaveformScroll` broke that equality, and the way it broke it is worth
    /// writing down because the symptom was specific. The head is parked
    /// `WaveformScroll.margin(burst:)` levels behind the newest so it never reads a level that has
    /// not landed; the oldest bar of the row then reads `maximumBars - 1` further back still, which
    /// with no headroom is off the end of the ring. Those bars clamped to the oldest level -- so
    /// the left-hand three or four bars of the card were a little block that held still and then
    /// jumped by two whenever the ring shifted, i.e. the exact staircase the change exists to
    /// remove, surviving in the corner of the drawing.
    ///
    /// Eight is **arbitrary in its digit** and bounded on one side: it must be at least the margin,
    /// which is the burst plus a block and a half, and eight therefore covers a tap buffer of up to
    /// six blocks -- 258 ms, far past anything `AVAudioEngine` hands out. `WaveformScroll.margin`
    /// is capped at this number so the two cannot drift apart.
    ///
    /// These levels are never drawn. They are 32 bytes of look-back, and the alternative to them is
    /// a stepping left edge.
    public static let scrollHeadroom = 8

    // MARK: - Fitting them to a frame

    /// How many bars a frame this wide draws.
    ///
    /// As many as fit at the minimum pitch, capped at `maximumBars`. `n` bars and `n - 1` gaps fit
    /// in `width` when `n × barWidth + (n - 1) × minimumBarSpacing ≤ width`, which rearranges to
    /// the division below.
    ///
    /// Never zero: a waveform with no bars is not a quiet waveform, it is a blank surface, and
    /// nothing in Murmure hands this a frame narrower than a single bar.
    public static func barCount(inWidth width: Double) -> Int {
        let fitting = Int((width + minimumBarSpacing) / (minimumBarWidth + minimumBarSpacing))
        return min(maximumBars, max(1, fitting))
    }

    /// How wide each of those bars is drawn.
    ///
    /// `inkFraction` of the space one bar gets, floored at `minimumBarWidth`. Solving
    /// `count × bar + (count - 1) × gap = width` under `bar = f × (bar + gap)` gives the closed
    /// form below, so the fraction is exact against the pitch the row actually ends up with rather
    /// than against an approximation of it.
    public static func barWidth(inWidth width: Double, barCount: Int) -> Double {
        guard barCount > 1 else { return max(minimumBarWidth, max(0, width)) }
        let denominator = Double(barCount) * inkFraction + Double(barCount - 1) * (1 - inkFraction)
        return max(minimumBarWidth, max(0, width) * inkFraction / denominator)
    }

    /// The gap between two bars, once `barCount` of them are laid in a frame this wide.
    ///
    /// The leftover is shared out equally so the row **fills its frame exactly**. That is the line
    /// that removes the clump: with a fixed gap the bars are a block of fixed width centred in
    /// whatever they are given, and a card four times wider than a panel gets the same block with
    /// more emptiness around it.
    ///
    /// Floored at `minimumBarSpacing` so a frame too narrow for the bars it was told to draw
    /// overflows rather than overlapping them -- bars drawn on top of each other read as one thick
    /// bar, which is precisely the artefact at the centre of the card this change also fixes.
    public static func barSpacing(inWidth width: Double, barCount: Int) -> Double {
        guard barCount > 1 else { return 0 }
        let leftover = width - Double(barCount) * barWidth(inWidth: width, barCount: barCount)
        return max(minimumBarSpacing, leftover / Double(barCount - 1))
    }
}
