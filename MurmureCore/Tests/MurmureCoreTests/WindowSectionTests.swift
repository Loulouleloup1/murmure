import XCTest
@testable import MurmureCore

/// The sidebar, pinned as a shape rather than as six cases that happen to exist.
///
/// The guarantee being made is `NotchCard.symbolName(for:)`'s, one layer up: a section added later
/// cannot silently land in the wrong half or inherit a blank square. The compiler makes half of it
/// — the three switches have no `default` — and everything below is the half a compiler cannot
/// make, which is that the order, the split and the glyphs are the ones §2.2 asked for.
final class WindowSectionTests: XCTestCase {
    // MARK: - The order

    /// Declaration order is sidebar order, so this is the sidebar. Written out in full rather than
    /// checked property by property: the order IS the decision (D3, plan §4.1), and spec §6's own
    /// `General · Modes · Models · Vocabulary · History · Advanced` is the thing this refuses.
    func testTheSidebarOrderIsTheOneTheWindowDraws() {
        XCTAssertEqual(
            WindowSection.allCases,
            [.home, .history, .modes, .vocabulary, .models, .general, .advanced])
    }

    /// D3 on its own, because it is the decision the order exists to carry: History is the
    /// section with a daily reason to be opened, right after the Home overview, and the other
    /// five are opened when something changes.
    func testHistoryIsSecond() {
        XCTAssertEqual(WindowSection.allCases.dropFirst().first, .history)
    }

    // MARK: - The split that replaces the dividers

    func testTheColouredHalfIsTheUsersOwnMaterial() {
        XCTAssertEqual(
            WindowSection.sections(in: .material), [.home, .history, .modes, .vocabulary])
    }

    func testTheNeutralHalfIsTheAppsMachinery() {
        XCTAssertEqual(WindowSection.sections(in: .machinery), [.models, .general, .advanced])
    }

    /// The property the window's whole grouping device rests on. The sidebar draws two lists, in
    /// this order, and the gap between them is the entire break — no rule, no heading (§2.2). That
    /// only renders as §2.2 while the two halves are **contiguous runs** of the order above: a
    /// seventh section declared between Vocabulary and Models, in the machinery group, would draw
    /// a second gap and a second grouping nobody decided on.
    func testTheTwoHalvesAreContiguousRunsInSidebarOrder() {
        XCTAssertEqual(
            WindowSection.sections(in: .material) + WindowSection.sections(in: .machinery),
            WindowSection.allCases)
    }

    /// Every section is in exactly one half — which `group` being total makes true, and which is
    /// stated so that the line above cannot be satisfied by a section belonging to neither.
    func testEverySectionIsInOneHalfOrTheOther() {
        XCTAssertEqual(
            WindowSection.sections(in: .material).count
                + WindowSection.sections(in: .machinery).count,
            WindowSection.allCases.count)
    }

    // MARK: - The glyphs

    /// The blank-square guarantee. `NotchCard` makes it for phases with a card; there is no
    /// section without a row, so here it holds for all six.
    func testEverySectionCarriesAGlyph() {
        for section in WindowSection.allCases {
            XCTAssertFalse(section.symbolName.isEmpty, "\(section) must carry a glyph")
        }
    }

    /// The glyph is what the row is found by once the window is a habit. Two sections wearing one
    /// symbol would make the tile decoration rather than an address.
    func testNoTwoSectionsShareAGlyph() {
        let glyphs = Set(WindowSection.allCases.map(\.symbolName))
        XCTAssertEqual(glyphs.count, WindowSection.allCases.count)
    }

    /// `sparkles` is the notch's `refining` phase. A settings section wearing the phase's own
    /// symbol would make the two mean each other — the section where refinement is *configured*
    /// is not the moment a refinement is *running*.
    func testTheModesSectionDoesNotWearTheRefiningPhasesGlyph() {
        XCTAssertNotEqual(WindowSection.modes.symbolName, NotchCard.symbolName(for: .refining))
    }

    // MARK: - The titles

    func testEverySectionCarriesADistinctTitle() {
        for section in WindowSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) must carry a title")
        }
        XCTAssertEqual(Set(WindowSection.allCases.map(\.title)).count, WindowSection.allCases.count)
    }

    // MARK: - The storage names

    /// Written out literally, with real values, for `ModePreference`'s reason: the raw value is
    /// the name the selected section is filed under, and a rename forgets which section the window
    /// was left on. A test that read the constant back off the enum would agree with any rename.
    func testTheStorageNamesAreTheOnesTheyAlreadyHave() {
        XCTAssertEqual(WindowSection.home.rawValue, "home")
        XCTAssertEqual(WindowSection.history.rawValue, "history")
        XCTAssertEqual(WindowSection.modes.rawValue, "modes")
        XCTAssertEqual(WindowSection.vocabulary.rawValue, "vocabulary")
        XCTAssertEqual(WindowSection.models.rawValue, "models")
        XCTAssertEqual(WindowSection.general.rawValue, "general")
        XCTAssertEqual(WindowSection.advanced.rawValue, "advanced")
    }

    /// Not `.general`, which is what a settings window would fall back to. Six of the seven are
    /// settings and Home is the overview.
    func testTheFallbackSectionIsHome() {
        XCTAssertEqual(WindowSection.fallback, .home)
    }

    // MARK: - Home

    func testHomeIsAMaterialSectionWithItsOwnSymbol() {
        XCTAssertEqual(WindowSection.home.title, "Home")
        XCTAssertEqual(WindowSection.home.symbolName, "chart.bar.xaxis")
        XCTAssertEqual(WindowSection.home.group, .material)
        XCTAssertEqual(WindowSection.sections(in: .material).first, .home)
        XCTAssertEqual(WindowSection.fallback, .home)
    }
}
