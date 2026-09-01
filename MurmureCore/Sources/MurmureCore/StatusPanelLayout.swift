import CoreGraphics

/// The floating panel's fixed geometry, as the sum it actually is.
///
/// **The width is not a number, it is a budget**, and writing it as `260` hid that. The strip is
/// exactly as wide as the longest sentence `StatusPanelText` can produce needs it to be, plus the
/// drawing, plus the space between them -- and the comment that used to say so drifted: it put the
/// longest line at "about 149 pt" where CoreText measures 142.34, and nothing could tell. Written
/// as `labelSlot` and its neighbours, the rule that matters becomes a test (`StatusPanelLayoutTests`)
/// instead of an estimate in prose.
///
/// It lives here rather than beside the view for the reason the rest of `MurmureCore` exists: the
/// `Murmure` target has no test bundle, so a width chosen in a `View` is a width nothing can check.
public enum StatusPanelLayout {
    /// The strip's height. A status bar, not a card: tall enough for one 12 pt line and the 16 pt
    /// drawing, and no taller, so it reads as an indicator rather than as a window.
    public static let height: CGFloat = 34

    /// The inset on each end, inside the capsule's own stroke.
    public static let horizontalPadding: CGFloat = 14

    /// The dictation's drawing: **one** `DictationPhaseView` across the whole 64 pt while a
    /// recording is running, or two mirrored halves of 32 for every other phase.
    ///
    /// Which it is belongs to `NotchAppearance.isMirrored(for:)` rather than to this number, so
    /// the panel and the notch card cannot disagree about a phase.
    ///
    /// The same view as the notch card's, at a size of its own. It used to be the same *size* as
    /// well -- 32 pt was the notch wing's width, back when the notch had wings -- and the sentence
    /// that stood here said a dictation therefore looked identical on either display. That stopped
    /// being true when the notch became a 400 pt card: what the two surfaces share is the drawing
    /// and its cadence, not its scale. `WaveformLayout` is what keeps 64 pt meaning twelve bars
    /// here while the card fits its own, so this number needs no defending against that one.
    ///
    /// **It stays 64 pt, and the exchange rate is why.** Once the recording became a single series
    /// the obvious next question was whether the drawing now wants to be wider -- 64 pt is a small
    /// object in a 260 pt strip. But the card's defect was *emptiness inside the drawing*: 61 pt of
    /// bars marooned in a 340 pt frame. This row has none; it fills its frame exactly. What sits
    /// beside it is not void, it is 158 pt of sentence.
    ///
    /// And the panel's bars are pinned to `minimumBarWidth`, so here width buys history at a flat
    /// 5.5 pt per bar -- 43 ms each. Every point `labelSlot` can spare (7.93, before a five-digit
    /// completion truncates) buys **one** bar. Spending a label's entire safety margin on 43 ms is
    /// not a trade, and `StatusPanelLayoutTests` pins it so the next reader gets the number rather
    /// than the intuition. Widening the capsule itself would work -- +32 pt is five bars and
    /// 0.21 s -- but that is the one thing this panel is not: a second card.
    public static let drawingWidth: CGFloat = 64

    /// Between the drawing and the sentence. Wide enough that they read as two things.
    public static let spacing: CGFloat = 10

    /// The point size the sentence is set at, and therefore half of what `labelSlot` has to be
    /// wide enough for. Here rather than in the view because a width budget whose font size lives
    /// somewhere else is a budget that can be invalidated from somewhere else.
    public static let labelFontSize: CGFloat = 12

    /// The room the sentence gets, and **the number the panel's width is derived from**.
    ///
    /// 158 pt, which fits every fixed sentence the panel can say with room to spare: the widest is
    /// a completion with a five-digit count, 150.07 pt at `labelFontSize` in the rounded system
    /// font. The count is the reason the slot is this wide and not 90 -- `StatusPanelText` says why
    /// it must survive: it is the difference between "it worked" and "it thinks it worked".
    ///
    /// A `failed` or `alert` message is not covered and cannot be: it carries text from wherever
    /// the failure came from, and "The microphone is not available" is 179 pt. Those truncate at
    /// the tail, by design, which is why the beginning of a failure is the part that names it.
    public static let labelSlot: CGFloat = 158

    /// The strip's width, as the sum of what is inside it.
    ///
    /// Derived and not stated, so that changing any part moves the whole and the two can never
    /// disagree. It comes to 260 pt, which is the width Louis has been looking at.
    public static let width = horizontalPadding * 2 + drawingWidth + spacing + labelSlot

    public static let size = CGSize(width: width, height: height)
}
