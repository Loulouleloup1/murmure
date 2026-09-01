import XCTest
@testable import MurmureCore

/// That the token table is **total** — and that "total" means more than "it compiles".
///
/// The compiler already refuses a role with no value: `WindowPalette.token(for:)` has no
/// `default`. What it cannot refuse is a role given a value that draws nothing — white text at 2 %
/// opacity, or a glyph the same brightness as the tile under it. Black on black compiles
/// perfectly, and it is the exact failure that makes shipping dark-only cheap now and expensive
/// later, so it is what these tests are about.
final class WindowPaletteTests: XCTestCase {
    /// Roughly what one colour looks like once it has been drawn *onto* another. Greys and
    /// opacity only, which is what the table is made of — it is not a colour-science model and it
    /// is not trying to be, it is the difference between "there is a value" and "you can see it".
    private func composited(_ token: ColorToken, on ground: ColorToken) -> Double {
        token.brightness * token.opacity + ground.brightness * (1 - token.opacity)
    }

    private func contrast(_ role: WindowRole, on groundRole: WindowRole) -> Double {
        let ground = WindowPalette.token(for: groundRole)
        return abs(composited(WindowPalette.token(for: role), on: ground) - ground.brightness)
    }

    // MARK: - The table resolves, everywhere

    /// Every role, and every component inside the range `Color(hue:saturation:brightness:opacity:)`
    /// accepts. A component outside 0…1 is clamped silently by SwiftUI, so nothing on screen would
    /// say which token was wrong.
    func testEveryRoleResolvesToAColourSwiftUICanDraw() {
        for role in WindowRole.allCases {
            let token = WindowPalette.token(for: role)
            for (name, value) in [
                ("hue", token.hue), ("saturation", token.saturation),
                ("brightness", token.brightness), ("opacity", token.opacity),
            ] {
                XCTAssertTrue(
                    value.isFinite && value >= 0 && value <= 1,
                    "\(role).\(name) is \(value), outside 0…1")
            }
        }
    }

    /// The cheapest way to add a role and draw nothing: leave its opacity at zero. Every role in
    /// the table is drawn somewhere, so none of them may be fully transparent.
    func testNoRoleIsFullyTransparent() {
        for role in WindowRole.allCases {
            XCTAssertGreaterThan(
                WindowPalette.token(for: role).opacity, 0, "\(role) would draw nothing")
        }
    }

    // MARK: - Black on black

    /// Every pair in the window where something is drawn on top of something else, and the amount
    /// of separation each pair has. 0.35 is a judgement, and a generous one: it is well below what
    /// body text against its background needs and comfortably above the point where a glyph starts
    /// to disappear into its tile.
    func testEveryMarkIsLegibleAgainstTheSurfaceItIsDrawnOn() {
        let pairs: [(WindowRole, WindowRole)] = [
            (.primaryText, .paneBackground),
            (.secondaryText, .paneBackground),
            (.primaryText, .sidebarBackground),
            (.secondaryText, .sidebarBackground),
            (.primaryText, .selection),
            (.materialGlyph, .materialTile),
            (.machineryGlyph, .machineryTile),
        ]
        for (mark, ground) in pairs {
            XCTAssertGreaterThanOrEqual(
                contrast(mark, on: ground), 0.35,
                "\(mark) on \(ground) is too close to read")
        }
    }

    /// The hairline is the one mark with a ceiling as well as a floor, and both edges are the
    /// design. §2.2 removes divider rules from the window entirely — the grouping device is a gap
    /// — so the line closing the section header has to be faint enough to read as an edge and not
    /// as a rule, while still being visible at all.
    func testTheHairlineIsVisibleWithoutBecomingADividerRule() {
        for ground in [WindowRole.paneBackground, .sidebarBackground] {
            let separation = contrast(.hairline, on: ground)
            XCTAssertGreaterThanOrEqual(separation, 0.04, "the hairline on \(ground) is invisible")
            XCTAssertLessThanOrEqual(separation, 0.25, "the hairline on \(ground) is a rule")
        }
    }

    /// The sidebar and the pane are two surfaces with no rule between them, so the split has to be
    /// carried by the grounds themselves — far enough apart to read as two surfaces, close enough
    /// that neither reads as a panel laid over the other.
    func testTheSidebarAndThePaneReadAsTwoSurfacesWithNoRuleBetweenThem() {
        let separation = abs(
            WindowPalette.token(for: .sidebarBackground).brightness
                - WindowPalette.token(for: .paneBackground).brightness)
        XCTAssertGreaterThan(separation, 0.02)
        XCTAssertLessThan(separation, 0.15)
    }

    // MARK: - One visual language

    /// D4, and the condition Louis attached to Q-NB4: the window's accent is the notch's, reused
    /// and not re-picked. Two constants that happened to hold the same violet today would drift
    /// the first time he moves one — and the hue is explicitly a placeholder he may move.
    func testTheAccentIsTheNotchsOwnRatherThanASecondOne() {
        for role in [WindowRole.materialTile, .selection] {
            let token = WindowPalette.token(for: role)
            XCTAssertEqual(token.hue, NotchAppearance.accentHue, "\(role) is not the notch's hue")
            XCTAssertEqual(token.saturation, NotchAppearance.accentSaturation)
        }
    }

    /// §2.2's icon-colour split, as a fact about the colours and not about the names: the
    /// material tile carries colour, the machinery tile carries none. A "dimmer accent" for the
    /// machinery half would make the split an emphasis; it has to read as a kind.
    func testTheMaterialHalfIsColouredAndTheMachineryHalfIsNot() {
        XCTAssertGreaterThan(WindowPalette.token(for: .materialTile).saturation, 0)
        XCTAssertEqual(WindowPalette.token(for: .machineryTile).saturation, 0)
    }

    /// The one place that knows both halves of a tile. A group whose glyph role belonged to the
    /// other group's tile would pass every contrast test above and still draw white on white.
    func testEachHalfAsksForItsOwnTileAndItsOwnGlyph() {
        XCTAssertEqual(WindowPalette.tile(for: .material).tile, .materialTile)
        XCTAssertEqual(WindowPalette.tile(for: .material).glyph, .materialGlyph)
        XCTAssertEqual(WindowPalette.tile(for: .machinery).tile, .machineryTile)
        XCTAssertEqual(WindowPalette.tile(for: .machinery).glyph, .machineryGlyph)
    }

    /// Both halves of the split are covered by the pair above — stated as its own line so that a
    /// third group added to `WindowSectionGroup` fails here rather than quietly reusing whichever
    /// tile the switch happened to be written with first.
    func testEveryGroupHasATile() {
        for group in WindowSectionGroup.allCases {
            let pair = WindowPalette.tile(for: group)
            XCTAssertNotEqual(pair.tile, pair.glyph, "\(group) would draw its glyph on itself")
        }
    }
}
