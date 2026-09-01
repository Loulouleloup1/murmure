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
/// - **A surface draws as many bars as fit, up to `maximumBars`.** The panel's 32 pt half fits six
///   and gets six -- unchanged, and unchanged *by construction* rather than by exception. The
///   card's 165 pt half would fit thirty and is capped at twenty-three.
/// - **The leftover width goes into the gaps.** The row therefore fills its frame exactly instead
///   of centring a fixed-width block in it, which is what removes the clump; and above the cap the
///   gaps keep growing, which is what makes a wide surface *airier* rather than merely busier.
///
/// The cap is the interesting half. Without it a 165 pt frame would take thirty bars at the
/// minimum pitch and the card would be a dense hairline comb -- wider, but no more aéré than
/// before. With it the card's gaps open to about 4.4 pt against the panel's 2.8, so the same
/// waveform is drawn more loosely on the surface that has room for it.
///
/// **The two surfaces therefore differ, and the axis they differ on is time.** Both draw the same
/// bars at the same 43 ms cadence -- nothing is stretched, compressed or resampled -- but the card
/// is a wider window onto that signal, so it shows about a second of speech where the panel shows
/// about a quarter of one. That is the right way round: a 32 pt strip cannot show a second of
/// anything, and forcing the card down to the panel's window would mean six bars at 27 pt apiece,
/// which is a different design and not this one.
public enum WaveformLayout {
    // MARK: - The bar itself

    /// A bar's width, in points, on every surface. **Absolute, and it stays absolute**, which is
    /// `DictationPhaseView`'s stated contract: lengths and positions scale with the frame, line
    /// weights do not, so the same design does not read as a hairline on one surface and a slab on
    /// the other. It is the count and the gaps that answer a wider frame, never the stroke.
    public static let barWidth: Double = 3

    /// The closest two bars may ever sit. The gap the panel has always drawn at, and the floor the
    /// count is derived against; a wider frame opens the gaps past it and never below it.
    public static let minimumBarSpacing: Double = 2.5

    // MARK: - How much time is on screen

    /// How much audio one bar measures.
    ///
    /// ~43 ms, i.e. about 23 bars a second. It is a *fraction of a tap buffer*, not a buffer: at
    /// the 48 kHz of this Mac a 4 096-frame buffer is 85.3 ms, so one level per callback would
    /// update the waveform 11.7 times a second and a syllable would be a single bar. Two blocks
    /// per buffer is what puts the update rate above the 20 Hz the eye reads as continuous.
    ///
    /// (The lot-3 plan says "100 ms sub-blocks … so the level updates at ~20 Hz". Those two are
    /// not the same statement: a 100 ms block is *longer* than the 85.3 ms buffer it would have to
    /// be cut from, and would have lowered the rate to 10 Hz. The 20 Hz is the intent worth
    /// keeping, so it is the number implemented.)
    ///
    /// It lives here rather than in `AudioLevels`, where it was written, because it is now the
    /// waveform's time resolution and not merely the recorder's block size: `maximumBars` is
    /// derived from it, and a derivation whose two halves sit in different targets is one the app
    /// target cannot test.
    public static let blockDuration: Double = 0.043

    /// How far back the waveform shows, at most.
    ///
    /// **Arbitrary, and recorded as arbitrary.** Nothing measured says one second. What it has to
    /// buy is stated: long enough that the shape of the clause just spoken is on screen rather
    /// than an instantaneous level meter -- the six-bar wing showed 0.26 s, which is a VU needle
    /// with steps -- and short enough that the bars still visibly march rather than crawl. It is
    /// also what stops a very wide surface from turning into a dense comb. Tune by use.
    public static let window: TimeInterval = 1

    /// The most bars any surface draws, and therefore the number of levels `LevelHistory` must
    /// hold (`LevelHistory.defaultCapacity`).
    ///
    /// Truncating rather than rounding, so the window is a ceiling that is never exceeded.
    public static let maximumBars = Int(window / blockDuration)

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
        let fitting = Int((width + minimumBarSpacing) / (barWidth + minimumBarSpacing))
        return min(maximumBars, max(1, fitting))
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
        let leftover = width - Double(barCount) * barWidth
        return max(minimumBarSpacing, leftover / Double(barCount - 1))
    }
}
