import AppKit
import XCTest
@testable import MurmureCore

/// The five things Murmure says about a clipboard it borrowed, and the one branch among them that
/// has already been wrong once.
final class ClipboardWarningTests: XCTestCase {
    private func message(_ outcome: PasteboardSnapshot.RestoreOutcome) -> String? {
        ClipboardWarning.message(for: outcome)
    }

    /// Nil is not "no message yet" — it is what takes the previous dictation's warning off the
    /// screen. A string here would leave a standing notice about a clipboard that is fine.
    func testAnIntactClipboardSaysNothingAtAll() {
        XCTAssertNil(message(.restored))
    }

    /// **The branch that was wrong.** Every item came back, amputated: an eager `.string` kept and
    /// its unfulfilled `.rtf` promise gone for good. It arrives with `lostItems == 0`, and the
    /// first version of this rule read that as `.restored` and cleared the warning at the exact
    /// moment content had been destroyed.
    func testAnItemThatCameBackWithoutSomeOfItsFormatsStillWarns() throws {
        let warning = try XCTUnwrap(message(.restoredPartially(
            lostItems: 0, capturedItems: 1, lostTypes: [.rtf, .html])))

        XCTAssertTrue(warning.contains("2"), "it has to say how much was lost: \(warning)")
    }

    /// Everything he had copied was promise-only and is now unrecoverable. This reads to him
    /// exactly like a failed write and has to be as loud — in particular it must NOT be the
    /// "partly restored" sentence, because nothing was.
    func testAClipboardThatIsEntirelyGoneDoesNotSayItWasPartlyRestored() throws {
        let warning = try XCTUnwrap(message(.restoredPartially(
            lostItems: 3, capturedItems: 3, lostTypes: [.string])))

        XCTAssertFalse(warning.lowercased().contains("partly"), warning)
        XCTAssertTrue(warning.contains("3"))
    }

    /// The genuinely partial case, and the one the two above must not be confused with. It names
    /// both numbers, because "some of it is gone" is not actionable and "1 of 4" is.
    func testAPartialLossNamesWhatSurvivedAsWellAsWhatDidNot() throws {
        let warning = try XCTUnwrap(message(.restoredPartially(
            lostItems: 1, capturedItems: 4, lostTypes: [.string])))

        XCTAssertTrue(warning.contains("1"), warning)
        XCTAssertTrue(warning.contains("4"), warning)
    }

    /// Measured cross-process: the third party's newer copy is in place and wins, our write was
    /// refused, and the pre-dictation contents are deliberately not restored over it. It is not a
    /// failure and must not read as one — nothing was lost, it was declined.
    func testAClipboardSomebodyElseChangedIsReportedAsDeclinedRatherThanFailed() throws {
        let warning = try XCTUnwrap(message(.declinedPasteboardChanged))

        XCTAssertTrue(warning.lowercased().contains("changed"), warning)
    }

    func testAFailedWriteSaysSo() {
        XCTAssertNotNil(message(.writeFailed))
    }

    /// Four of the five outcomes produce a sentence and they must all be different sentences: two
    /// outcomes sharing a wording is two different things Louis cannot tell apart, which is the
    /// whole argument `RestoreOutcome` exists for in the first place.
    func testTheOutcomesThatWarnAllSayDifferentThings() {
        let warnings = [
            message(.restoredPartially(lostItems: 0, capturedItems: 2, lostTypes: [.rtf])),
            message(.restoredPartially(lostItems: 2, capturedItems: 2, lostTypes: [.rtf])),
            message(.restoredPartially(lostItems: 1, capturedItems: 3, lostTypes: [.rtf])),
            message(.declinedPasteboardChanged),
            message(.writeFailed),
        ].compactMap(\.self)

        XCTAssertEqual(warnings.count, 5, "every warning path must produce a sentence")
        XCTAssertEqual(Set(warnings).count, 5, "two outcomes share a wording")
    }
}
