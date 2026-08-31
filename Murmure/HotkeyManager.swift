import Carbon.HIToolbox
import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "hotkey")

/// Registers one global hotkey through Carbon's `RegisterEventHotKey`.
///
/// Carbon rather than an `NSEvent` global monitor: it needs no Accessibility permission and it
/// fires while another application is focused, which is the whole point of a dictation shortcut.
/// A global monitor is only required for a bare-modifier trigger (⌥ held down); ruling L4 settled
/// on the ⌥Space chord, so none is installed here.
///
/// `@MainActor` is load-bearing, not decoration. The Carbon handler holds an *unretained* pointer
/// back to this object, invalidated in `deinit` by removing the handler, and `nextID` is mutated
/// without a lock. Both are safe only because every entry point runs on the main thread -- the
/// same thread Carbon dispatches the handler on (the run loop owning the application event
/// target). Isolating the type makes the compiler enforce that instead of a doc comment believing
/// it; the two places that step outside the isolation -- the C callback and `deinit` -- assert it
/// with `MainActor.assumeIsolated`, so a violation traps rather than races.
@MainActor
final class HotkeyManager {
    /// Each manager takes its own id. The handler is installed on the *application* event target,
    /// so it sees every hot key the process registers; filtering on the id stops two managers from
    /// firing each other's callbacks.
    private static var nextID: UInt32 = 1

    private let hotKeyID: EventHotKeyID
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onPress: (() -> Void)?

    init() {
        hotKeyID = EventHotKeyID(signature: OSType(0x4D55_524D), id: Self.nextID) // "MURM"
        Self.nextID += 1
    }

    deinit {
        // `deinit` is nonisolated whatever the type says. Assert the main actor rather than
        // weaken the isolation: the type is non-Sendable and both owners are `@MainActor`, so the
        // last release is on the main thread -- and if that ever stops being true, this traps
        // instead of tearing down Carbon state from under a handler that may be running.
        MainActor.assumeIsolated {
            unregister()
            if self.hotKeyRef != nil || self.eventHandler != nil {
                logger.fault("""
                    hotkey teardown INCOMPLETE at deinit -- \
                    hotkey still registered: \(self.hotKeyRef != nil, privacy: .public), \
                    handler still installed: \(self.eventHandler != nil, privacy: .public); \
                    a surviving handler now points at freed memory
                    """)
            }
        }
    }

    /// Registers `combo`, replacing any previous registration on this manager.
    ///
    /// Returns `false` -- and logs the `OSStatus` -- when the system refuses. Deliberately *not*
    /// `@discardableResult`: dropping the result is the one thing that turns a failed
    /// registration into Louis pressing a dead key forever with no explanation, so it costs a
    /// compiler warning.
    ///
    /// Measured on macOS 26: `eventHotKeyExistsErr` (-9878) is raised only when THIS process
    /// already holds the combination. A clash with another application is not an error at all --
    /// both processes then receive the press -- so `true` means "registered", not "exclusive".
    /// `kEventHotKeyNoOptions` is a measured choice, not an oversight: `kEventHotKeyExclusive`
    /// changes nothing unless the other registrant is *also* exclusive (see the task 4 report,
    /// fix round 1), and would otherwise silently starve another app's shortcut.
    func register(_ combo: KeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister()
        // Only reachable when a previous teardown failed. Registering anyway would overwrite the
        // surviving reference, losing the last handle on state the OS still holds.
        guard hotKeyRef == nil, eventHandler == nil else {
            logger.fault(
                "hotkey registration refused -- the previous teardown failed and is still held")
            return false
        }
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var firedID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &firedID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                // Carbon dispatches on the run loop owning the application event target -- the
                // main one -- but a C callback cannot say so in its signature. Assert it here so
                // the unretained pointer below is touched under the same isolation as `deinit`.
                return MainActor.assumeIsolated {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData)
                        .takeUnretainedValue()
                    guard firedID.signature == manager.hotKeyID.signature,
                        firedID.id == manager.hotKeyID.id
                    else { return OSStatus(eventNotHandledErr) }
                    manager.fire()
                    return noErr
                }
            }, 1, &eventType, selfPtr, &eventHandler)
        guard handlerStatus == noErr else {
            logger.error(
                "hotkey handler install failed -- OSStatus \(handlerStatus, privacy: .public)")
            self.onPress = nil
            return false
        }

        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyNoOptions), &hotKeyRef
        )
        guard status == noErr, hotKeyRef != nil else {
            logger.error("""
                hotkey registration failed -- OSStatus \(status, privacy: .public), \
                keyCode \(combo.keyCode, privacy: .public), \
                modifiers \(combo.carbonModifiers, privacy: .public) \
                (-9878 means this process already holds the combination)
                """)
            // Leave nothing installed: a handler with no hotkey is dead weight holding a pointer.
            unregister()
            return false
        }
        logger.info("""
            hotkey registered -- keyCode \(combo.keyCode, privacy: .public), \
            modifiers \(combo.carbonModifiers, privacy: .public), \
            id \(self.hotKeyID.id, privacy: .public)
            """)
        return true
    }

    /// Releases the hotkey and the handler. Idempotent: safe before any `register`, and safe
    /// twice. The hotkey goes first so no event can reach a handler that is about to disappear.
    ///
    /// A reference is cleared **only** when its OS call succeeded. Clearing it regardless would
    /// turn "the OS may still hold this" into "Swift believes it is clean", and the object could
    /// then be deallocated under a handler that is still installed -- a use-after-free on the next
    /// press. Keeping the reference makes the next `register()` refuse loudly and lets `deinit`
    /// retry; the failure is logged at `.fault`.
    func unregister() {
        // First, so that a handler surviving a failed removal fires nothing.
        onPress = nil
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            if status == noErr {
                self.hotKeyRef = nil
            } else {
                logger.fault("""
                    hotkey unregister FAILED -- OSStatus \(status, privacy: .public); \
                    the combination may still be held by this process
                    """)
            }
        }
        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            if status == noErr {
                self.eventHandler = nil
            } else {
                logger.fault("""
                    handler removal FAILED -- OSStatus \(status, privacy: .public); \
                    the handler is still installed and still points at this object
                    """)
            }
        }
    }

    private func fire() {
        logger.info("hotkey pressed -- id \(self.hotKeyID.id, privacy: .public)")
        onPress?()
    }
}
