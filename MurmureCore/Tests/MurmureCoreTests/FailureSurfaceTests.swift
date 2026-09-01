import XCTest
@testable import MurmureCore

/// The dictation Louis just spoke, as it reaches `.failed`'s payload.
private let spoken = "Il faudrait relire la section neuf avant de la publier."

/// A paste failure that kept the text -- what `DictationSession.finishRecording()` emits when
/// `inserter.insert(text)` throws.
private func pasteFailure(_ message: String = "insert failed: accessibility") -> DictationSession
    .State
{
    .failed(message: message, recoveredText: spoken)
}

final class FailureSurfaceTests: XCTestCase {
    // MARK: - The safety property

    /// **The one that matters.** A denied Accessibility is *why* the paste failed, so the two
    /// arrive together on every dictation this task exists for. If the alert took the surface,
    /// the transcript -- which is held nowhere else, and is cleared by the next `.recording` --
    /// would go with it.
    func testAnAlertNeverMasksAFailureCarryingRecoverableText() {
        let problem = FailureSurface.standing(
            state: pasteFailure(), alert: .accessibilityDenied, clipboardWarning: nil)
        XCTAssertEqual(
            problem,
            .recovery(Recovery(message: "insert failed: accessibility", text: spoken,
                               clipboardNote: nil)))
    }

    /// The same, for every alert there is, so a case added later cannot be the one that wins.
    func testNoAlertWhatsoeverMasksARecoverableTranscript() {
        for alert in AppAlert.allCases {
            let problem = FailureSurface.standing(
                state: pasteFailure(), alert: alert, clipboardWarning: nil)
            guard case .recovery = problem else {
                return XCTFail("\(alert) masked a recoverable transcript")
            }
        }
    }

    // MARK: - Precedence between a paste failure and a clipboard loss

    /// The plan's question, and the answer is that it is not a contest: the failure takes the
    /// headline, the clipboard takes the second line, and the panel carries both.
    func testAClipboardLossRidesInsideTheRecoveryInsteadOfCompetingWithIt() {
        let problem = FailureSurface.standing(
            state: pasteFailure(), alert: nil,
            clipboardWarning: "Presse-papiers perdu (1 élément(s) non restaurables)")
        XCTAssertEqual(
            problem,
            .recovery(Recovery(
                message: "insert failed: accessibility", text: spoken,
                clipboardNote: "Presse-papiers perdu (1 élément(s) non restaurables)")))
    }

    /// And with all three at once, which is the worst real dictation: the surface is still the
    /// transcript's, the clipboard is still reported, and the alert still waits.
    func testTheTranscriptWinsTheSurfaceWhileTheClipboardKeepsItsLine() {
        let problem = FailureSurface.standing(
            state: pasteFailure(), alert: .accessibilityDenied,
            clipboardWarning: "Restauration du presse-papiers échouée")
        guard case let .recovery(recovery) = problem else {
            return XCTFail("expected the recovery to win the surface")
        }
        XCTAssertEqual(recovery.text, spoken)
        XCTAssertEqual(recovery.clipboardNote, "Restauration du presse-papiers échouée")
    }

    // MARK: - What is not an offer

    /// A failure with nothing to offer falls through to the alert, which is the useful thing left
    /// to say. `mic start failed`, `no audio captured` and `transcription failed` are all this
    /// case: `DictationSession` passes `recoveredText: nil` on every one of them.
    func testAFailureWithNoTextFallsThroughToTheAlert() {
        let problem = FailureSurface.standing(
            state: .failed(message: "no audio captured", recoveredText: nil),
            alert: .accessibilityDenied, clipboardWarning: nil)
        XCTAssertEqual(problem, .alert(.accessibilityDenied))
    }

    /// Empty is not "some text": a button offering to re-paste nothing is a button that does
    /// nothing, and `PasteInserter` refuses an empty string before it touches the clipboard.
    func testEmptyRecoveredTextIsNotAnOffer() {
        let problem = FailureSurface.standing(
            state: .failed(message: "insert failed", recoveredText: ""),
            alert: .hotkeyUnavailable, clipboardWarning: nil)
        XCTAssertEqual(problem, .alert(.hotkeyUnavailable))
    }

    /// And with nothing standing at all, there is no panel. This is every ordinary dictation.
    func testAWorkingDictationOpensNoPanel() {
        for state: DictationSession.State in [
            .idle, .recording, .transcribing, .refining, .inserting, .completed(insertedCharacters: 47),
        ] {
            XCTAssertNil(
                FailureSurface.standing(state: state, alert: nil, clipboardWarning: nil),
                "\(state) opened a panel")
        }
    }

    /// A clipboard warning on its own does NOT open the clickable panel. It has no button --
    /// nothing Murmure can do gets the contents back -- and it is already in the menu. Opening a
    /// panel that can only be dismissed would train Louis to dismiss the one that carries his
    /// transcript.
    func testAClipboardWarningAloneOpensNoPanel() {
        XCTAssertNil(FailureSurface.standing(
            state: .completed(insertedCharacters: 47), alert: nil,
            clipboardWarning: "Presse-papiers modifié pendant la dictée"))
    }

    /// An alert standing through a running dictation still holds the panel, because that panel is
    /// not the dictation's. This is the case the whole re-check exists for: Accessibility is found
    /// denied at `.recording`, and Louis reads it while he is still speaking rather than after.
    func testAnAlertHoldsThePanelWhileADictationRuns() {
        XCTAssertEqual(
            FailureSurface.standing(
                state: .recording, alert: .accessibilityDenied, clipboardWarning: nil),
            .alert(.accessibilityDenied))
    }

    // MARK: - The transient surface

    /// A dictation's own phase outranks an alert on the notch and the strip. The waveform is the
    /// only thing on screen saying the microphone is live.
    func testADictationPhaseOutranksAnAlertOnTheTransientSurface() {
        for phase: NotchPhase in [
            .recording, .transcribing, .refining, .inserting,
            .completed(insertedCharacters: 47), .nothingHeard,
            .failed(message: "insert failed", recoveredText: spoken),
        ] {
            XCTAssertEqual(
                FailureSurface.transient(dictation: phase, alert: .accessibilityDenied), phase)
        }
    }

    /// And with nothing on screen, the alert is what appears -- which is the whole of how a
    /// launch-time problem is ever seen, since without the hotkey no dictation can start and no
    /// phase can ever arrive.
    func testAnAlertAppearsWhenNoDictationIsOnScreen() {
        XCTAssertEqual(
            FailureSurface.transient(dictation: .hidden, alert: .hotkeyUnavailable),
            .alert(message: AppAlert.hotkeyUnavailable.message))
    }

    func testIdleWithNothingWrongIsNoWindowAtAll() {
        XCTAssertEqual(FailureSurface.transient(dictation: .hidden, alert: nil), .hidden)
    }

    /// The transient alert leaves on its own. It has to: the notch card is a black slab over the
    /// menu bar, and `NotchPresenter.dwell` is what stops one outliving what it is about. The
    /// standing panel is where an alert waits.
    func testTheTransientAlertRetractsOnATimer() {
        XCTAssertEqual(
            NotchPresenter.dwell(for: .alert(message: AppAlert.accessibilityDenied.message)),
            NotchPresenter.failureDwell)
    }

    // MARK: - Dismissal

    func testADismissedProblemStaysOffTheScreen() {
        let alert = StandingProblem.alert(.accessibilityDenied)
        XCTAssertNil(FailureSurface.visible(problem: alert, dismissed: alert))
    }

    /// Dismissing one problem does not dismiss the next. This is the case that would lose a
    /// transcript: Louis waves away an Accessibility alert, dictates, the paste fails, and the
    /// recovery has to open.
    func testDismissingAnAlertDoesNotDismissTheRecoveryThatFollowsIt() {
        let recovery = StandingProblem.recovery(
            Recovery(message: "insert failed", text: spoken, clipboardNote: nil))
        XCTAssertEqual(
            FailureSurface.visible(
                problem: recovery, dismissed: .alert(.accessibilityDenied)),
            recovery)
    }

    /// A second failure carrying a different dictation is a different problem, so the panel opens
    /// again even though the previous one was dismissed.
    func testANewTranscriptReopensTheDismissedPanel() {
        let first = StandingProblem.recovery(
            Recovery(message: "insert failed", text: spoken, clipboardNote: nil))
        let second = StandingProblem.recovery(
            Recovery(message: "insert failed", text: "Autre chose.", clipboardNote: nil))
        XCTAssertEqual(FailureSurface.visible(problem: second, dismissed: first), second)
    }

    /// A clipboard loss that appears on the second attempt is new news, so it reopens the panel
    /// even though the failure and the text are the ones already waved away.
    func testAClipboardLossAppearingLaterReopensTheDismissedPanel() {
        let dismissed = StandingProblem.recovery(
            Recovery(message: "insert failed", text: spoken, clipboardNote: nil))
        let withLoss = StandingProblem.recovery(
            Recovery(message: "insert failed", text: spoken,
                     clipboardNote: "Presse-papiers perdu"))
        XCTAssertEqual(FailureSurface.visible(problem: withLoss, dismissed: dismissed), withLoss)
    }

    func testNothingStandingShowsNothingWhateverWasDismissed() {
        XCTAssertNil(FailureSurface.visible(
            problem: nil, dismissed: .alert(.hotkeyUnavailable)))
    }

    /// The defect this rule exists for: without it, an alert dismissed once is silenced for the
    /// life of the process as soon as anything else has taken the panel -- including the very
    /// recovery it caused.
    func testADismissalLapsesAsSoonAsAnotherProblemTakesThePanel() {
        let alert = StandingProblem.alert(.accessibilityDenied)
        let recovery = StandingProblem.recovery(
            Recovery(message: "insert failed", text: spoken, clipboardNote: nil))
        // Dismissed, then a failed dictation takes the panel...
        let afterRecovery = FailureSurface.dismissal(alert, given: recovery)
        XCTAssertNil(afterRecovery)
        // ...and the alert is news again.
        XCTAssertEqual(
            FailureSurface.visible(problem: alert, dismissed: afterRecovery), alert)
    }

    /// It also lapses on the ordinary state where nothing is wrong, which is every dictation
    /// between the two.
    func testADismissalLapsesWhenTheProblemItselfClears() {
        XCTAssertNil(FailureSurface.dismissal(.alert(.hotkeyUnavailable), given: nil))
    }

    /// And it survives for as long as the same problem is standing, which is what stops the panel
    /// reopening on the next state change that recomputes it.
    func testADismissalSurvivesWhileTheSameProblemStands() {
        let alert = StandingProblem.alert(.accessibilityDenied)
        XCTAssertEqual(FailureSurface.dismissal(alert, given: alert), alert)
        XCTAssertNil(FailureSurface.visible(
            problem: alert, dismissed: FailureSurface.dismissal(alert, given: alert)))
    }

    // MARK: - The panel's own size

    /// A recovery is taller than an alert because it holds a transcript the alert does not have.
    /// The relation is the point; the digits are Louis's.
    func testTheRecoveryPanelIsTallerThanTheAlertByTheTranscriptItHolds() {
        let recovery = StandingPanelLayout.size(
            for: .recovery(Recovery(message: "m", text: spoken, clipboardNote: nil)))
        let alert = StandingPanelLayout.size(for: .alert(.accessibilityDenied))
        XCTAssertEqual(recovery.width, alert.width)
        XCTAssertEqual(
            recovery.height - alert.height,
            StandingPanelLayout.transcriptHeight + StandingPanelLayout.blockSpacing)
    }
}
