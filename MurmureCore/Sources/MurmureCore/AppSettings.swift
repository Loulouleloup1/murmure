import Foundation

/// What Murmure does with a finished transcript.
///
/// Two cases and not three: **simulating keypresses is not a third paste behaviour**, it is how
/// the first one is carried out in an application that refuses ⌘V (spec §5, `Mode`'s own
/// `simulateKeypresses`). Folding it in here would make "copy to clipboard" and "type it out"
/// look like siblings when only one of them ever touches another application.
///
/// The raw values are storage names -- see ``AppSettings`` -- so they are never renamed lightly.
public enum PasteBehaviour: String, CaseIterable, Sendable {
    /// Put the text on the clipboard, press ⌘V into whatever is in front, hand the clipboard back.
    /// What `PasteInserter` does today and the reason the app exists.
    case pasteIntoFrontmostApp

    /// Leave the text on the clipboard and paste nothing.
    ///
    /// Not a degraded mode: it is the honest answer for the applications where a synthetic ⌘V
    /// lands in the wrong field, and it is the only behaviour that needs no Accessibility
    /// permission at all -- `AppAlert.accessibilityDenied` stops mattering.
    case copyToClipboardOnly
}

/// Everything the General and Advanced panes read and write (plan T8), and nothing else.
///
/// **`UserDefaults`, injected, for `ModePreference`'s two reasons**: none of this is content --
/// losing it costs a few clicks, never a dictation or a mode file -- and a store that reached
/// `.standard` would write into the preferences domain of the application Louis is running.
/// Plan §4.6 says this out loud: settings belong in `UserDefaults`, the vocabulary and the modes
/// belong in files, and the two must not get the same home.
///
/// **Every key below is a storage name and is never renamed lightly**, the rule
/// `ModePreference.storageKey` carries: a rename does not migrate a setting, it silently forgets
/// it, and the user's answer reverts to the default with nothing said anywhere.
///
/// **An empty domain reads as the defaults, and the defaults are what the app does today.**
/// That is why the booleans do not go through `defaults.bool(forKey:)` alone: it answers `false`
/// for a key that was never written, which would ship the two sound cues off on a fresh install
/// and turn the clipboard restore -- the thing that keeps Louis's clipboard from being eaten by
/// every dictation -- into an opt-in.
public struct AppSettings {
    /// The storage names, in one place so that the "never renamed lightly" rule has somewhere to
    /// be read. They are the names `defaults read com.louiscourcier.Murmure` prints, which is the
    /// other reason they are spelled out rather than derived from a case name.
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let soundOnRecordingStarted = "soundOnRecordingStarted"
        static let soundOnTextInserted = "soundOnTextInserted"
        static let pasteBehaviour = "pasteBehaviour"
        static let restoreClipboardAfterPaste = "restoreClipboardAfterPaste"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - General

    // There is deliberately no stored microphone here, and it is a correction rather than an
    // omission. `AudioRecorder` opens `engine.inputNode` and nothing else -- there is no
    // `AudioDeviceID` anywhere in the app -- so a stored choice would be written, read back
    // correctly, tick a row, and leave every dictation recording from the system input anyway.
    // Louis decided on 2026-09-03 that the General pane REPORTS the device instead of offering
    // it (`MicrophoneStatus`), and a setting kept behind a row that no longer sets anything is
    // the same lie one layer down. It comes back the day something reads it.

    /// Whether Murmure starts itself when Louis logs in.
    ///
    /// **`UserDefaults` holds the intent; `SMAppService.mainApp` holds the truth.** The two can
    /// disagree, because System Settings › General › Login Items can turn the registration off
    /// without this app running. The app layer is the one that can reconcile them -- it is the
    /// only side that can call `SMAppService` -- and the rule it must apply is that the service
    /// wins on read: the toggle should show what macOS is actually doing, and this value is
    /// written after a `register()`/`unregister()` has succeeded, never before.
    ///
    /// Default `false`. An app that adds itself to the login items of a machine without being
    /// asked is a bad citizen, and Murmure is not one: this is a hotkey daemon, and Louis
    /// deciding it should always be there is a decision worth one click.
    public var launchAtLogin: Bool {
        get { bool(Key.launchAtLogin, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// Whether a given cue is allowed to make a noise.
    ///
    /// Keyed on ``FeedbackCue`` rather than on two invented booleans: lot 3 T11 already decided
    /// what the sounds ARE and why there are exactly two of them, and a settings model that
    /// re-listed them under new names would be a second vocabulary for one thing -- with nothing
    /// making the two lists agree the day a third cue is added.
    ///
    /// Both default to ON, which is how T11 shipped. The start cue in particular is the whole
    /// point of that task: without it Louis has to go find a 260 pt capsule on a 3440 pt display
    /// before he dares open his mouth, and defaulting it off would ship the bug the feature was
    /// written to remove.
    public func isSoundEnabled(_ cue: FeedbackCue) -> Bool {
        bool(Self.soundKey(for: cue), default: true)
    }

    public func setSoundEnabled(_ isEnabled: Bool, for cue: FeedbackCue) {
        defaults.set(isEnabled, forKey: Self.soundKey(for: cue))
    }

    /// Written without a `default` so a cue added later fails to compile here rather than
    /// silently sharing another cue's key -- which would make one toggle switch two sounds, the
    /// kind of bug nobody reports because it looks like the toggle working.
    private static func soundKey(for cue: FeedbackCue) -> String {
        switch cue {
        case .recordingStarted: Key.soundOnRecordingStarted
        case .textInserted: Key.soundOnTextInserted
        }
    }

    // MARK: - Advanced

    /// What happens to a finished transcript. Defaults to pasting, which is what the app does
    /// today and the behaviour every other part of it is written around.
    ///
    /// An unrecognised stored value reads as the default rather than as nothing -- reachable by a
    /// hand-run `defaults write`, and, the real one, by a case renamed in a later lot. Refusing
    /// would mean an app that inserts nowhere; degrading means an app that pastes, which is where
    /// it started.
    public var pasteBehaviour: PasteBehaviour {
        get {
            guard let stored = defaults.string(forKey: Key.pasteBehaviour),
                  let behaviour = PasteBehaviour(rawValue: stored)
            else { return .pasteIntoFrontmostApp }
            return behaviour
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.pasteBehaviour)
        }
    }

    /// Whether the clipboard Louis had before a paste is handed back to him afterwards.
    ///
    /// Default `true`: `PasteInserter` borrows the clipboard rather than taking it, and that is
    /// not politeness -- a dictation every few minutes that ate the clipboard each time would
    /// make the app unusable next to any copy-and-paste work.
    ///
    /// Turning it OFF is a real request and not a degradation: it leaves the transcript on the
    /// clipboard, which is what someone who wants to paste it a second time, somewhere else,
    /// actually wants.
    public var restoreClipboardAfterPaste: Bool {
        get { bool(Key.restoreClipboardAfterPaste, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.restoreClipboardAfterPaste) }
    }

    // There is deliberately no `simulateKeypresses` row here, and it is not an omission. `Mode`
    // has carried the field since lot 2 and spec §6 asks for a global one, but **nothing types
    // anything out**: `PasteInserter.insert` posts ⌘V unconditionally, so both flags are read by
    // nobody at the moment of acting. Louis decided on 2026-09-03 that the switch comes off the
    // screens until the keystroke path is actually written -- a control in front of a feature
    // that does not exist is worse than a missing control, because it reports success. The JSON
    // field stays where it is, so no mode file on disk is invalidated, and an accessor here would
    // be the same dead control one layer down.

    // MARK: - Derived

    /// Whether the clipboard will actually be handed back after this dictation.
    ///
    /// ``restoreClipboardAfterPaste`` is what the toggle says; this is what happens, and the two
    /// differ in exactly one place: under ``PasteBehaviour/copyToClipboardOnly`` the transcript on
    /// the clipboard **is** the delivery, so restoring would erase the only copy of the dictation
    /// a moment after producing it. The toggle is not overridden quietly -- it is scoped, and the
    /// Advanced pane should disable the row rather than let it read as a promise it cannot keep.
    ///
    /// Written without a `default` so a third paste behaviour has to answer this question.
    public var willRestoreClipboard: Bool {
        switch pasteBehaviour {
        case .pasteIntoFrontmostApp: restoreClipboardAfterPaste
        case .copyToClipboardOnly: false
        }
    }

    // MARK: - Reading

    /// A boolean with a default that is not `false`.
    ///
    /// `defaults.bool(forKey:)` cannot express one: it answers `false` for a key nobody has
    /// written, so "off" and "never asked" are the same value. The presence of the object is the
    /// only thing that tells them apart.
    private func bool(_ key: String, default fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
