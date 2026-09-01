import CoreGraphics

/// The window's measurements, in points.
///
/// Here rather than in the view for the reason `WaveformLayout` and `StatusPanelLayout` are here:
/// `Murmure` has no test bundle, so a number written into a `.frame(height:)` is a decision nothing
/// can check and nothing can find again. Only what this task actually draws is below — §2.3's
/// other two corner-radius tiers (large surfaces 14–16 pt, interactive rows 10–11 pt) arrive with
/// the panes that draw them, because a constant nothing reads is a constant nobody maintains.
public enum WindowLayout {
    /// What the window opens at the very first time, before there is a stored frame.
    ///
    /// Wider than Superwhisper's fixed 750 × 500 settings window on purpose: theirs is a settings
    /// window and ours is not (D1/D3). History is the section this size is for — a truncated line
    /// of transcript plus a date and a duration needs the width, and the whole reason this is a
    /// `Window` and not a `Settings` scene is that it can be resized past whatever is chosen here.
    public static let defaultSize = CGSize(width: 980, height: 660)

    /// Below this the sidebar and the detail pane stop being two things.
    ///
    /// Also the floor `WindowRestoration` does *not* enforce, deliberately: AppKit clamps a
    /// restored frame to the window's own `minSize` and then stores the clamped one back, so a
    /// second rule here would only ever disagree with the first.
    public static let minimumSize = CGSize(width: 720, height: 460)

    /// The sidebar, which is six short words and never needs to be wider.
    public static let sidebarWidth: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) =
        (minimum: 168, ideal: 196, maximum: 240)

    /// The per-section header row (plan §2.3): a contextual toolbar, not a titlebar. There are no
    /// page titles anywhere in this window — the installed app deleted heading prose entirely
    /// (design notes §1.4) and each pane opens straight onto its content.
    public static let headerHeight: CGFloat = 46

    /// The line closing the header. One point, drawn at `WindowRole.hairline`'s 10 % — the pair is
    /// what keeps it a *hairline* rather than the divider rule §2.2 rules out.
    public static let hairlineWidth: CGFloat = 1

    /// The rounded square behind a sidebar row's glyph — the thing that carries the material /
    /// machinery colour split.
    public static let sidebarTileSize: CGFloat = 22

    /// The chip tier of §2.3's three radii, and the only one this task draws.
    public static let chipCornerRadius: CGFloat = 5
}
