import Foundation

/// One colour, as the four numbers SwiftUI's `Color(hue:saturation:brightness:opacity:)` takes.
///
/// Numbers and not a `Color`, for the reason `NotchAppearance` gives at the top of its own file:
/// `MurmureCore` has no SwiftUI in it, and the seam that already works is the one
/// `DictationPhaseView` uses — the package chooses the components, the view assembles them. It is
/// also what lets this be tested at all; a `Color` is opaque and two of them cannot be compared
/// for anything a test could learn from.
public struct ColorToken: Equatable, Sendable {
    /// 0…1, the way SwiftUI counts hues. Meaningless when `saturation` is 0, which is every grey
    /// in the table below.
    public let hue: Double
    public let saturation: Double
    public let brightness: Double
    /// 1 unless the colour is deliberately drawn *through* whatever is behind it — the hairline
    /// and the muted text are the only two.
    public let opacity: Double

    public init(hue: Double = 0, saturation: Double = 0, brightness: Double, opacity: Double = 1) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.opacity = opacity
    }

    /// A grey: no hue, no saturation, one number.
    public static func grey(_ brightness: Double, opacity: Double = 1) -> ColorToken {
        ColorToken(brightness: brightness, opacity: opacity)
    }
}

/// Every colour the window draws, named by what it means rather than by what it is.
///
/// The whole point of the enum is that **no call site in `Murmure/` may write a colour**. That is
/// the condition attached to shipping this lot dark-only (Q-NB6): dark-only is cheap now and
/// expensive to retrofit, and the difference between the two is entirely whether the colours are
/// in one table or spread across five panes. Light mode, when it comes, is an `appearance`
/// parameter on `WindowPalette.token(for:)` and a second `switch` underneath this one — this file
/// changes and nothing else does. A single `Color(white: 0.2)` written into a view is what would
/// turn that into five panes to revisit, so it is worth being pedantic about.
public enum WindowRole: String, CaseIterable, Sendable {
    /// The ground of the detail pane and of the section header above it.
    case paneBackground
    /// The ground of the sidebar. Distinct from the pane so the split reads without a rule
    /// between the two.
    case sidebarBackground
    /// The line closing the section header (plan §2.3). Deliberately faint — see `hairlineWidth`.
    case hairline
    /// Text that is being read.
    case primaryText
    /// Text that is being glanced at: the active mode in the header, an unselected sidebar row.
    case secondaryText
    /// The selected sidebar row. Murmure's own accent, never the system one — a window whose
    /// selection was the user's system blue would be a second visual language (D4).
    case selection
    /// The tile behind a *material* section's glyph: History, Modes, Vocabulary.
    case materialTile
    /// The glyph on it.
    case materialGlyph
    /// The tile behind a *machinery* section's glyph: Models, General, Advanced.
    case machineryTile
    /// The glyph on it.
    case machineryGlyph
}

/// The token table. Dark only, for this lot (D18, Q-NB6).
public enum WindowPalette {
    /// The colour of one role.
    ///
    /// Written **without a `default`**, which is the compile-time half of "the table is total": a
    /// role added to `WindowRole` does not build until it has a colour. The other half is a test
    /// that walks `WindowRole.allCases`, because a role can be given a value that is present and
    /// still invisible, and black on black compiles perfectly.
    public static func token(for role: WindowRole) -> ColorToken {
        switch role {
        // Not pure black. The window is a real window with a shadow and a titlebar, and pure
        // black makes the traffic lights sit on a hole rather than on a surface. The notch is
        // black because it is drawn on a hardware cutout that already is; a window is not.
        case .paneBackground: .grey(0.13)
        case .sidebarBackground: .grey(0.09)
        // Drawn *through*, so this is one value that works on either ground above.
        case .hairline: .grey(1, opacity: 0.10)
        case .primaryText: .grey(0.97)
        // Muted by opacity rather than by a darker grey, so it stays legible against both the
        // pane and the sidebar without needing to be two tokens.
        case .secondaryText: .grey(0.97, opacity: 0.55)
        case .selection: accent(brightness: 0.52)
        // The material half. The accent, reused rather than re-picked (D4): the hue is
        // `NotchAppearance.accentHue` itself and a test refuses any other value, because a window
        // whose accent differed from the notch's would be a second interface.
        case .materialTile: accent(brightness: 0.58)
        case .materialGlyph: .grey(1)
        // The machinery half: the same tile, with the colour taken out. Not a *dimmer* accent —
        // the split has to be readable as a kind, not as an emphasis.
        case .machineryTile: .grey(0.26)
        case .machineryGlyph: .grey(0.88)
        }
    }

    /// The tile a section's glyph sits on, and the glyph on it — the icon-colour split of §2.2 in
    /// the one place that knows both halves.
    public static func tile(for group: WindowSectionGroup) -> (tile: WindowRole, glyph: WindowRole) {
        switch group {
        case .material: (.materialTile, .materialGlyph)
        case .machinery: (.machineryTile, .machineryGlyph)
        }
    }

    /// The accent, at the brightness a given surface needs.
    ///
    /// Hue and saturation come from `NotchAppearance` and are not restated: `accentSaturation` is
    /// 0.55 because the notch draws a 4 pt bar on pure black, and the same restraint happens to be
    /// right on a tile — but if Louis moves the hue (it is a placeholder answering lot 3's Q-NB2)
    /// it must move in both surfaces at once, and the only way to guarantee that is to have one
    /// definition.
    private static func accent(brightness: Double) -> ColorToken {
        ColorToken(
            hue: NotchAppearance.accentHue,
            saturation: NotchAppearance.accentSaturation,
            brightness: brightness)
    }
}
