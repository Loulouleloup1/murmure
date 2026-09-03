import XCTest
@testable import MurmureCore

/// A fixed instant to count from. `timeIntervalSinceReferenceDate: 0` rather than `Date()` so the
/// boundary tests below compare exact `Double`s: at 0, `+ 0.3` is 0.3 and nothing rounds. On an
/// arbitrary reference date, "exactly at the dwell" would be a coin toss on the last bit.
private let t0 = Date(timeIntervalSinceReferenceDate: 0)

final class NotchPresenterTests: XCTestCase {
    // MARK: - The phase a state change produces

    func testEachRunningStateHasItsOwnPhase() {
        XCTAssertEqual(NotchPresenter.phase(previous: .idle, current: .recording), .recording)
        XCTAssertEqual(
            NotchPresenter.phase(previous: .recording, current: .transcribing), .transcribing)
        // Distinct from `transcribing` all the way down: 19 s at the p-high of the measured
        // refinements against a transcription of seconds.
        XCTAssertEqual(
            NotchPresenter.phase(previous: .transcribing, current: .refining), .refining)
        XCTAssertEqual(
            NotchPresenter.phase(previous: .refining, current: .inserting), .inserting)
    }

    /// The decision the whole lot turns on. A dictation that inserted nothing is not a small
    /// success: `nothingHeard` is its own phase, and a green flash here would tell Louis his
    /// words landed when nothing reached the pasteboard at all.
    func testACompletionThatInsertedNothingIsNothingHeardAndNotAFlash() {
        let phase = NotchPresenter.phase(
            previous: .inserting, current: .completed(insertedCharacters: 0))
        XCTAssertEqual(phase, .nothingHeard)
        XCTAssertNotEqual(phase, .completed(insertedCharacters: 0))
    }

    func testACompletionThatInsertedTextIsTheFlashAndCarriesItsCount() {
        XCTAssertEqual(
            NotchPresenter.phase(previous: .inserting, current: .completed(insertedCharacters: 42)),
            .completed(insertedCharacters: 42))
    }

    /// Spec §9: a dictation is never lost. The text the paste could not deliver has to reach the
    /// surface that offers to paste it again, so it travels in the phase rather than being
    /// dropped at the boundary the way the menu drops it today.
    func testAFailureCarriesItsMessageAndItsRecoveredText() {
        let phase = NotchPresenter.phase(
            previous: .inserting,
            current: .failed(message: "insert failed", recoveredText: "texte précieux"))
        XCTAssertEqual(
            phase, .failed(message: "insert failed", recoveredText: "texte précieux"))
    }

    /// `DictationSession` emits `.completed` and `.idle` in the same breath -- it holds no timer,
    /// by design. A reducer reading only the new state would hide the notch in the instant it was
    /// told the dictation succeeded, and the flash would never be seen.
    func testTheIdleThatFollowsACompletionKeepsItOnScreen() {
        XCTAssertEqual(
            NotchPresenter.phase(previous: .completed(insertedCharacters: 5), current: .idle),
            .completed(insertedCharacters: 5))
    }

    /// And the same for the silence, which must never turn into a flash on its way through idle.
    func testTheIdleThatFollowsANothingHeardKeepsThatAndNeverBecomesAFlash() {
        XCTAssertEqual(
            NotchPresenter.phase(previous: .completed(insertedCharacters: 0), current: .idle),
            .nothingHeard)
    }

    /// A cancellation is the third phase that survives its own `.idle`, and for the reason the
    /// other two do: `DictationSession.cancel()` emits `.cancelled` and `.idle` in the same
    /// breath, so a reducer reading only `current` would retract the notch in the same instant it
    /// was told the dictation had been abandoned -- and Louis, who pressed a key that is silently
    /// consumed, would have nothing at all telling him the press landed.
    func testTheIdleThatFollowsACancellationKeepsItOnScreen() {
        XCTAssertEqual(NotchPresenter.phase(previous: .cancelled, current: .idle), .cancelled)
    }

    /// The state itself, before the `.idle` behind it.
    func testACancelledDictationIsShownRatherThanVanishing() {
        XCTAssertEqual(NotchPresenter.phase(previous: .recording, current: .cancelled), .cancelled)
    }

    /// Every other route to idle is a retraction: the idle the app starts life in, and the one
    /// after a failure. Hidden is no window at all -- idle costs zero pixels (D4).
    ///
    /// `.recording` straight to `.idle` is no longer a route the session can take -- a cancel now
    /// says `.cancelled` on the way through -- and it is kept here as the answer for a pair
    /// nothing draws, which is what this arm is for.
    func testAnyOtherRouteToIdleHidesTheNotch() {
        XCTAssertEqual(NotchPresenter.phase(previous: .recording, current: .idle), .hidden)
        XCTAssertEqual(NotchPresenter.phase(previous: .idle, current: .idle), .hidden)
        XCTAssertEqual(
            NotchPresenter.phase(
                previous: .failed(message: "boom", recoveredText: nil), current: .idle),
            .hidden)
    }

    // MARK: - The elapsed string

    func testElapsedIsMinutesAndPaddedSeconds() {
        XCTAssertEqual(NotchPresenter.elapsed(since: t0, now: t0), "0:00")
        XCTAssertEqual(NotchPresenter.elapsed(since: t0, now: t0.addingTimeInterval(7)), "0:07")
        XCTAssertEqual(NotchPresenter.elapsed(since: t0, now: t0.addingTimeInterval(59)), "0:59")
        XCTAssertEqual(NotchPresenter.elapsed(since: t0, now: t0.addingTimeInterval(65)), "1:05")
        XCTAssertEqual(NotchPresenter.elapsed(since: t0, now: t0.addingTimeInterval(600)), "10:00")
    }

    /// Truncated, never rounded: a counter that shows 0:08 at 7.6 s reads ahead of the wait it is
    /// describing, and the first thing it would do is jump straight from 0:00 to 0:01.
    func testElapsedTruncatesRatherThanRounds() {
        XCTAssertEqual(NotchPresenter.elapsed(since: t0, now: t0.addingTimeInterval(7.9)), "0:07")
    }

    /// A clock that goes backwards -- a time zone change, an NTP correction mid-refinement --
    /// reads 0:00. `-1:03` is a bug on screen; a wait that restarts is merely confusing.
    func testElapsedReadsZeroWhenTheClockGoesBackwards() {
        XCTAssertEqual(NotchPresenter.elapsed(since: t0, now: t0.addingTimeInterval(-63)), "0:00")
    }

    // MARK: - D15, the counter that only appears after 5 s

    func testTheCounterIsHiddenUntilTheFifthSecond() {
        XCTAssertFalse(NotchPresenter.showsElapsedCounter(
            in: .refining, since: t0, now: t0.addingTimeInterval(4.999)))
    }

    func testTheCounterAppearsExactlyAtTheFifthSecond() {
        XCTAssertTrue(NotchPresenter.showsElapsedCounter(
            in: .refining, since: t0, now: t0.addingTimeInterval(5)))
    }

    /// Only a refinement is long enough for a number to be worth reading. A transcription is
    /// seconds and an insertion is one CGEvent round-trip, so a counter there would appear and
    /// vanish; a recording already has the waveform saying the app is listening.
    func testOnlyARefinementEverShowsACounter() {
        let long = t0.addingTimeInterval(30)
        for phase: NotchPhase in [
            .recording, .preparingModel(.downloading(ModelDownload(expectedBytes: 1_638_467_188))),
            .preparingModel(.loading), .transcribing, .inserting, .hidden,
        ] {
            XCTAssertFalse(
                NotchPresenter.showsElapsedCounter(in: phase, since: t0, now: long),
                "\(phase) must not show a counter")
        }
    }

    // MARK: - D16, the 300 ms hover dwell

    /// The pointer crosses the notch on every trip to the menu bar. An expansion on each crossing
    /// would be unbearable, so a crossing is defined as a hover that does not last.
    func testAHoverShorterThanTheDwellDoesNotExpand() {
        XCTAssertFalse(
            NotchPresenter.expandsOnHover(hoverBegan: t0, now: t0.addingTimeInterval(0.299)))
    }

    func testAHoverExpandsExactlyAtTheDwell() {
        XCTAssertTrue(
            NotchPresenter.expandsOnHover(hoverBegan: t0, now: t0.addingTimeInterval(0.3)))
    }

    /// No pointer on the notch, no expansion -- and no dwell on the way out either: a panel that
    /// lingered after the pointer left would cover the menu bar it was on its way to.
    func testNoHoverAtAllNeverExpands() {
        XCTAssertFalse(
            NotchPresenter.expandsOnHover(hoverBegan: nil, now: t0.addingTimeInterval(600)))
    }

    // MARK: - How long a finished dictation stays on screen

    /// The session holds no timer -- it emits `.completed` and `.idle` in the same breath -- so
    /// this is the only thing in Murmure that ever takes a finished dictation off the screen. A
    /// phase that answered nil here would leave a black band with nothing behind it.
    func testEveryPhaseThatEndsADictationRetractsOnATimer() {
        for phase: NotchPhase in [
            .completed(insertedCharacters: 9), .copiedToClipboard(characters: 9), .nothingHeard,
            .cancelled,
            .failed(message: "boom", recoveredText: nil), .alert(message: "revoked"),
        ] {
            XCTAssertNotNil(NotchPresenter.dwell(for: phase), "\(phase) would never leave")
        }
    }

    /// And a running dictation has no dwell at all. It leaves when its next state says so, and a
    /// timer over it would pull the notch out from under a refinement that was merely slow -- 57.5 s
    /// at the worst measured, against dwells of a second or two.
    func testARunningDictationIsNeverRetractedOnATimer() {
        for phase: NotchPhase in [
            .hidden, .recording, .preparingModel(.downloading(ModelDownload(expectedBytes: 1_638_467_188))),
            .preparingModel(.loading), .transcribing, .refining, .inserting,
        ] {
            XCTAssertNil(NotchPresenter.dwell(for: phase), "\(phase) would be cut off mid-dictation")
        }
    }

    /// A green flash only corroborates what Louis can already see under his cursor. A silence is
    /// the only evidence the press was registered at all, because nothing appeared anywhere -- so
    /// it has to outlast the flash. The two durations are arbitrary; this ordering is not.
    func testASilenceOutlastsAFlash() {
        XCTAssertGreaterThan(
            NotchPresenter.dwell(for: .nothingHeard) ?? 0,
            NotchPresenter.dwell(for: .completed(insertedCharacters: 1)) ?? 0)
    }

    /// **A cancellation is the second sole witness, and takes the silence's dwell for the
    /// silence's reason.** Louis pressed Escape and Escape is consumed without a sound, so nothing
    /// anywhere corroborates it: no text appears, no clipboard changes, the recording simply
    /// stops. As with a silence, the surface is the ONLY evidence the press was received, and a
    /// sole witness has to stay longer than a corroborating one.
    ///
    /// Pinned as an equality to the silence rather than as a digit of its own, because the
    /// argument is the same argument and a second arbitrary number would be one more thing to
    /// tune in two places.
    func testACancellationStaysAsLongAsASilence() {
        XCTAssertEqual(
            NotchPresenter.dwell(for: .cancelled), NotchPresenter.dwell(for: .nothingHeard))
        XCTAssertGreaterThan(
            NotchPresenter.dwell(for: .cancelled) ?? 0,
            NotchPresenter.dwell(for: .completed(insertedCharacters: 1)) ?? 0)
    }

    /// **The third sole witness.** Under `PasteBehaviour.copyToClipboardOnly` nothing appears
    /// anywhere on screen -- no text under the cursor, no application touched -- so this sentence
    /// is the only evidence there is that the dictation went where it went. A green flash
    /// corroborates text Louis can already see; this corroborates nothing, so it stays as long as
    /// a silence does.
    ///
    /// Pinned as an equality to the silence rather than as a digit of its own, for the reason the
    /// cancellation's is: the argument is the same argument.
    func testAClipboardDeliveryStaysAsLongAsASilence() {
        XCTAssertEqual(
            NotchPresenter.dwell(for: .copiedToClipboard(characters: 9)),
            NotchPresenter.dwell(for: .nothingHeard))
        XCTAssertGreaterThan(
            NotchPresenter.dwell(for: .copiedToClipboard(characters: 9)) ?? 0,
            NotchPresenter.dwell(for: .completed(insertedCharacters: 1)) ?? 0)
    }

    /// And a failure outlasts both: it carries a sentence to read, where the others carry a colour
    /// to notice.
    func testAFailureOutlastsASilence() {
        XCTAssertGreaterThan(
            NotchPresenter.dwell(for: .failed(message: "boom", recoveredText: nil)) ?? 0,
            NotchPresenter.dwell(for: .nothingHeard) ?? 0)
    }
}
