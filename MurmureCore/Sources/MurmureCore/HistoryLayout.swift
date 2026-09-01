import CoreGraphics

/// The History pane's measurements, in points. `WindowLayout`'s neighbour, split for the reason
/// `StatusPanelLayout` is split from `WaveformLayout`: one surface, one table.
public enum HistoryLayout {
    /// The list column, which holds a truncated line of French with English technical terms plus
    /// a date, a time and a duration. Narrower than this and the transcript line stops being the
    /// row's identity; wider and the detail pane starts losing the width a 400-word transcript
    /// needs.
    public static let listWidth: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) =
        (minimum: 260, ideal: 320, maximum: 420)

    /// Between two cards. The doc corpus's own gap (design notes §1.3), and the only separator
    /// there is — no dividers, here or in the sidebar (§2.2).
    public static let rowSpacing: CGFloat = 8

    /// Inside a card.
    public static let rowPadding = (horizontal: CGFloat(12), vertical: CGFloat(9))

    /// Between the transcript line and the date line inside one card.
    public static let rowLineSpacing: CGFloat = 3

    /// **The selection is a ring, not a fill.** A filled row would be the third strong colour in
    /// the window — the sidebar's selected row already carries the accent — and it would compete
    /// with the transcript, which is the row's identity (design notes §1.3). A ring says "this
    /// one" without repainting the ground the text is read against.
    public static let selectionRingWidth: CGFloat = 1.5

    /// Above a date header, so a group reads as a break rather than as another row.
    public static let groupHeaderSpacing: CGFloat = 18

    /// The widest a transcript is allowed to be set, however wide the window is.
    ///
    /// The measure, in the typographic sense, and the answer to "a 400-word refined transcript
    /// reads rather than walls": a line that runs the full width of a 1 400 pt window is a line
    /// the eye loses its place returning from. Roughly 80 characters at 13 pt.
    public static let transcriptMeasure: CGFloat = 660

    /// Opened up, because this is the one text in the window that is read rather than glanced at.
    public static let transcriptLineSpacing: CGFloat = 5

    /// How many rows one fetch brings back.
    ///
    /// Not paginated: at Louis's measured rate — 98 dictations in two days, and a 30-day text
    /// retention — the whole live history is well inside this, and a scroll position that jumps
    /// when a page lands is a defect nobody asked for. The number is a ceiling against a database
    /// that grew unexpectedly, not a window onto it.
    public static let pageSize = 2_000
}
