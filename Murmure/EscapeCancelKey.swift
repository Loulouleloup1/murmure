import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "hotkey")

/// Escape, held only while a recording is running. The Carbon half of `CancelHotkey`.
///
/// **A second `HotkeyManager` instance, and not a second mechanism.** That class was written to be
/// one of several: its `nextID` is static, its handler goes on the *application* event target so
/// it sees every hot key the process registers, and it filters on the id precisely "so two
/// managers do not fire each other's callbacks". Nothing about it had to change to hold two
/// registrations at once, and the alternative -- teaching one manager two combinations -- would
/// have doubled every field it owns for the sake of one caller.
///
/// **`register`/`unregister` are called on Louis's behalf dozens of times a day, and that is the
/// whole risk of this file.** A globally registered Escape is taken from every application on the
/// Mac, so one that outlives its recording is Escape silently ceasing to work everywhere, with no
/// error and nothing anyone would trace back to a dictation app. Nothing here decides when that
/// happens: `CancelHotkey` does, from the session's state, in `MurmureCore` where it is tested.
/// This file is the two calls it drives, and it holds no policy at all.
///
/// **Not `@MainActor` on the type, and the two entry points assert the isolation instead.**
/// `CancelKeyRegistering` is declared in `MurmureCore`, where the main actor means nothing -- the
/// test double needs no isolation at all, which is the point of the seam -- so an isolated
/// conformance to a non-isolated protocol is exactly the "crosses into main actor-isolated code"
/// the compiler refuses in the Swift 6 language mode. `MainActor.assumeIsolated` is what
/// `HotkeyManager` itself already does at its two boundaries, its C callback and its `deinit`, and
/// for the same reason: a violation traps rather than races.
///
/// The assertion is true by construction. Both calls are made from `CancelHotkey.apply`, which the
/// app reaches only from inside a `Task { @MainActor in ... }`; `CancelHotkey.stamp`, which runs
/// on the session's executor, never touches this object.
final class EscapeCancelKey: CancelKeyRegistering {
    private let manager: HotkeyManager

    /// What a press does. A `var` because it is the one thing here that cannot be known at
    /// construction: it needs the `DictationSession`, and the session's own initialiser is what
    /// takes the state-change closure this object is driven from. `DictationController` sets it on
    /// the line after the session exists.
    ///
    /// Registering without one would be the worst outcome available: Escape taken from Louis's
    /// terminal for the length of every dictation, doing nothing. So a missing handler REFUSES the
    /// registration and says so at `.fault`, rather than quietly swallowing the key.
    var onPress: (() -> Void)?

    @MainActor
    init() {
        manager = HotkeyManager()
    }

    func registerCancelKey() -> Bool {
        MainActor.assumeIsolated {
            guard let onPress else {
                logger.fault("""
                    Escape registration refused -- no handler was installed; \
                    registering would take the key from every application and do nothing with it
                    """)
                return false
            }
            return manager.register(.cancelRecording, onPress: onPress)
        }
    }

    func releaseCancelKey() {
        MainActor.assumeIsolated { manager.unregister() }
    }
}
