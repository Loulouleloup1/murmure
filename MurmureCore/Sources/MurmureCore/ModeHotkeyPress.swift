import Foundation

/// What pressing a mode's own shortcut does, as a function of the session state it lands in.
///
/// **Lifted out of `DictationController` for the same reason `CancelHotkeyPolicy.isLive(during:)`
/// was.** The mapping from `DictationSession.State` to an action is a decision with one
/// catastrophic wrong answer -- starting a second recording on top of one already running, or
/// silently eating a press that should have stopped one -- and that is worth a type this package
/// tests, rather than a `switch` inline in a closure `Murmure` (no test bundle) never exercises
/// directly.
///
/// Written without a `default`, so a state added later to `DictationSession.State` has to say
/// which action it wants rather than silently inheriting one.
public enum ModeHotkeyPress {
    /// What a press should cause. `DictationController` is the only caller, and it already has a
    /// `DictationSession` to act on -- this type says which of its three responses fits, not how
    /// to invoke them.
    public enum Action: Equatable, Sendable {
        /// A recording is running; the press is this mode's shortcut for the SAME gesture the
        /// global toggle already performs while recording -- stop it.
        case stop
        /// The pipeline is already past recording (transcribing, refining, inserting text) --
        /// exactly like the global toggle, a press here does nothing rather than queuing a second
        /// dictation behind the first.
        case ignore
        /// Nothing is running -- start a new dictation, one-shot-overridden into this mode.
        case startInMode
    }

    public static func action(for state: DictationSession.State) -> Action {
        switch state {
        case .recording:
            .stop

        case .transcribing, .refining, .inserting:
            .ignore

        case .idle, .completed, .copiedToClipboard, .cancelled, .failed:
            .startInMode
        }
    }
}
