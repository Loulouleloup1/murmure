import Foundation

/// Everything the notch decides, as pure functions.
///
/// The whole of lot 3's logic lives here for one structural reason: the `Murmure` target has no
/// test bundle and cannot get a useful one (a host-app bundle would prove a SwiftUI view renders,
/// not that a phase is right). So the rule of the split is that the app target holds drawing and
/// AppKit calls, and every decision -- which phase, which string, when a hover counts -- is a
/// function here, over values, with the clock passed in.
///
/// The clock is a parameter and never `Date()` read inside, which is what makes the two policies
/// below testable AT their boundary. A test over a real clock can only assert "after a while",
/// and 4.999 s versus 5.0 s is exactly where a rule like D15 is either implemented or not.
public enum NotchPresenter {
    /// How long the pointer must rest on the notch before it expands (lot 3 D16).
    ///
    /// **Arbitrary, and recorded as arbitrary.** Nothing measured says 300 ms. What is known is
    /// the failure it prevents: the pointer crosses the notch on every trip to the menu bar, and
    /// an expansion on every crossing would be unbearable. Tune by use.
    public static let hoverDwell: TimeInterval = 0.3

    /// How long a phase must last before it starts showing an elapsed counter (lot 3 D15).
    ///
    /// **Arbitrary too.** At the 3.17 s median of a short refinement a number would flash and
    /// vanish; at 57.5 s the only question left is whether the app is alive.
    public static let elapsedCounterDelay: TimeInterval = 5

    /// How long a completion -- green flash or `nothingHeard` -- stays before the notch retracts.
    ///
    /// **Arbitrary.** Long enough to register out of the corner of an eye, short enough that it
    /// is gone by the time the next sentence is typed.
    public static let completionDwell: TimeInterval = 0.9

    /// How long a silence stays before the notch retracts.
    ///
    /// **Longer than `completionDwell`, and that ordering is the decision** -- the 1.6 s itself is
    /// as arbitrary as the 0.9 above. A green flash corroborates evidence Louis already has: his
    /// words are sitting under his cursor, and the notch is only agreeing with them. A silence is
    /// the *only* evidence there is -- nothing appeared anywhere, and if the notch has already
    /// retracted by the time he looks up, the dictation is indistinguishable from a hotkey press
    /// the app never received. A sole witness has to stay longer than a corroborating one.
    public static let nothingHeardDwell: TimeInterval = 1.6

    /// How long a failure stays. Longer than a completion, because it carries a sentence to read
    /// rather than a colour to notice.
    ///
    /// Lot 3 T6 makes the one failure that must NOT retract -- a paste failure holding recovered
    /// text -- persist until dismissed. Everything else is a notice, and a notice that never
    /// leaves is a black band with no dictation behind it.
    public static let failureDwell: TimeInterval = 4

    /// How long this phase stays on screen before the notch retracts, or nil if it does not
    /// retract on a timer.
    ///
    /// Nil is the answer for every phase of a running dictation, and it is not "no dwell": those
    /// leave when their next state says so, and a timer over them would pull the notch out from
    /// under a dictation that was merely slow. The session holds no timer of its own -- by design,
    /// `DictationSession.State.completed` says so -- so this function is the only thing in Murmure
    /// that ever takes a finished dictation off the screen.
    ///
    /// Written without a `default`, so a phase added later cannot quietly inherit "never
    /// retracts", which is the failure that leaves a black band with nothing behind it.
    public static func dwell(for phase: NotchPhase) -> TimeInterval? {
        switch phase {
        case .completed: completionDwell
        // **The cancellation takes the silence's dwell for the silence's reason, and it is pinned
        // as an equality rather than given a digit of its own.** Escape is consumed without a
        // sound and pastes nothing, so this surface is the ONLY evidence the press was received --
        // exactly the position `nothingHeard` argues from. A green flash corroborates text Louis
        // can already see; these two are sole witnesses, and a sole witness has to stay longer.
        case .nothingHeard, .cancelled: nothingHeardDwell
        case .failed, .alert: failureDwell
        // The preparation joins the phases with no timer, and it is the one that would suffer most
        // from inheriting one: a 1.6 GB download is minutes long, and a dwell would retract the
        // only thing on screen explaining the wait and leave exactly the blank Louis read as a
        // crash. It leaves when the model is ready, which is a state change, not a clock.
        case .hidden, .recording, .preparingModel, .transcribing, .refining, .inserting: nil
        }
    }

    /// The phase to show, given what the dictation itself is doing and a model preparation in
    /// flight.
    ///
    /// **The preparation is only ever shown over `transcribing`, and that single rule is what makes
    /// a report that arrives late harmless.** The model can only be fetched or loaded from inside
    /// `Transcriber.transcribe`, which the session calls between emitting `.transcribing` and
    /// emitting whatever comes next -- so `.transcribing` is the only phase during which a
    /// preparation is *true*. Anything else means the report is stale, and the dictation's own
    /// phase is the current fact.
    ///
    /// The case that matters is `.failed`. A download that stalls throws
    /// `WhisperKitEngine.Failure.modelDownloadStalled`, the session turns it into `.failed`, and
    /// that failure has to reach the surface **carrying its own sentence** -- it is the one thing
    /// on screen that will tell Louis his connection died rather than that Murmure is slow. A rule
    /// that let a stale `.downloading` outrank it would replace the explanation with a percentage
    /// frozen at whatever it had reached, which is the original defect wearing the fix's clothes.
    ///
    /// It is also what recovers an out-of-order report. The session's state change and the engine's
    /// first `.loading` reach the main actor by two different routes; if the preparation won the
    /// race it is suppressed here, and the caller composes again on the `.transcribing` that
    /// follows -- so the worst a race can cost is one frame, never a lost state.
    public static func phase(dictation: NotchPhase, preparing: ModelPreparation?) -> NotchPhase {
        guard let preparing, case .transcribing = dictation else { return dictation }
        return .preparingModel(preparing)
    }

    /// Which phase the notch is in, given the state change that just arrived.
    ///
    /// `previous` is not decoration. `DictationSession` emits `.completed` and `.idle` -- and
    /// `.cancelled` and `.idle` -- in the same breath -- the machine holds no timer, by design -- so a reducer reading only `current`
    /// would hide the notch in the same instant it was told the dictation succeeded, and the
    /// completion would never be seen at all. An `.idle` arriving straight after a completion
    /// therefore KEEPS the completion on screen, and how long it stays is the interface's
    /// business (it is what retracts it).
    public static func phase(
        previous: DictationSession.State, current: DictationSession.State
    ) -> NotchPhase {
        switch current {
        case .recording: .recording
        case .cancelled: .cancelled
        case .transcribing: .transcribing
        case .refining: .refining
        case .inserting: .inserting
        // The one place a number becomes a meaning: 0 characters is not a small success. Before
        // this state existed, the success path and the two silences all ended in `.idle`, and a
        // green flash driven by `.idle` would congratulate Louis for a dictation that pasted
        // nothing.
        case .completed(let inserted):
            inserted > 0 ? .completed(insertedCharacters: inserted) : .nothingHeard
        case .failed(let message, let recoveredText):
            .failed(message: message, recoveredText: recoveredText)
        case .idle:
            // Only a completion survives its own `.idle`. Every other route to idle -- a cancel,
            // a launch, a state nobody drew -- means there is nothing to show.
            switch previous {
            case .completed(let inserted):
                inserted > 0 ? .completed(insertedCharacters: inserted) : .nothingHeard
            // The third phase that survives its own `.idle`, and it joined the list the moment the
            // cancel stopped going straight to idle: `cancel()` emits `.cancelled` and `.idle` in
            // the same breath, so a reducer reading only `current` would retract the notch in the
            // same instant it was told the dictation had been abandoned.
            case .cancelled:
                .cancelled
            default:
                .hidden
            }
        }
    }

    /// `m:ss`, the length of the thing being waited for.
    ///
    /// `since` is whichever instant the caller is timing -- the start of the dictation for the
    /// hover panel, the start of the current phase for the counter below. The presenter does not
    /// choose, because the two answers are both right in their own place.
    ///
    /// A clock that has gone backwards (a manual time change, an NTP correction) reads 0:00
    /// rather than a negative count: seeing the wait restart is confusing, seeing `-1:03` is
    /// broken.
    public static func elapsed(since: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(since)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Whether a counter belongs on screen yet (lot 3 D15).
    ///
    /// Only `refining` ever shows one. `transcribing` is seconds and `inserting` is one CGEvent
    /// round-trip, so a counter there would be a number nobody has time to read; `recording` is
    /// the waveform's job -- it is already saying the app is listening, and better than a digit
    /// could.
    public static func showsElapsedCounter(in phase: NotchPhase, since: Date, now: Date) -> Bool {
        guard case .refining = phase else { return false }
        return now.timeIntervalSince(since) >= elapsedCounterDelay
    }

    /// Whether a hover has lasted long enough to expand the notch (lot 3 D16).
    ///
    /// `hoverBegan` is nil when the pointer is not on the notch, which is its own answer: leaving
    /// collapses it immediately. There is no symmetric dwell on the way out -- a panel that
    /// lingered after the pointer left would cover the menu bar for no reason.
    public static func expandsOnHover(hoverBegan: Date?, now: Date) -> Bool {
        guard let hoverBegan else { return false }
        return now.timeIntervalSince(hoverBegan) >= hoverDwell
    }
}
