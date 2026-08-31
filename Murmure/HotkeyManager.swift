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
/// Main thread only. The Carbon handler holds an *unretained* pointer back to this object and
/// that pointer is invalidated in `deinit` by removing the handler. Carbon dispatches on the run
/// loop that owns the application event target -- the main one -- so a handler call and `deinit`
/// can never overlap as long as the manager is created and released on the main thread. Releasing
/// one from another thread would reintroduce a use-after-free.
final class HotkeyManager {
    /// Each manager takes its own id. The handler is installed on the *application* event target,
    /// so it sees every hot key the process registers; filtering on the id stops two managers from
    /// firing each other's callbacks.
    nonisolated(unsafe) private static var nextID: UInt32 = 1

    private let hotKeyID: EventHotKeyID
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onPress: (() -> Void)?

    init() {
        hotKeyID = EventHotKeyID(signature: OSType(0x4D55_524D), id: Self.nextID) // "MURM"
        Self.nextID += 1
    }

    deinit { unregister() }

    /// Registers `combo`, replacing any previous registration on this manager.
    ///
    /// Returns `false` -- and logs the `OSStatus` -- when the system refuses. The caller must not
    /// assume the key works: a swallowed failure means pressing it does nothing, forever, with no
    /// explanation.
    ///
    /// Measured on macOS 26: `eventHotKeyExistsErr` (-9878) is raised only when THIS process
    /// already holds the combination. A clash with another application is not an error at all --
    /// both processes then receive the press -- so `true` means "registered", not "exclusive".
    @discardableResult
    func register(_ combo: KeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister()
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
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard status == noErr,
                    firedID.signature == manager.hotKeyID.signature,
                    firedID.id == manager.hotKeyID.id
                else { return OSStatus(eventNotHandledErr) }
                manager.fire()
                return noErr
            }, 1, &eventType, selfPtr, &eventHandler)
        guard handlerStatus == noErr else {
            logger.error(
                "hotkey handler install failed -- OSStatus \(handlerStatus, privacy: .public)")
            self.onPress = nil
            return false
        }

        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
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
    func unregister() {
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            if status != noErr {
                logger.error("hotkey unregister failed -- OSStatus \(status, privacy: .public)")
            }
            self.hotKeyRef = nil
        }
        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            if status != noErr {
                logger.error("handler removal failed -- OSStatus \(status, privacy: .public)")
            }
            self.eventHandler = nil
        }
        onPress = nil
    }

    private func fire() {
        logger.info("hotkey pressed -- id \(self.hotKeyID.id, privacy: .public)")
        onPress?()
    }
}
