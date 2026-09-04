import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "hotkey")

/// Registers one global hotkey, through Carbon's `RegisterEventHotKey` for an ordinary chord, or
/// through `NSEvent` monitors for a modifier-only tap (`KeyCombo.isModifierOnly`) -- Carbon has no
/// way to register the second kind at all.
///
/// **Carbon for a chord: it needs no Accessibility permission** and it fires while another
/// application is focused, which is the whole point of a dictation shortcut. Ruling L4 originally
/// settled on the ⌥Space chord alone, with no monitor installed for anything else; a bare-modifier
/// trigger such as right-⌥ (Superwhisper's own choice) is the reason a monitor exists here now.
///
/// **`NSEvent` monitors for a modifier-only tap, and this DOES need Accessibility** -- the same
/// trust Murmure already asks for to paste. See ``registerModifierOnly(_:onPress:)`` for the
/// reasoning behind that claim (it is reasoning, not a verified fact -- the doc comment says so)
/// and for why `.keyDown` is watched there and not only `.flagsChanged`.
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

    /// How long a tap may take, down to up, in the modifier-only path -- see
    /// ``registerModifierOnly(_:onPress:)`` for why this exists at all.
    private static let modifierOnlyTapCeiling: TimeInterval = 0.35

    private let hotKeyID: EventHotKeyID
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// The monitors backing a modifier-only registration -- `nil` whenever the live combo (if
    /// any) is an ordinary Carbon chord instead.
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// The combo a modifier-only registration is watching for, the pure detector deciding chord
    /// vs. tap for it (`ModifierTapDetector`, tested in `MurmureCore`), and the one thing that
    /// type deliberately does not own -- when the target's current hold began, so
    /// ``observeModifierOnlyEvent(_:)`` can compute how long it has lasted. Replaced wholesale by
    /// every `register(_:onPress:)`, chord or modifier-only, via `unregister()`.
    private var tapTarget: KeyCombo?
    private var tapDetector: ModifierTapDetector?
    private var tapTargetDownAt: Date?

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

    /// Registers `combo`, replacing any previous registration on this manager -- through Carbon
    /// for an ordinary chord, through `NSEvent` monitors for a modifier-only tap. The caller does
    /// not choose which; `combo.isModifierOnly` does, because Carbon has no way to register the
    /// second kind at all.
    ///
    /// Returns `false` when the system refuses either path. Deliberately *not* `@discardableResult`:
    /// dropping the result is the one thing that turns a failed registration into Louis pressing a
    /// dead key forever with no explanation, so it costs a compiler warning.
    func register(_ combo: KeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister()
        if combo.isModifierOnly {
            return registerModifierOnly(combo, onPress: onPress)
        }
        return registerChord(combo, onPress: onPress)
    }

    /// The Carbon path, unchanged in every particular from before modifier-only bindings existed.
    ///
    /// Measured on macOS 26: `eventHotKeyExistsErr` (-9878) is raised only when THIS process
    /// already holds the combination. A clash with another application is not an error at all --
    /// both processes then receive the press -- so `true` means "registered", not "exclusive".
    /// `kEventHotKeyNoOptions` is a measured choice, not an oversight: `kEventHotKeyExclusive`
    /// changes nothing unless the other registrant is *also* exclusive (see the task 4 report,
    /// fix round 1), and would otherwise silently starve another app's shortcut.
    private func registerChord(_ combo: KeyCombo, onPress: @escaping () -> Void) -> Bool {
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

    /// Releases whichever path is live -- Carbon's hotkey and handler, or the modifier-only
    /// monitors -- and always both sets of state, since a registration can switch from one kind
    /// to the other. Idempotent: safe before any `register`, and safe twice. The hotkey goes first
    /// so no event can reach a handler that is about to disappear.
    ///
    /// A Carbon reference is cleared **only** when its OS call succeeded. Clearing it regardless
    /// would turn "the OS may still hold this" into "Swift believes it is clean", and the object
    /// could then be deallocated under a handler that is still installed -- a use-after-free on
    /// the next press. Keeping the reference makes the next `register()` refuse loudly and lets
    /// `deinit` retry; the failure is logged at `.fault`. `NSEvent.removeMonitor` has no such
    /// failure mode -- it cannot refuse -- so the monitor references are always cleared outright.
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
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        tapTarget = nil
        tapDetector = nil
        tapTargetDownAt = nil
    }

    // MARK: - The modifier-only path

    /// Installs `NSEvent` monitors that fire `onPress` the moment `combo`'s one physical key is
    /// tapped and released alone, with nothing else pressed while it was down.
    ///
    /// **`.flagsChanged` AND `.keyDown`, in both the global and the local monitor.** An earlier
    /// version of this watched `.flagsChanged` only and leaned on `modifierOnlyTapCeiling` alone
    /// to reject a chord -- traced against ⌘C typed quickly (⌘ down at t=0, C down at ~60 ms, ⌘ up
    /// at ~200 ms) that is WRONG: 200 ms is comfortably under any reasonable ceiling, so the old
    /// version fired a dictation on every copy a Left-⌘-bound Murmure would see. A duration alone
    /// cannot separate a tap from a chord; only seeing the character key can. So `.keyDown` is
    /// watched too, and ``observeModifierOnlyEvent(_:)`` cancels the pending tap the instant one
    /// arrives while the target is held -- the ceiling stays only as a SECOND guard, for a hold
    /// that never sees an interrupting key at all (Louis resting a finger on the key, say). The
    /// three mouse-button kinds are watched for the same reason: an ⌥-click is a click first, and
    /// must not be read as a clean tap just because no KEY interrupted it.
    ///
    /// **Gated on `AXIsProcessTrusted()`, checked BEFORE installing anything.** An earlier version
    /// of this instead installed both monitors unconditionally and treated a nil `globalMonitor`
    /// as proof Accessibility was missing. That was an assumption dressed as a fact: Apple's
    /// documentation for `NSEvent.addGlobalMonitorForEvents` does not say it returns nil without
    /// the permission, only that it "may only monitor key events" once granted -- the observed
    /// common failure mode elsewhere in AppKit for an under-permissioned monitor is a LIVE token
    /// that simply never calls its handler, not a nil one. Under that assumption the old code
    /// would have reported success (a non-nil monitor) for a registration that was silently dead,
    /// which is worse than refusing outright: the row would show the combo as set, and tapping it
    /// would do nothing, with no way for Louis to tell why. `AXIsProcessTrusted()` is the same
    /// check `ContextCapture`, `DictationController`, `PasteInserter` and `StatusRouter` already
    /// make before touching anything Accessibility-gated -- checking it first here, and refusing
    /// before a monitor goes in at all, means a `false` return here is never itself in question.
    ///
    /// **This IS still an inference, one step further in.** That Accessibility (not Input
    /// Monitoring, macOS 10.15+'s separate grant for `CGEventTapCreate`) is the permission an
    /// `NSEvent` global monitor needs at all is reasoned from Murmure already exercising that
    /// trust for a KEY event (`PasteInserter` posts ⌘V through `CGEvent`), not a separate
    /// confirmation for THIS API. The observable that would prove it wrong is macOS showing an
    /// Input Monitoring prompt the first time a modifier-only toggle is tapped, which nothing here
    /// can pre-empt or suppress; see the shipped report for this as the one thing to watch for.
    ///
    /// **Both a global and a local monitor, watching the same state.** A global monitor never sees
    /// events sent to Murmure's own windows (`CancelHotkey`'s note on why a monitor and a
    /// registration are not the same thing applies here too, in reverse), so without the local
    /// one, tapping the toggle while the General pane itself is key would silently do nothing.
    private func registerModifierOnly(_ combo: KeyCombo, onPress: @escaping () -> Void) -> Bool {
        guard globalMonitor == nil, localMonitor == nil else {
            logger.fault(
                "modifier-only registration refused -- a previous teardown failed and is still held"
            )
            return false
        }
        guard AXIsProcessTrusted() else {
            logger.error("modifier-only hotkey registration refused -- Accessibility not granted")
            return false
        }
        self.onPress = onPress
        tapTarget = combo
        tapDetector = ModifierTapDetector(target: combo)
        tapTargetDownAt = nil

        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        // Two inline closures, not one shared value handed to both calls: a closure literal
        // formed directly in an actor-isolated method's argument position inherits that
        // isolation, which is what lets `observeModifierOnlyEvent` -- a `@MainActor` method --
        // be called from here at all; a closure built once and passed by value would not carry
        // that inference the same way.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observeModifierOnlyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observeModifierOnlyEvent(event)
            // Passed through unmodified: this is a passive watch for a system-wide toggle, not an
            // exclusive capture like `RegisterEventHotKey` -- Murmure's own window must go on
            // seeing its own keys exactly as it would with no toggle bound at all.
            return event
        }

        // Defensive, not the primary gate above: `AXIsProcessTrusted()` is what this function
        // actually trusts, but a nil global monitor here -- trusted or not -- is a registration
        // that would silently never fire, so it is refused rather than reported as a success.
        guard globalMonitor != nil else {
            logger.error(
                "modifier-only hotkey registration refused -- global monitor came back nil despite Accessibility trust"
            )
            unregister()
            return false
        }
        logger.info("""
            modifier-only hotkey registered -- keyCode \(combo.keyCode, privacy: .public), \
            id \(self.hotKeyID.id, privacy: .public)
            """)
        return true
    }

    /// One `.flagsChanged`, `.keyDown`, or mouse-button-down, from either monitor, fed to
    /// `tapDetector` -- `ModifierTapDetector`'s own note has the decision rule; this is only the
    /// AppKit glue around it: turning an `NSEvent` into the plain numbers that pure type reads,
    /// and stamping the one thing it deliberately does not own -- when the current hold began, so
    /// the elapsed time it asks for on a release can be computed at all.
    ///
    /// **`tapTargetDownAt` is stamped and cleared only on a transition `tapDetector` itself
    /// reports, never by a toggle of its own.** An earlier version toggled it independently,
    /// stamping on one target-key event and reading-then-clearing on the next -- exactly the same
    /// class of bug `ModifierTapDetector`'s own note describes for `isDown`, and traced the same
    /// way: a duplicate down event (the dropped-event recovery case) would have read back and
    /// cleared a stamp the detector itself still considers live, so the NEXT, genuine up would
    /// measure its elapsed time from the wrong instant. Comparing `isTargetDown` before and after
    /// `observe(_:...)` -- both readings of the SAME authoritative state -- means this can only
    /// ever stamp or clear when something genuinely changed.
    private func observeModifierOnlyEvent(_ event: NSEvent) {
        guard tapTarget != nil else { return }

        if event.type == .keyDown {
            _ = tapDetector?.observe(
                .keyDown(keyCode: event.keyCode, appKitModifierFlags: event.modifierFlags.rawValue),
                elapsedSinceDown: 0, ceiling: Self.modifierOnlyTapCeiling)
            return
        }
        guard event.type == .flagsChanged else {
            // One of the three mouse-button kinds in the monitor mask -- an interruption, not a
            // target event: an ⌥-click must not read as a clean tap just because no KEY arrived.
            _ = tapDetector?.observeMouseDown()
            return
        }

        let wasDown = tapDetector?.isTargetDown ?? false
        let elapsed = tapTargetDownAt.map { Date().timeIntervalSince($0) } ?? 0
        let outcome = tapDetector?.observe(
            .flagsChanged(keyCode: event.keyCode, appKitModifierFlags: event.modifierFlags.rawValue),
            elapsedSinceDown: elapsed, ceiling: Self.modifierOnlyTapCeiling)

        switch (wasDown, tapDetector?.isTargetDown ?? false) {
        case (false, true): tapTargetDownAt = Date() // the target's own down, genuinely
        case (true, false): tapTargetDownAt = nil // the target's own up, genuinely
        default: break // no transition -- some other key, or a duplicate/glitched event
        }

        if outcome == .fire {
            fireModifierOnlyTap()
        }
    }

    private func fireModifierOnlyTap() {
        logger.info("modifier-only hotkey tapped -- id \(self.hotKeyID.id, privacy: .public)")
        onPress?()
    }

    private func fire() {
        logger.info("hotkey pressed -- id \(self.hotKeyID.id, privacy: .public)")
        onPress?()
    }
}
