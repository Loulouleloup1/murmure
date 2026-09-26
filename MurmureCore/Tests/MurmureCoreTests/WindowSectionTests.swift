import XCTest
@testable import MurmureCore

/// The sidebar, pinned as a shape rather than as eight cases that happen to exist.
///
/// The guarantee being made is `NotchCard.symbolName(for:)`'s, one layer up: a section added later
/// cannot silently land in the wrong half or inherit a blank square. The compiler makes half of it
/// — the three switches have no `default` — and everything below is the half a compiler cannot
/// make, which is that the order, the split and the glyphs are the ones §2.2 asked for.
///
/// **Lot 9 added the eighth case, `.transcripts`, and it arrived through this file rather than
/// beside it**: R8 decided its name, its title, its glyph and its place in one line, and every
/// assertion those four decisions touch is below. The assertions that are red today carry
/// `contrat lot 9 : non implémenté` — they are waiting for the sentinel bodies in
/// `WindowSection.swift` to be replaced, not for a test to be relaxed.
final class WindowSectionTests: XCTestCase {
    /// What every lot-9 assertion that is red today carries, so a failure says which contract it
    /// belongs to rather than only which line moved.
    private let contrat = "contrat lot 9 : non implémenté"

    // MARK: - The order

    /// Declaration order is sidebar order, so this is the sidebar. Written out in full rather than
    /// checked property by property: the order IS the decision (D3, plan §4.1), and spec §6's own
    /// `General · Modes · Models · Vocabulary · History · Advanced` is the thing this refuses.
    ///
    /// `.transcripts` is third because R8 put it immediately after `.history`: it is the other half
    /// of the same promise — the user's own material, kept and readable again — not a setting.
    func testTheSidebarOrderIsTheOneTheWindowDraws() {
        XCTAssertEqual(
            WindowSection.allCases,
            [.home, .history, .transcripts, .modes, .vocabulary, .models, .general, .advanced],
            contrat)
    }

    /// R8 on its own, because the position is half the decision: a library of videos placed among
    /// the settings would read as a preference about transcription rather than as an archive.
    func testTranscriptsComesRightAfterHistory() {
        XCTAssertEqual(WindowSection.allCases.firstIndex(of: .history), 1, contrat)
        XCTAssertEqual(WindowSection.allCases.firstIndex(of: .transcripts), 2, contrat)
        XCTAssertEqual(WindowSection.allCases.dropFirst(2).first, .transcripts, contrat)
    }

    /// D3 on its own, because it is the decision the order exists to carry: History is the
    /// section with a daily reason to be opened, right after the Home overview, and the other six
    /// are opened when something changes.
    func testHistoryIsSecond() {
        XCTAssertEqual(WindowSection.allCases.dropFirst().first, .history)
    }

    // MARK: - The split that replaces the dividers

    func testTheColouredHalfIsTheUsersOwnMaterial() {
        XCTAssertEqual(
            WindowSection.sections(in: .material),
            [.home, .history, .transcripts, .modes, .vocabulary], contrat)
    }

    func testTheNeutralHalfIsTheAppsMachinery() {
        XCTAssertEqual(
            WindowSection.sections(in: .machinery), [.models, .general, .advanced], contrat)
    }

    /// The property the window's whole grouping device rests on. The sidebar draws two lists, in
    /// this order, and the gap between them is the entire break — no rule, no heading (§2.2). That
    /// only renders as §2.2 while the two halves are **contiguous runs** of the order above: a
    /// section declared between Vocabulary and Models, in the machinery group, would draw a
    /// second gap and a second grouping nobody decided on. `.transcripts` is the case that would
    /// have broken it had R8 put it anywhere else.
    func testTheTwoHalvesAreContiguousRunsInSidebarOrder() {
        XCTAssertEqual(
            WindowSection.sections(in: .material) + WindowSection.sections(in: .machinery),
            WindowSection.allCases, contrat)
    }

    /// Every section is in exactly one half — which `group` being total makes true, and which is
    /// stated so that the line above cannot be satisfied by a section belonging to neither.
    func testEverySectionIsInOneHalfOrTheOther() {
        XCTAssertEqual(
            WindowSection.sections(in: .material).count
                + WindowSection.sections(in: .machinery).count,
            WindowSection.allCases.count, contrat)
    }

    // MARK: - The glyphs

    /// The blank-square guarantee. `NotchCard` makes it for phases with a card; there is no
    /// section without a row, so here it holds for all eight.
    func testEverySectionCarriesAGlyph() {
        for section in WindowSection.allCases {
            XCTAssertFalse(section.symbolName.isEmpty, "\(section) must carry a glyph — \(contrat)")
        }
    }

    /// The glyph is what the row is found by once the window is a habit. Two sections wearing one
    /// symbol would make the tile decoration rather than an address.
    func testNoTwoSectionsShareAGlyph() {
        let glyphs = Set(WindowSection.allCases.map(\.symbolName))
        XCTAssertEqual(glyphs.count, WindowSection.allCases.count, contrat)
    }

    /// R8 froze the glyph as `text.bubble`, and distinct from the seven that were already there —
    /// which is the rule the type's own doc comment states and no test could see until this case
    /// existed. Named here as well as in the sweep above so that a collision says which section
    /// arrived.
    func testTheTranscriptsGlyphIsTheTextBubbleAndDiffersFromTheSevenOthers() {
        XCTAssertEqual(WindowSection.transcripts.symbolName, "text.bubble", contrat)
        let autres = WindowSection.allCases
            .filter { $0 != .transcripts }
            .map(\.symbolName)
        XCTAssertFalse(autres.contains("text.bubble"), contrat)
        XCTAssertEqual(autres.count, 7, contrat)
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
            XCTAssertFalse(section.title.isEmpty, "\(section) must carry a title — \(contrat)")
        }
        XCTAssertEqual(
            Set(WindowSection.allCases.map(\.title)).count, WindowSection.allCases.count, contrat)
    }

    /// R8's title and half, together, because they are one decision: the word in the sidebar, and
    /// which of the two colours it is drawn in.
    func testTheTranscriptsSectionIsTitledTranscriptsAndIsTheUsersOwnMaterial() {
        XCTAssertEqual(WindowSection.transcripts.title, "Transcripts", contrat)
        XCTAssertEqual(WindowSection.transcripts.group, .material, contrat)
        XCTAssertTrue(WindowSection.sections(in: .material).contains(.transcripts), contrat)
        XCTAssertFalse(WindowSection.sections(in: .machinery).contains(.transcripts), contrat)
    }

    // MARK: - The storage names

    /// Written out literally, with real values, for `ModePreference`'s reason: the raw value is
    /// the name the selected section is filed under, and a rename forgets which section the window
    /// was left on. A test that read the constant back off the enum would agree with any rename.
    ///
    /// `.transcripts` is here because R8 named it as the risky half of the decision — the title and
    /// the glyph can be changed later without losing anything, this cannot.
    func testTheStorageNamesAreTheOnesTheyAlreadyHave() {
        XCTAssertEqual(WindowSection.home.rawValue, "home")
        XCTAssertEqual(WindowSection.history.rawValue, "history")
        XCTAssertEqual(WindowSection.transcripts.rawValue, "transcripts", contrat)
        XCTAssertEqual(WindowSection.modes.rawValue, "modes")
        XCTAssertEqual(WindowSection.vocabulary.rawValue, "vocabulary")
        XCTAssertEqual(WindowSection.models.rawValue, "models")
        XCTAssertEqual(WindowSection.general.rawValue, "general")
        XCTAssertEqual(WindowSection.advanced.rawValue, "advanced")
    }

    /// Not `.general`, which is what a settings window would fall back to. Seven of the eight are
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
