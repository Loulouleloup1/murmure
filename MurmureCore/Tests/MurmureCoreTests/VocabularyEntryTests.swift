import XCTest
@testable import MurmureCore

/// `VocabularyEntry`'s own small decisions: which of the two kinds an entry is, and what happens
/// when the pane's two input rows try to write the same term.
final class VocabularyEntryTests: XCTestCase {
    // MARK: - isCorrection

    func testABareTermIsNotACorrection() {
        XCTAssertFalse(VocabularyEntry(term: "Trucost").isCorrection)
    }

    func testATermWithAReplacementIsACorrection() {
        XCTAssertTrue(
            VocabularyEntry(term: "cloud code", replacement: "Claude Code").isCorrection)
    }

    // MARK: - upserting(into:)

    func testUpsertingANewTermAppendsIt() {
        let existing = [VocabularyEntry(term: "Trucost")]
        let updated = VocabularyEntry(term: "WeeFin").upserting(into: existing)

        XCTAssertEqual(updated, [VocabularyEntry(term: "Trucost"), VocabularyEntry(term: "WeeFin")])
    }

    func testUpsertingAnExistingTermReplacesItInPlaceOfAppending() {
        let existing = [VocabularyEntry(term: "Trucost"), VocabularyEntry(term: "WeeFin")]
        let updated = VocabularyEntry(term: "Trucost", replacement: "TruCost")
            .upserting(into: existing)

        XCTAssertEqual(updated.count, 2)
        XCTAssertTrue(updated.contains(VocabularyEntry(term: "Trucost", replacement: "TruCost")))
    }

    func testUpsertingMatchesTheExistingTermCaseInsensitively() {
        let existing = [VocabularyEntry(term: "Trucost")]
        let updated = VocabularyEntry(term: "TRUCOST", replacement: "Trucost")
            .upserting(into: existing)

        XCTAssertEqual(updated, [VocabularyEntry(term: "TRUCOST", replacement: "Trucost")])
    }

    /// The one behaviour a user can hit by accident: typing a bare term into "Words to recognise"
    /// when a correction already exists under that term does not add a second row beside it -- it
    /// replaces the correction, and the replacement is gone. Documented in `VocabularyEntry`'s own
    /// header for why this is the deliberate choice and not a gap.
    func testABareTermTypedOverAnExistingCorrectionReplacesItRatherThanCoexisting() {
        let existing = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        let updated = VocabularyEntry(term: "cloud code").upserting(into: existing)

        XCTAssertEqual(updated, [VocabularyEntry(term: "cloud code")])
    }

    /// The same accident in the other direction: adding a correction for a term that already
    /// exists as a bare word to recognise moves it into Corrections instead of leaving both.
    func testACorrectionTypedOverAnExistingBareTermReplacesItRatherThanCoexisting() {
        let existing = [VocabularyEntry(term: "Trucost")]
        let updated = VocabularyEntry(term: "Trucost", replacement: "TruCost")
            .upserting(into: existing)

        XCTAssertEqual(updated, [VocabularyEntry(term: "Trucost", replacement: "TruCost")])
    }

    // MARK: - isWordAddable(_:) -- the pane's "New word" Add button

    func testABlankWordIsNotAddable() {
        XCTAssertFalse(VocabularyEntry.isWordAddable(""))
    }

    func testAWhitespaceOnlyWordIsNotAddable() {
        XCTAssertFalse(VocabularyEntry.isWordAddable("   "))
    }

    func testARealWordIsAddable() {
        XCTAssertTrue(VocabularyEntry.isWordAddable("Trucost"))
    }

    // MARK: - isCorrectionAddable(term:replacement:) -- the pane's "Should be" Add button

    func testBothFieldsBlankIsNotAddable() {
        XCTAssertFalse(VocabularyEntry.isCorrectionAddable(term: "", replacement: ""))
    }

    /// The rule `commitCorrection` already enforces: an empty "Should be" refuses the whole
    /// correction rather than downgrading it to a bare word, so a term alone is not addable here
    /// even though `isWordAddable(term)` on its own would say yes.
    func testATermWithNoReplacementIsNotAddableAsACorrection() {
        XCTAssertFalse(VocabularyEntry.isCorrectionAddable(term: "cloud code", replacement: "  "))
    }

    func testABlankTermWithARealReplacementIsNotAddable() {
        XCTAssertFalse(VocabularyEntry.isCorrectionAddable(term: "  ", replacement: "Claude Code"))
    }

    func testBothFieldsHoldingRealTextIsAddable() {
        XCTAssertTrue(
            VocabularyEntry.isCorrectionAddable(term: "cloud code", replacement: "Claude Code"))
    }
}
