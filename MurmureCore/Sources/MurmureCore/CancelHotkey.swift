import Foundation

/// Whatever holds the global Escape registration.
///
/// A protocol because the registration itself cannot cross into this package: it is Carbon's
/// `RegisterEventHotKey`, and `Murmure` -- which owns it -- has no test bundle. What CAN cross is
/// every decision ABOUT it, which is `CancelHotkeyPolicy` and `CancelHotkey` below, and that is
/// where the bug would be: the Carbon call is a dozen lines that either work or return an
/// `OSStatus`, while *when the key is held* is a rule with one catastrophic wrong answer.
///
/// **Register, and not "add a monitor".** `NSEvent.addGlobalMonitorForEvents` does not consume the
/// event, so Escape would reach Murmure *and* whatever Louis has focused -- pressing it in Claude
/// Code would cancel a dictation and interrupt Claude at the same time. Only a registered hot key
/// takes the press exclusively, which is also precisely why it must be given back.
public protocol CancelKeyRegistering {
    /// Takes Escape from every other application, for as long as it is held.
    ///
    /// Returns whether the system accepted it. `CancelHotkey` deliberately ignores the answer --
    /// see the fail-safe note there -- so an implementation that can be refused has to SAY so
    /// itself, in a log, rather than relying on this being read.
    func registerCancelKey() -> Bool

    /// Gives it back. Must be idempotent, and must be safe when nothing was ever registered.
    func releaseCancelKey()
}

/// When Escape belongs to Murmure.
///
/// **One state, and the reason the answer has to be this narrow is the failure it prevents.** A
/// registered hot key is taken from *every application on the machine*, so an Escape that outlives
/// its recording is Escape silently ceasing to work across the whole of macOS -- no error, no
/// dialog, and nothing a user would ever connect to a dictation app. The registration therefore
/// exists for exactly as long as there is a recording to abandon, and this function is the whole
/// of that claim.
///
/// Written without a `default`, so a state added later has to say whether it holds Escape rather
/// than inheriting an answer. Silence is the safe direction here as it is in `FeedbackPolicy`, but
/// "not held because somebody decided" and "not held because nobody looked" are not the same
/// thing, and only one of them survives the next state being added.
public enum CancelHotkeyPolicy {
    public static func isLive(during state: DictationSession.State) -> Bool {
        switch state {
        // The one state with something to abandon: the microphone is live and nothing downstream
        // has run.
        case .recording: true

        // **The pipeline deliberately does NOT hold it, and this is the decision of the task.**
        // Three reasons, in order of weight. The audio has already been captured and the text
        // exists or is seconds away, so spec §9's rule applies -- a dictation is never lost -- and
        // there is nothing left to abandon that is not simply text Louis can delete. `Transcriber`
        // and `TextInserter` have no cancellation seam at all: WhisperKit and Ollama are in
        // flight, so a "cancel" here could stop the *display* and would still paste. And a
        // refinement runs 19 s at the p-high of the measured calls and 57.5 s at the worst, so
        // holding Escape across it would take the key from whatever Louis reads while he waits --
        // for a full minute, to cancel work that is already done.
        case .transcribing, .refining, .inserting: false

        // Nothing is running. `.cancelled` in particular is the state the cancel itself produces,
        // so answering `true` here would re-take the key on the way out of taking it.
        case .idle, .completed, .copiedToClipboard, .cancelled, .failed: false
        }
    }
}

/// The one owner of the Escape registration, and its whole lifetime.
///
/// **The point of this type is that "unregister" is not a call anybody has to remember.** Cancel
/// could have been wired by registering in the code that starts a recording and unregistering in
/// each of the seven places one can end -- the ordinary stop, the cancel itself, an empty
/// recording, a recording that never reached the disk, an unreadable one, a transcription that
/// threw, a paste that was refused -- and a single one of those forgotten is Escape broken across
/// the Mac until Murmure is quit. Instead the registration is a **function of the session's
/// state**: `apply` is called on every state change, exactly where `CueFeedback.apply` and the two
/// surfaces already are, and the key is held if and only if `CancelHotkeyPolicy.isLive` says so.
/// Forgetting a path is not possible, because there is no path -- there is one line, and every
/// exit from `.recording` is a state change by construction.
///
/// Idempotent in both directions. An actor is re-entrant and nothing promises the state stream is
/// free of repeats, so a second `.recording` must not take the key twice -- Carbon would refuse
/// the second registration with `eventHotKeyExistsErr` and leave the first held by a handle
/// nothing points at any more.
///
/// **A registration the system refused is still considered held**, which is the fail-safe
/// direction: releasing what nobody holds is one no-op call, while believing a refusal means
/// nothing needs releasing is exactly how the key leaks.
///
/// **`stamp` and `apply` are two entry points because the ordering guarantee is only true at one
/// of them, and this is the part that must not be deleted as ceremony.** The state changes are
/// emitted inside `DictationSession`'s actor, in order, and then each one is hopped onto the main
/// actor by its own `Task { @MainActor in ... }` -- and separate unstructured tasks carry NO
/// ordering guarantee. Whether they happen to run in order today is a property of the runtime,
/// not something any test can pin.
///
/// The other three consumers of that stream can live with it: a mis-ordered delivery costs the
/// notch, the panel or the cue a wrong frame, and the next state corrects it. This one cannot.
/// `.recording` is the only state that TAKES the key and every other state releases, so a
/// `.recording` overtaking the `.idle` that ended its dictation would register Escape *after* the
/// last release had already run -- and nothing would ever release it again. Escape would be held
/// across the whole of macOS, indefinitely, with no error, nothing on screen, and no way for
/// anyone to connect a dead Escape key to a dictation app.
///
/// So the order is not assumed, it is carried. `stamp` is called where the session EMITS --
/// synchronously, inside the actor, before any hop -- and is therefore ordered by construction.
/// `apply` runs after the hop, in whatever order the runtime chose, and drops any change whose
/// stamp is not strictly newer than the last one acted on. **Strictly**: the same change delivered
/// twice is the same information twice, and re-taking a held key is refused by Carbon with
/// `eventHotKeyExistsErr`, which would leave the first registration held by a handle nothing
/// points at. Dropping is safe in the one direction that matters -- the worst a lost race can cost
/// is a dictation that cannot be cancelled, never a key that cannot be released.
///
/// `@unchecked Sendable` over a lock, and the lock is what the two entry points need rather than a
/// nicety: `stamp` is called on the session's executor and `apply` on the main actor, where the
/// registration itself has to happen (`HotkeyManager` is `@MainActor`, because Carbon dispatches
/// its handler on the main run loop). The Carbon calls are made outside the lock.
///
/// What `unchecked` is asserting about the `key`, since the compiler is being asked to take it on
/// trust: it is touched from `apply` and from nowhere else -- `stamp`, the one method that runs on
/// another executor, never reads it -- so it is confined to whichever context `apply` is called
/// from. In the app that is the main actor, which is what lets `EscapeCancelKey` assert its own
/// isolation; in the tests it is a double that requires none, which is the seam's whole purpose.
public final class CancelHotkey: @unchecked Sendable {
    private let key: any CancelKeyRegistering
    private let lock = NSLock()

    /// Whether the key has been ASKED for and not yet given back -- which is not quite the same as
    /// whether the OS granted it, see the note above.
    private var isHeld = false

    /// The stamp handed to the next change, and the highest one already acted on.
    private var nextSequence: UInt64 = 0
    private var highestApplied: UInt64 = 0

    public init(key: any CancelKeyRegistering) {
        self.key = key
    }

    /// Stamp a change with its place in the stream, at the moment the session emits it.
    ///
    /// **Called synchronously from `onStateChange`, before the hop onto the main actor**, which is
    /// the only place the order is known to be true. Stamping after the hop would record the order
    /// the runtime happened to choose, which is the thing being guarded against.
    public func stamp(_ state: DictationSession.State) -> SequencedState {
        lock.lock()
        defer { lock.unlock() }
        nextSequence += 1
        return SequencedState(state: state, sequence: nextSequence)
    }

    /// The session changed state. The only entry point that acts, and the same shape as
    /// `CueFeedback.apply`, so the surfaces and the key are driven from one place.
    ///
    /// Silently drops anything older than what it has already acted on -- see the type's note.
    public func apply(_ change: SequencedState) {
        let shouldHold = CancelHotkeyPolicy.isLive(during: change.state)

        lock.lock()
        // Strictly greater: this change has to be NEWER than the last one acted on, not merely
        // not-older. A stale delivery leaves `highestApplied` where it is, so the changes still
        // in flight behind it are unaffected.
        let isNews = change.sequence > highestApplied
        let act = isNews && shouldHold != isHeld
        if isNews {
            highestApplied = change.sequence
            if act { isHeld = shouldHold }
        }
        lock.unlock()

        guard act else { return }
        if shouldHold {
            // Discarded on purpose: whatever the system answers, the release obligation is the
            // same. `isHeld` is set above rather than from this result for exactly that reason.
            _ = key.registerCancelKey()
        } else {
            key.releaseCancelKey()
        }
    }
}

/// A state change and its position in the stream the session emitted it into.
///
/// The sequence is an envelope and never a decision: what a state MEANS is `CancelHotkeyPolicy`'s
/// alone, and all this carries is *when it was said*. Only `CancelHotkey.stamp` mints one, so a
/// number cannot be invented at a call site and used to jump the queue.
public struct SequencedState: Sendable, Equatable {
    public let state: DictationSession.State
    public let sequence: UInt64
}
