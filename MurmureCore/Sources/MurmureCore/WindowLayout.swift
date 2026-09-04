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

    /// The chip tier of §2.3's three radii, and the only one T1 drew.
    public static let chipCornerRadius: CGFloat = 5

    /// The interactive-row tier of §2.3 (10–11 pt): a history row, and every list row after it.
    ///
    /// Arrived with T5, which is the first task to draw one — the note above says the other tiers
    /// land with the panes that draw them, and this is that happening rather than a value being
    /// added on spec.
    public static let rowCornerRadius: CGFloat = 11

    /// The large-surface tier of §2.3 (14–16 pt): the panel the detail pane's transcript sits on.
    public static let surfaceCornerRadius: CGFloat = 14

    /// The three fixed columns of the Models table (design notes §1.1). The name column takes
    /// whatever is left, which is what makes the table a table rather than four labels in a row.
    ///
    /// `type` is a glyph and needs no more than its own tile; `size` holds "1.6 GB" and has to
    /// stay wide enough for the longest thing ``ModelSize`` prints; `action` is one button.
    public static let modelsColumns: (type: CGFloat, size: CGFloat, action: CGFloat) =
        (type: 44, size: 96, action: 44)

    /// The narrowest the model-name column may get before the table stops being readable. The
    /// test beside it is the one that matters: sidebar + this + the three fixed columns has to
    /// fit inside `minimumSize.width`, or the table's last column falls off the smallest window
    /// the app can be resized to.
    public static let modelsNameMinimum: CGFloat = 200

    /// The gap between the lines INSIDE one Vocabulary group's header block -- its heading (with
    /// count) and its subtitle. Tighter than `vocabularyGroupSpacing`, the gap between the two
    /// groups themselves, so a header's own lines read as one paragraph rather than as a third
    /// group floating between the other two.
    public static let vocabularyHeaderSpacing: CGFloat = 6

    /// The gap between Vocabulary's two groups (`VocabularyPaneView`'s outer `VStack`, one group
    /// per heading) -- wide enough that "Words to recognise" and "Corrections" read as two
    /// separate sections, never as two halves of one.
    public static let vocabularyGroupSpacing: CGFloat = 20
}
