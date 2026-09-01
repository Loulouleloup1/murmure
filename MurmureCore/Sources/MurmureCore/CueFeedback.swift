import Foundation

/// The two moments Murmure makes a sound, and nothing else.
///
/// The list is short on purpose. This fires on every single dictation, dozens of times a day,
/// usually into headphones -- so every case added here is a sound Louis cannot switch off by not
/// using a feature. `nothingHeard` and `failed` are deliberately absent: an error chime on a tool
/// used all day is a different decision from a confirmation, and it has not been asked for. The
/// notch and the panel already say those two out loud, in words.
public enum FeedbackCue: Sendable, CaseIterable {
    /// The microphone is live and Louis can start speaking.
    ///
    /// This is the one that matters. Without it he presses ⌥Space and then has to find a small
    /// capsule on an ultrawide display before he dares open his mouth -- the sound removes the
    /// look, which is the whole point of the feature.
    case recordingStarted

    /// Text reached the application under the cursor. Confirms an outcome he can already see,
    /// so it is shorter and quieter than the one above.
    case textInserted
}

/// Whatever actually makes the noise.
///
/// A protocol because the noise itself cannot cross into this package: playing a sound is an
/// `AVAudioEngine` on a real output device, and `Murmure` -- which owns it -- has no test bundle.
/// What CAN cross is every decision about it, which is what `FeedbackPolicy` and `CueFeedback`
/// below are, and they are covered by tests against a spy.
public protocol CuePlaying {
    func play(_ cue: FeedbackCue)
}

/// Which sound a state change earns, if any.
///
/// Written without a `default`, so a state added later cannot quietly inherit an answer. Silence
/// is the safe direction, but "silent because nobody thought about it" and "silent because it was
/// decided" are not the same thing, and only one of them survives the next state being added.
public enum FeedbackPolicy {
    public static func cue(for state: DictationSession.State) -> FeedbackCue? {
        switch state {
        // The recording is live here and not a moment earlier: `DictationSession` reaches this
        // state only after `recorder.start()` has returned without throwing. That ordering is the
        // feature, not an implementation detail -- Louis speaks as soon as he hears the sound, so
        // a cue that fired before the microphone was capturing would cost him the front of every
        // dictation. A microphone that refuses ends in `.failed`, which is silent below, so the
        // sound is never a promise the recorder did not keep.
        case .recording: .recordingStarted

        // Zero characters is the case this distinction exists for. `.completed(0)` is a dictation
        // that ran to its end and pasted NOTHING -- a silence Whisper returned empty, or a
        // recording `SpeechGate` rejected. A confirmation there would tell Louis his words had
        // landed somewhere when they had not, which is worse than saying nothing.
        case .completed(let insertedCharacters): insertedCharacters > 0 ? .textInserted : nil

        // `.idle` is silent even though it arrives immediately after every `.completed`
        // (`DictationSession.complete(insertedCharacters:)` emits both in the same breath). The
        // notch deliberately does the opposite -- `NotchPresenter.phase` KEEPS a completion on
        // screen across its own `.idle`, or it would never be seen at all. A sound has no such
        // problem: it has already been heard. Answering `.idle` the way the notch does would
        // simply play the insertion cue twice.
        case .idle, .transcribing, .refining, .inserting, .failed: nil
        }
    }
}

/// The state changes of one dictation, turned into sounds.
///
/// Thin on purpose, and in this package rather than in `DictationController` for one reason: the
/// line that decides whether a sound happens at all is the line worth a test, and in the app
/// target it could only be verified by listening. Here a spy can assert that a failed dictation
/// makes no start sound -- and, just as importantly, that a successful one makes exactly one.
public final class CueFeedback {
    private let player: any CuePlaying

    public init(player: any CuePlaying) {
        self.player = player
    }

    /// The session changed state. The only entry point, and the same shape as the notch's and the
    /// panel's, so the three surfaces are driven from one place by three identical lines.
    public func apply(_ state: DictationSession.State) {
        guard let cue = FeedbackPolicy.cue(for: state) else { return }
        player.play(cue)
    }
}
