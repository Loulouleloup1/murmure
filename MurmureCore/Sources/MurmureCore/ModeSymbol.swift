import Foundation

/// The icon library a mode's own `symbol` (``Mode/symbol``) is picked from — the Modes editor's
/// icon grid.
///
/// Eleven SF Symbol names, each verified individually with `NSImage(systemSymbolName:
/// accessibilityDescription:)` -- run on this machine (macOS 26.6.2, the only OS available to run
/// it on) rather than typed from memory -- rather than assumed for `macOS(.v14)`, the package's own
/// deployment target: every one of the eleven is old enough to predate it (SF Symbols additions are
/// additive across releases, so a symbol confirmed present on 26.6.2 and not newly introduced by
/// it is present on 14 too; none of the eleven below is a recent addition). A name that does not
/// exist draws a blank tile in the grid, which is a worse failure than a smaller library.
///
/// **One list, no separate Default tile.** The grid (`ModesPaneView.iconTile(_:for:draft:)`) draws
/// the library once, in order; there is no thirteenth tile standing apart from it. `mic.fill` and
/// `sparkles` are kept in the eleven even though they are also the two stage defaults
/// (``ModeStage/symbolName``) a mode falls back to when `symbol` is nil, because each is still an
/// ordinary tile for the *other* stage's mode -- `sparkles` is a real, explicit choice for a
/// dictation mode, `mic.fill` for a refiner one. The tile that matches the *current* mode's own
/// stage default is the one exception: it carries the small "Default" caption, reads as selected
/// both when `symbol == nil` and when `symbol` already equals its name, and tapping it always
/// stores `nil` rather than the name -- so the grid keeps exactly one way back to "nothing chosen"
/// without adding a tile for it. Every other tile stores its own name on tap, plainly.
///
/// **Eleven, not twelve.** `quote.bubble` was dropped (review, lot 3a leftovers, item 2): eleven
/// tiles at `ModesLayout.iconGridColumns` == 6 is two full rows (6 + 5, the second short by one),
/// not the trailing row of one a twelfth entry would have made. `quote.bubble` was the one dropped
/// because it reads as a near-duplicate of `text.bubble`, kept above it, rather than because of
/// anything about the glyph itself.
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

    /// The glyph a mode shows when it has chosen none: the stage default. The picker captions that
    /// tile "Default" and stores `nil` for it, so the list holds each glyph once.
    public static func isStageDefault(_ symbol: String, for stage: ModeStage) -> Bool {
        symbol == stage.symbolName
    }
}
