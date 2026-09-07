import CoreGraphics

/// The Modes pane's measurements, in points. `HistoryLayout`'s neighbour, split for the same
/// reason: one surface, one table, and nothing in it that the pane does not actually draw.
public enum ModesLayout {
    /// A collapsed row. Measured on the installed app (design notes §2, spacing rhythm), and kept
    /// as a *minimum* rather than a fixed frame: the row grows into the editor when it is
    /// expanded, and a fixed height would clip it.
    public static let rowHeight: CGFloat = 51

    /// Between two cards. The doc corpus's own gap, and the only separator there is.
    public static let rowSpacing: CGFloat = 8

    /// Inside a card.
    public static let rowPadding = (horizontal: CGFloat(14), vertical: CGFloat(10))

    /// The dot after the name of the mode that is running. **The entire active-mode indicator**
    /// (design notes §5): no highlight, no checkmark, no border. Small enough to be a mark rather
    /// than a badge.
    public static let activeDotSize: CGFloat = 7

    /// One stage badge, and the tray they sit in.
    public static let badgeSize: CGFloat = 20
    public static let badgeSpacing: CGFloat = 4
    public static let badgeTrayPadding: CGFloat = 4

    /// The disclosure chevron's column, fixed so the glyphs of every row line up whether or not
    /// the row is expanded.
    public static let chevronWidth: CGFloat = 12

    /// The label column of an editor field. Wide enough for "Instructions" at 12 pt, so the inputs
    /// of every row start on the same vertical.
    public static let fieldLabelWidth: CGFloat = 104

    /// Between two fields of the editor, and between a field and the message under it.
    public static let fieldSpacing: CGFloat = 10
    public static let messageSpacing: CGFloat = 4

    /// The back-chevron strip of the advanced screen.
    ///
    /// Deliberately shorter than `WindowLayout.headerHeight`: the pane's own 46 pt header is still
    /// above it -- `MainWindowView` owns that row and draws it for every section -- so a second
    /// 46 pt bar would read as two titlebars stacked. At 34 pt it reads as what it is, the way
    /// back out of a sub-screen. Should the back chevron ever move up into the shared header, this
    /// strip goes away rather than shrinking further.
    public static let backBarHeight: CGFloat = 34

    /// The Icon field's grid (task 4): tiles per row. Six puts the grid's twelve tiles -- the
    /// "Default" tile plus `ModeSymbol.library`'s eleven entries -- in two full rows -- a picker
    /// whose last row trails off short reads as unfinished layout rather than as "these are all of
    /// them", which is why `ModeSymbolTests` pins `library.count + 1` against this constant rather
    /// than the two being free to drift apart.
    public static let iconGridColumns = 6

    /// Between two icon tiles, in both directions. Tiles are `WindowLayout.sidebarTileSize`, the
    /// same square the sidebar's own section glyphs sit on -- no new size for one more grid of
    /// glyphs.
    public static let iconGridSpacing: CGFloat = 6

    /// What the preview block (§1) is introduced by, and its own frame: tall enough to show a
    /// short `.chat` system turn without scrolling on the first look, capped so a very long one
    /// scrolls inside its own box rather than pushing Instructions and Context off the bottom of
    /// the card.
    public static let previewHeight: (minimum: CGFloat, maximum: CGFloat) = (minimum: 90, maximum: 220)

    /// The "Draft a mode with help" sheet's chat log: the gap between two bubbles.
    public static let draftBubbleSpacing: CGFloat = 10

    /// How much of the sheet's own fixed width (`WindowLayout.draftSheetWidth`, not the log's own
    /// -- scrollable, and narrower once its padding is subtracted) one bubble's `.frame(maxWidth:)`
    /// may take -- wide enough that a fenced JSON block does not wrap on every third word, capped
    /// so a one-line reply does not stretch edge to edge and read like a system message rather
    /// than one side of a conversation.
    public static let draftBubbleMaxWidthFraction: CGFloat = 0.86
}
