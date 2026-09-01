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

    /// The dictation's drawing: two `DictationPhaseView` halves of 32 pt each, which is the notch
    /// wing's width. The same drawing at the same size on both surfaces, so a dictation looks
    /// identical whichever display it was started on -- that is the whole reason the halves are one
    /// view and not two.
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
