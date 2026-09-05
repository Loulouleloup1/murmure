import Foundation

/// The icon library a mode's own `symbol` (``Mode/symbol``) is picked from — the Modes editor's
/// icon grid (task 4).
///
/// Eleven SF Symbol names, each verified individually with `NSImage(systemSymbolName:
/// accessibilityDescription:)` -- run on this machine (macOS 26.6.2, the only OS available to run
/// it on) rather than typed from memory -- rather than assumed for `macOS(.v14)`, the package's own
/// deployment target: every one of the eleven is old enough to predate it (SF Symbols additions are
/// additive across releases, so a symbol confirmed present on 26.6.2 and not newly introduced by
/// it is present on 14 too; none of the eleven below is a recent addition). A name that does not
/// exist draws a blank tile in the grid, which is a worse failure than a smaller library.
/// `mic.fill` and `sparkles` are kept in the eleven even though they are also the
/// two stage defaults (``ModeStage/symbolName``) a mode falls back to when `symbol` is nil — so
/// picking either one explicitly is a real choice in the grid, not a value the grid refuses to
/// offer because the stage already implies it.
///
/// **Eleven, not twelve.** `quote.bubble` was dropped (review, lot 3a leftovers, item 2): with the
/// grid's own "Default" tile (``ModesPaneView/iconPicker(_:)``) counted in, twelve library entries
/// made thirteen tiles at `ModesLayout.iconGridColumns` == 6, a trailing row of one -- the exact
/// half-finished-looking layout the grid was built to avoid. Eleven plus the Default tile fills
/// exactly two rows of six. `quote.bubble` was the one dropped because it reads as a near-duplicate
/// of `text.bubble`, kept above it, rather than because of anything about the glyph itself.
public enum ModeSymbol {
    /// The picker's own entries, in the order the grid draws them.
    public static let library: [String] = [
        "mic.fill",
        "sparkles",
        "text.bubble",
        "terminal",
        "doc.text",
        "envelope",
        "chevron.left.forwardslash.chevron.right",
        "brain",
        "globe",
        "pencil.line",
        "list.bullet",
    ]
}
