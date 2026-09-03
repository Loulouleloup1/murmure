import XCTest
@testable import MurmureCore

/// One of the two erasures stops to ask, the other does not, and neither can be mistaken for the
/// other by anybody reading the screen.
final class HistoryClearingTests: XCTestCase {
    // MARK: - Which one asks

    func testDeletingTranscriptsAsksAndDeletingRecordingsDoesNot() {
        XCTAssertTrue(HistoryClearing.transcripts.requiresConfirmation)
        XCTAssertFalse(HistoryClearing.recordings.requiresConfirmation)
    }

    /// The two halves of "requires a confirmation" held together. An action that claims a dialog
    /// and cannot produce one is a delete that happens with no warning at all -- and the
    /// `allCases` walk is what makes a third action added later fail here rather than ship silent.
    func testEveryActionThatAsksHasSomethingToAskAndTheOtherHasNothing() {
        for action in HistoryClearing.allCases {
            XCTAssertEqual(
                action.confirmation(dictationCount: 1469) != nil,
                action.requiresConfirmation,
                "\(action)")
        }
    }

    /// The two cannot be confused at the moment of clicking. macOS spells a trailing `…` as "this
    /// opens something before it acts", so the button that acts immediately must not wear one:
    /// its missing ellipsis is the only warning that there is no second chance coming.
    func testOnlyTheActionThatOpensADialogWearsAnEllipsis() {
        XCTAssertTrue(HistoryClearing.transcripts.buttonTitle.hasSuffix("…"))
        XCTAssertFalse(HistoryClearing.recordings.buttonTitle.hasSuffix("…"))
    }

    func testTheTwoButtonsDoNotReadAsTheSameButton() {
        let titles = HistoryClearing.allCases.map(\.buttonTitle)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    // MARK: - What the words say disappears

    /// The rule this whole file exists for: a message that does not name what disappears is a bug.
    /// Both actions have one, including the one with no dialog -- that is the action whose only
    /// chance to explain itself is the line under the button.
    func testBothActionsSayWhatTheyDestroyBeforeTheyAreClicked() {
        XCTAssertTrue(HistoryClearing.recordings.summary.contains("recording"))
        XCTAssertTrue(HistoryClearing.recordings.summary.contains("Transcripts are untouched"))

        XCTAssertTrue(HistoryClearing.transcripts.summary.contains("raw and refined text"))
        // `clearText` is an UPDATE, not a DELETE: the row survives with its date, its duration
        // and its mode. A button called "Delete All Transcripts" reads as though the entries
        // themselves go, so the line under it has to say what actually stays -- before the click,
        // not only inside the dialog.
        XCTAssertTrue(HistoryClearing.transcripts.summary.contains("The rows stay"))
    }

    /// The words have to agree with what the app already does on its own, or one of the two is
    /// lying: `RetentionPurge` deletes audio after 3 days and text after 30, every launch, with
    /// no dialog. Read off the constants rather than typed in, so changing the policy fails here.
    func testEachActionRepeatsTheAutomaticClockItBringsForward() {
        let audioDays = Int(RetentionPurge.audioLifetime / 86_400)
        let textDays = Int(RetentionPurge.textLifetime / 86_400)

        XCTAssertTrue(
            HistoryClearing.recordings.summary.contains("\(audioDays) days"),
            HistoryClearing.recordings.summary)
        XCTAssertTrue(
            HistoryClearing.transcripts.summary.contains("\(textDays) days"),
            HistoryClearing.transcripts.summary)

        let prompt = HistoryClearing.transcripts.confirmation(dictationCount: 1469)
        XCTAssertTrue(prompt?.message.contains("\(textDays) days") == true, prompt?.message ?? "")
    }

    /// What is destroyed, what survives, and that it does not come back -- the three things the
    /// dialog is for. The count is in it because "your transcripts" and "1 469 transcripts" are
    /// not the same warning.
    func testTheConfirmationNamesTheTextTheRowsAndTheCount() throws {
        // When
        let prompt = try XCTUnwrap(HistoryClearing.transcripts.confirmation(dictationCount: 1469))

        // Then
        XCTAssertTrue(prompt.message.contains("1469 dictations"), prompt.message)
        XCTAssertTrue(prompt.message.contains("raw and refined text"), prompt.message)
        XCTAssertTrue(prompt.message.contains("The rows stay"), prompt.message)
        XCTAssertTrue(prompt.message.contains("recordings are untouched"), prompt.message)
        XCTAssertTrue(prompt.message.contains("cannot be undone"), prompt.message)
    }

    /// The last thing read before the click is still the name of what is about to happen, not
    /// "OK" -- and there is a way out that is spelled as a way out.
    func testTheDialogsButtonsNameTheActionAndTheEscape() throws {
        let prompt = try XCTUnwrap(HistoryClearing.transcripts.confirmation(dictationCount: 3))
        XCTAssertEqual(prompt.confirmTitle, "Delete All Transcripts")
        XCTAssertEqual(prompt.cancelTitle, "Cancel")
        // No ellipsis on the button inside the dialog: that one really does act.
        XCTAssertFalse(prompt.confirmTitle.hasSuffix("…"))
    }

    /// "1 dictations" is the kind of thing that makes a warning look machine-written at the exact
    /// moment it needs to be read.
    func testTheCountIsWrittenAsEnglish() throws {
        let one = try XCTUnwrap(HistoryClearing.transcripts.confirmation(dictationCount: 1))
        XCTAssertTrue(one.message.contains("1 dictation,"), one.message)
        XCTAssertFalse(one.message.contains("1 dictations"), one.message)

        let two = try XCTUnwrap(HistoryClearing.transcripts.confirmation(dictationCount: 2))
        XCTAssertTrue(two.message.contains("2 dictations"), two.message)
    }

    /// The dialog is a question. A title that is a statement reads as a report of something that
    /// has already happened, which is the wrong thing to say before asking permission.
    func testTheDialogAsksSomething() throws {
        let prompt = try XCTUnwrap(HistoryClearing.transcripts.confirmation(dictationCount: 3))
        XCTAssertTrue(prompt.title.hasSuffix("?"), prompt.title)
    }
}
