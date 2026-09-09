import CoreGraphics

/// Layout constants of the Home pane. Pinned by `HomeLayoutTests` so a drift is a deliberate act.
public enum HomeLayout {
    /// Outer padding of the pane; the other panes use the same 16 pt as a literal.
    public static let panePadding: CGFloat = 16
    public static let contentMaxWidth: CGFloat = 920
    public static let cardCornerRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 16
    public static let gridSpacing: CGFloat = 12
    public static let figureFontSize: CGFloat = 30
    public static let heatmapCellSize: CGFloat = 11
    public static let heatmapCellGap: CGFloat = 3
    /// Brightness of the accent hue for heatmap levels 1…4; level 0 uses the hairline role.
    public static let heatBrightness: [Double] = [0.35, 0.55, 0.75, 1.0]
}
