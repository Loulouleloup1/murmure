import XCTest
@testable import MurmureCore

/// The menu's words, and the language rule Louis decided on 2026-09-01.
///
/// These strings were literals in `MurmureApp` until this lot. The point of moving them into the
/// package is not tidiness — it is that a test can now **walk all of them at once**, which is the
/// only way "the mix disappeared" is a property rather than something somebody remembers to check.
final class MenuTextTests: XCTestCase {
    /// Every user-facing string Murmure owns, fixed and built alike. `AppAlert`'s two sentences are
    /// here too: they are read in the menu beside the rest, so a rule about the menu's language
    /// that skipped them would be a rule with a hole exactly where the mix used to live.
    private var everySentence: [String] {
        MenuText.allFixedLabels
            + [
                MenuText.activeMode("Voice"),
                MenuText.repasteFailed("the clipboard refused the transcript"),
            ]
            + AppAlert.allCases.map(\.message)
            + AppAlert.allCases.compactMap(\.actionTitle)
    }

    /// **The rule, enforced rather than remembered.** The menu was French in places and English in
    /// others — "Recoller la dernière transcription" directly above "Quit" — and a window adding
    /// six English section names would have made that worse rather than better. Louis chose
    /// English, and the condition was that the mix disappear rather than move.
    ///
    /// Checked against the letters French needs and English does not. It is a heuristic and it is
    /// meant to be: it cannot catch an unaccented French word, but every string that came back
    /// from this codebase's own French did carry one, and a guard that fires on the realistic
    /// regression is worth more than none.
    func testNoUserFacingStringHasSlippedBackIntoFrench() {
        let frenchOnly = CharacterSet(charactersIn: "éèêëàâùûüçîïôöÉÈÊÀÙÇÎÔ")
        for sentence in everySentence {
            XCTAssertNil(
                sentence.rangeOfCharacter(from: frenchOnly),
                "\"\(sentence)\" is not in the language the rest of the interface is in")
        }
    }

    /// A label nobody can read is a menu item that looks like a separator.
    func testEverySentenceSaysSomething() {
        for sentence in everySentence {
            XCTAssertFalse(sentence.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// The two labels that are built rather than fixed have to carry what they were given —
    /// a version that dropped the interpolation would still be a perfectly non-empty string.
    func testTheBuiltLabelsCarryWhatTheyWereGiven() {
        XCTAssertTrue(MenuText.activeMode("Prompt").contains("Prompt"))
        // The reason differs between failures and so does the fix, so the sentence has to name it.
        XCTAssertTrue(MenuText.repasteFailed("no frontmost app").contains("no frontmost app"))
    }

    /// The menu's own line and the standing panel's are the same sentence about the same problem.
    /// Two wordings would be a difference Louis has to learn for nothing — and it is only true
    /// because `MurmureApp` reads them off `AppAlert` instead of writing its own.
    func testTheAccessibilityFixIsOfferedUnderOneWordingOnly() throws {
        let title = try XCTUnwrap(AppAlert.accessibilityDenied.actionTitle)
        XCTAssertFalse(title.isEmpty)
        // A title with no destination is a button that does nothing; a destination with no title
        // is one that says nothing. The menu unwraps them together, so both must exist.
        XCTAssertNotNil(AppAlert.accessibilityDenied.settingsURL)
    }
}
