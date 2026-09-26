import XCTest
@testable import MurmureCore

/// The menu's words, and the language rule Louis decided on 2026-09-01.
///
/// These strings were literals in `MurmureApp` until this lot. The point of moving them into the
/// package is not tidiness — it is that a test can now **walk all of them at once**, which is the
/// only way "the mix disappeared" is a property rather than something somebody remembers to check.
///
/// Lot 9 adds one word to this table — the Transcripts panel's own button — and it is checked here
/// rather than in a pane's test for exactly that reason: a label written in a view is a label the
/// walk below cannot see.
final class MenuTextTests: XCTestCase {
    /// What every lot-9 assertion that is red today carries.
    private let contrat = "contrat lot 9 : non implémenté"

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
    ///
    /// This is also the assertion that catches a **sentinel** label — an empty string declared as
    /// the contract — which is why it carries the lot-9 message: with one empty label in the list
    /// this fails before the language rule ever could.
    func testEverySentenceSaysSomething() {
        for sentence in everySentence {
            XCTAssertFalse(
                sentence.trimmingCharacters(in: .whitespaces).isEmpty,
                "\"\(sentence)\" says nothing to the person reading it — \(contrat)")
        }
    }

    /// The two labels that are built rather than fixed have to carry what they were given —
    /// a version that dropped the interpolation would still be a perfectly non-empty string.
    func testTheBuiltLabelsCarryWhatTheyWereGiven() {
        XCTAssertTrue(MenuText.activeMode("Prompt").contains("Prompt"))
        // The reason differs between failures and so does the fix, so the sentence has to name it.
        XCTAssertTrue(MenuText.repasteFailed("no frontmost app").contains("no frontmost app"))
    }

    /// **Lot 9's one new word, and the R3 decision's whole compensation.** The transcripts live
    /// under `Application Support`, where the Finder never shows them on its own; the panel's
    /// button is the single click that answers "where are my transcripts?". Its wording is frozen
    /// here so the button and the folder cannot drift apart, and it is **walked with the rest**:
    /// a label left out of `allFixedLabels` is a label the language rule above does not cover.
    func testTheTranscriptsRevealLabelIsFrozenAndWalkedWithTheRest() {
        XCTAssertEqual(MenuText.revealTranscriptsFolder, "Reveal Transcripts Folder", contrat)
        XCTAssertFalse(MenuText.revealTranscriptsFolder.isEmpty, contrat)
        XCTAssertTrue(
            MenuText.allFixedLabels.contains(MenuText.revealTranscriptsFolder), contrat)
        // The convention the two buttons that already reveal a folder in this window follow
        // (`RevealTarget.buttonTitle`): "Reveal <Subject> Folder", Title Case, English.
        XCTAssertTrue(MenuText.revealTranscriptsFolder.hasPrefix("Reveal "), contrat)
        XCTAssertTrue(MenuText.revealTranscriptsFolder.hasSuffix(" Folder"), contrat)
    }

    /// A label listed twice would make the walk above shorter than it reads, and the duplicate
    /// would be invisible — which is how a string ends up in the table and not in the rule.
    func testNoFixedLabelIsListedTwice() {
        XCTAssertEqual(
            Set(MenuText.allFixedLabels).count, MenuText.allFixedLabels.count, contrat)
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

    // MARK: - Lot 10 (critère 18, §2.7) : le lancement, la fin, l'échec

    /// What every lot-10 assertion that is red today carries.
    private let contratLot10 = "contrat lot 10 : non implémenté"

    /// **Lot 10's three words, frozen in English and walked with the rest.**
    ///
    /// The launch entry is the plan's own wording (§2.7); the two notifications are the ones
    /// criterion 18 asks for (decision R6), and they are separate sentences because they send
    /// Louis to different places. The three are checked here rather than in the queue's test for
    /// the reason this file exists: a label written in a view — or in `TranscriptNotifier` — is a
    /// label no rule can see.
    ///
    /// Membership in ``MenuText/allFixedLabels`` is part of the contract, not a detail: the walk
    /// above only sees what is in there, so a lot-10 word left out of the list is a word the
    /// language rule does not cover.
    func testTheLot10WordsAreFrozenInEnglishAndWalkedWithTheRest() {
        XCTAssertEqual(MenuText.newTranscription, "New Transcription", contratLot10)
        XCTAssertEqual(MenuText.transcriptionFinished, "Transcription finished", contratLot10)
        XCTAssertEqual(MenuText.transcriptionFailed, "Transcription failed", contratLot10)

        let mots = [
            MenuText.newTranscription, MenuText.transcriptionFinished, MenuText.transcriptionFailed,
        ]
        for mot in mots {
            XCTAssertFalse(
                mot.trimmingCharacters(in: .whitespaces).isEmpty,
                "\"\(mot)\" says nothing to the person reading it — \(contratLot10)")
        }
        for mot in mots {
            XCTAssertTrue(
                MenuText.allFixedLabels.contains(mot),
                "\"\(mot)\" is not walked with the rest, so no rule covers it — \(contratLot10)")
        }
        // English, like every other word of the interface. The rule above is the heuristic that
        // runs over the whole table; these three are checked here so that the red carries the
        // lot-10 message rather than the lot-9 one.
        let frenchOnly = CharacterSet(charactersIn: "éèêëàâùûüçîïôöÉÈÊÀÙÇÎÔ")
        for mot in mots {
            XCTAssertNil(
                mot.rangeOfCharacter(from: frenchOnly),
                "\"\(mot)\" is not in the language the rest of the interface is in — \(contratLot10)")
        }
    }

    /// **The notification says which transcript finished, and Murmure does not touch its title.**
    ///
    /// The body is the transcript's own title: with three links queued (criterion 19), a
    /// notification that only said "finished" would announce an outcome without a subject. The
    /// title is the **user's** text — it can be French, Japanese or empty — which is why this
    /// function is not part of the fixed table above, and why the assertion below uses a title
    /// with an accent without that being a language-rule violation.
    func testTheNotificationBodyCarriesTheTranscriptOwnTitleAndInventsNothing() {
        // The video's title, accents included: Murmure passes it through, it does not rewrite it.
        let titre = "Vidéo de Louis — 38 min"
        XCTAssertEqual(MenuText.notificationBody(titre), titre, contratLot10)
        // A notification about a job is not the job's own title: the body is not the sentence the
        // notification is titled with.
        XCTAssertNotEqual(
            MenuText.notificationBody(titre), MenuText.transcriptionFinished, contratLot10)
        // A transcript with no title gets a notification with no body — never an invented word.
        XCTAssertEqual(
            MenuText.notificationBody(""), "",
            "an untitled transcript must not acquire a word nobody wrote — \(contratLot10)")
    }
}
