import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "hotkey")

/// Registers a TABLE of global hotkeys, keyed by `HotkeyBindingID` -- the toggle, or one mode's
/// own shortcut (`Mode.hotkey`) -- through Carbon's `RegisterEventHotKey` for an ordinary chord,
/// or through `NSEvent` monitors for a modifier-only tap (`KeyCombo.isModifierOnly`) -- Carbon has
/// no way to register the second kind at all.
///
/// **One binding per id, and nothing here decides which ids exist.** This type is a pure
/// registration table: `DictationController` decides which combo goes with which id (and settles
/// a clash between two of them, via `HotkeyAssignments.resolve` in `MurmureCore`) before ever
/// calling `register(id:combo:onPress:)`. A binding replaces any previous one under the SAME id;
/// every other id already registered is untouched.
///
/// **Carbon for a chord: it needs no Accessibility permission** and it fires while another
/// application is focused, which is the whole point of a dictation shortcut. Ruling L4 originally
/// settled on the ⌥Space chord alone, with no monitor installed for anything else; a bare-modifier
/// trigger such as right-⌥ (Superwhisper's own choice) is the reason a monitor exists here now.
///
/// **`NSEvent` monitors for a modifier-only tap, and this DOES need Accessibility** -- the same
/// trust Murmure already asks for to paste. See ``registerModifierOnly(id:combo:onPress:)`` for
/// the reasoning behind that claim (it is reasoning, not a verified fact -- the doc comment says
/// so) and for why `.keyDown` is watched there and not only `.flagsChanged`.
///
/// **One Carbon handler, one pair of `NSEvent` monitors, for every binding this manager holds --
/// not one of either per binding.** Carbon's own handler is installed on the *application* event
/// target and would see every hotkey the process registers regardless; giving each binding its
/// own would only mean the SAME event reaching several handlers that each have to filter it back
/// down to their own id, which is exactly what one handler dispatching on `EventHotKeyID.id`
/// already does in a single place. The modifier-only path has no id of its own to dispatch on at
/// all -- an `NSEvent` says which physical key changed, never which BINDING it was meant for --
/// so every modifier-only binding's own `ModifierTapDetector` has to see every such event and
/// decide independently whether ITS target was the one that moved.
///
/// `@MainActor` is load-bearing, not decoration. The Carbon handler holds an *unretained* pointer
/// back to this object, invalidated in `deinit` by removing the handler, and the numeric ids below
/// are mutated without a lock. Both are safe only because every entry point runs on the main
/// thread -- the same thread Carbon dispatches the handler on (the run loop owning the application
/// event target). Isolating the type makes the compiler enforce that instead of a doc comment
/// believing it; the two places that step outside the isolation -- the C callback and `deinit` --
/// assert it with `MainActor.assumeIsolated`, so a violation traps rather than races.
@MainActor
final class HotkeyManager {
    /// Carbon's own four-character signature for every hotkey this process ever registers -- "MURM".
    /// One constant for the whole table, since the numeric id (not the signature) is what tells two
    /// of this manager's own bindings apart, and a foreign hotkey firing through the same handler
    /// (there is only one *application* event target) still needs a signature check to be ignored.
    private static let signature = OSType(0x4D55_524D)

    /// Every numeric Carbon id this process has ever handed out, so two bindings -- registered at
    /// different times, for different ids -- never collide on the number Carbon itself uses to
    /// tell them apart. Unlike ``nextID`` in the single-binding version this replaces, this now
    /// counts BINDINGS, not manager instances -- there is one `HotkeyManager` in the process, and
    /// it can hold many chords at once.
    private static var nextNumericID: UInt32 = 1

    /// How long a tap may take, down to up, in the modifier-only path -- see
    /// ``registerModifierOnly(id:combo:onPress:)`` for why this exists at all.
    private static let modifierOnlyTapCeiling: TimeInterval = 0.35

    // MARK: - The chord path (Carbon)

    /// One binding's live state on the Carbon side. `hotKeyRef` is never optional here, unlike the
    /// single-binding version this replaces: an entry only ever enters ``chords`` already holding a
    /// live registration (see ``registerChord(id:combo:onPress:)``), and ``unregister(id:)`` leaves
    /// a failed teardown's entry untouched rather than storing a half-torn-down one.
    ///
    /// `combo` is kept only so ``combo(for:)`` can answer "what is this id already bound to?"
    /// without a second table -- nothing on the Carbon side needs it back.
    private struct ChordEntry {
        let hotKeyRef: EventHotKeyRef
        let numericID: UInt32
        let combo: KeyCombo
        let onPress: () -> Void
    }
    private var chords: [HotkeyBindingID: ChordEntry] = [:]
    /// The reverse of ``chords``, keyed by the number Carbon's own event actually carries --
    /// `EventHotKeyID.id` says nothing about WHICH binding fired except through this table.
    private var numericIDs: [UInt32: HotkeyBindingID] = [:]
    /// Installed once, lazily, on the first chord this manager ever registers; removed once the
    /// last one is gone (``teardownChordHandlerIfUnused()``). Every chord shares this one handler.
    private var eventHandler: EventHandlerRef?

    // MARK: - The modifier-only path (NSEvent)

    /// One binding's live state on the modifier-only side. `downAt` is this binding's own copy of
    /// the single `tapTargetDownAt` the version before this one kept: with several modifier-only
    /// bindings live at once, each watches a DIFFERENT physical key, so each needs its own down
    /// timestamp -- a shared one would let two unrelated taps overwrite each other's clock.
    private struct ModifierOnlyEntry {
        var detector: ModifierTapDetector
        var downAt: Date?
        /// Kept for the same reason `ChordEntry.combo` is: ``combo(for:)`` answers both paths
        /// from one lookup without asking `ModifierTapDetector` to expose its own target combo.
        let combo: KeyCombo
        let onPress: () -> Void
    }
    private var modifierOnlyBindings: [HotkeyBindingID: ModifierOnlyEntry] = [:]
    /// The monitors backing every live modifier-only binding -- `nil` whenever none is registered.
    /// Shared, not one pair per binding: see the type's own note on why one pair suffices.
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {}

    deinit {
        // `deinit` is nonisolated whatever the type says. Assert the main actor rather than
        // weaken the isolation: the type is non-Sendable and both owners are `@MainActor`, so the
        // last release is on the main thread -- and if that ever stops being true, this traps
        // instead of tearing down Carbon state from under a handler that may be running.
        MainActor.assumeIsolated {
            unregisterAll()
            if !self.chords.isEmpty || self.eventHandler != nil
                || !self.modifierOnlyBindings.isEmpty || self.globalMonitor != nil
                || self.localMonitor != nil {
                logger.fault("""
                    hotkey teardown INCOMPLETE at deinit -- \
                    \(self.chords.count, privacy: .public) chord(s) and \
                    \(self.modifierOnlyBindings.count, privacy: .public) modifier-only binding(s) \
                    still registered; a surviving handler or monitor now points at freed memory
                    """)
            }
        }
    }

    /// Registers `combo` under `id`, replacing any previous binding under that SAME id -- through
    /// Carbon for an ordinary chord, through `NSEvent` monitors for a modifier-only tap. The caller
    /// does not choose which; `combo.isModifierOnly` does, because Carbon has no way to register
    /// the second kind at all. Every OTHER id already registered is untouched.
    ///
    /// Returns `false` when the system refuses either path. Deliberately *not* `@discardableResult`:
    /// dropping the result is the one thing that turns a failed registration into Louis pressing a
    /// dead key forever with no explanation, so it costs a compiler warning.
    func register(id: HotkeyBindingID, combo: KeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister(id: id)
        if combo.isModifierOnly {
            return registerModifierOnly(id: id, combo: combo, onPress: onPress)
        }
        return registerChord(id: id, combo: combo, onPress: onPress)
    }

    /// The combo currently registered under `id`, or `nil` when nothing is. Lets a caller that
    /// re-derives the same bindings on every call (`DictationController.updateModeHotkeys()`,
    /// reached every time the menu opens) skip a `register` that would only replace a binding
    /// with an identical one -- an unregister/register round trip that, on the modifier-only
    /// path, discards a `ModifierTapDetector` mid-hold for no behavioural change at all.
    func combo(for id: HotkeyBindingID) -> KeyCombo? {
        chords[id]?.combo ?? modifierOnlyBindings[id]?.combo
    }

    /// The Carbon path, unchanged in every particular from before this held a table instead of one
    /// binding, except that the handler and the numeric id are now shared across every chord.
    ///
    /// Measured on macOS 26: `eventHotKeyExistsErr` (-9878) is raised only when THIS process
    /// already holds the combination. A clash with another application is not an error at all --
    /// both processes then receive the press -- so `true` means "registered", not "exclusive".
    /// `kEventHotKeyNoOptions` is a measured choice, not an oversight: `kEventHotKeyExclusive`
    /// changes nothing unless the other registrant is *also* exclusive (see the task 4 report,
    /// fix round 1), and would otherwise silently starve another app's shortcut.
    private func registerChord(
        id: HotkeyBindingID, combo: KeyCombo, onPress: @escaping () -> Void
    ) -> Bool {
        // Only reachable when a previous teardown of THIS id failed. Registering anyway would
        // overwrite the surviving reference, losing the last handle on state the OS still holds.
        guard chords[id] == nil else {
            logger.fault("""
                hotkey registration refused for id \(String(describing: id), privacy: .public) -- \
                the previous teardown failed and is still held
                """)
            return false
        }
        guard ensureChordHandlerInstalled() else { return false }

        let numericID = Self.nextNumericID
        Self.nextNumericID += 1
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: numericID),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyNoOptions), &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            logger.error("""
                hotkey registration failed for id \(String(describing: id), privacy: .public) -- \
                OSStatus \(status, privacy: .public), keyCode \(combo.keyCode, privacy: .public), \
                modifiers \(combo.carbonModifiers, privacy: .public) \
                (-9878 means this process already holds the combination)
                """)
            // Leave nothing installed for a binding that never got its own hotkey. The shared
            // handler stays if another chord is still using it.
            teardownChordHandlerIfUnused()
            return false
        }
        chords[id] = ChordEntry(hotKeyRef: hotKeyRef, numericID: numericID, combo: combo, onPress: onPress)
        numericIDs[numericID] = id
        logger.info("""
            hotkey registered -- id \(String(describing: id), privacy: .public), \
            keyCode \(combo.keyCode, privacy: .public), modifiers \(combo.carbonModifiers, privacy: .public)
            """)
        return true
    }

    /// Installs the one Carbon handler every chord binding shares, if it is not already up.
    /// Idempotent: a second chord registering while the first is still live is a no-op here.
    private func ensureChordHandlerInstalled() -> Bool {
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var firedID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &firedID
                )
                guard paramStatus == noErr else { return OSStatus(eventNotHandledErr) }
                // Carbon dispatches on the run loop owning the application event target -- the
                // main one -- but a C callback cannot say so in its signature. Assert it here so
                // the unretained pointer below is touched under the same isolation as `deinit`.
                return MainActor.assumeIsolated {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    guard firedID.signature == HotkeyManager.signature else {
                        return OSStatus(eventNotHandledErr)
                    }
                    // `true` only when THIS manager actually held `firedID.id` -- a second
                    // `HotkeyManager` instance in the same process (`EscapeCancelKey`'s own) shares
                    // this same signature and the same application event target, so `noErr` here
                    // for an id this instance does not recognise would tell Carbon the press was
                    // handled and stop it from ever reaching the OTHER manager's handler.
                    return manager.fireChord(numericID: firedID.id) ? noErr : OSStatus(eventNotHandledErr)
                }
            }, 1, &eventType, selfPtr, &eventHandler)
        guard status == noErr else {
            logger.error("hotkey handler install failed -- OSStatus \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Removes the shared handler once no chord needs it any more. Safe to call after every chord
    /// teardown attempt, successful or not: it only acts when ``chords`` is actually empty.
    private func teardownChordHandlerIfUnused() {
        guard chords.isEmpty, let eventHandler else { return }
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

    /// Returns whether THIS manager actually held `numericID` -- the handler installed above
    /// answers Carbon with `noErr` only when this is `true`, and `eventNotHandledErr` otherwise, so
    /// a numeric id this instance does not recognise falls through to whichever OTHER handler on
    /// the same application event target (there is only one) does recognise it, rather than being
    /// swallowed here. Two `HotkeyManager` instances coexist in the process for the whole of every
    /// recording -- `DictationController`'s own and `EscapeCancelKey`'s -- both sharing the
    /// signature and the target, so this is not a hypothetical caller.
    @discardableResult
    private func fireChord(numericID: UInt32) -> Bool {
        guard let id = numericIDs[numericID], let entry = chords[id] else { return false }
        logger.info("hotkey pressed -- id \(String(describing: id), privacy: .public)")
        entry.onPress()
        return true
    }

    // MARK: - The modifier-only path

    /// Installs `NSEvent` monitors that fire this id's `onPress` the moment `combo`'s one physical
    /// key is tapped and released alone, with nothing else pressed while it was down. The monitors
    /// themselves are shared with every other modifier-only binding already registered -- only
    /// `modifierOnlyBindings[id]`'s own detector is new here.
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
    /// **Gated on `AXIsProcessTrusted()`, checked BEFORE the shared monitors go in.** An earlier
    /// version of this instead installed both monitors unconditionally and treated a nil
    /// `globalMonitor` as proof Accessibility was missing. That was an assumption dressed as a
    /// fact: Apple's documentation for `NSEvent.addGlobalMonitorForEvents` does not say it returns
    /// nil without the permission, only that it "may only monitor key events" once granted -- the
    /// observed common failure mode elsewhere in AppKit for an under-permissioned monitor is a
    /// LIVE token that simply never calls its handler, not a nil one. Under that assumption the
    /// old code would have reported success (a non-nil monitor) for a registration that was
    /// silently dead, which is worse than refusing outright: the row would show the combo as set,
    /// and tapping it would do nothing, with no way for Louis to tell why. `AXIsProcessTrusted()`
    /// is the same check `ContextCapture`, `DictationController`, `PasteInserter` and
    /// `StatusRouter` already make before touching anything Accessibility-gated -- checking it
    /// first here, and refusing before a monitor goes in at all, means a `false` return here is
    /// never itself in question. Checked on EVERY modifier-only registration, not only the first
    /// that installs the shared monitors: a later binding must not silently inherit a trust that
    /// held at the time the pair first went in.
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
    /// one, tapping a modifier-only shortcut while the General pane itself is key would silently
    /// do nothing.
    private func registerModifierOnly(
        id: HotkeyBindingID, combo: KeyCombo, onPress: @escaping () -> Void
    ) -> Bool {
        // Only reachable when a previous teardown of THIS id failed to remove its entry -- in
        // practice `NSEvent.removeMonitor` cannot refuse, so this mirrors the chord side's own
        // guard for the same reason: defensive symmetry, not a path this can actually take.
        guard modifierOnlyBindings[id] == nil else {
            logger.fault("""
                modifier-only registration refused for id \(String(describing: id), privacy: .public) \
                -- a previous teardown failed and is still held
                """)
            return false
        }
        guard AXIsProcessTrusted() else {
            logger.error("""
                modifier-only hotkey registration refused for id \(String(describing: id), privacy: .public) \
                -- Accessibility not granted
                """)
            return false
        }
        guard ensureModifierOnlyMonitorsInstalled() else { return false }

        modifierOnlyBindings[id] = ModifierOnlyEntry(
            detector: ModifierTapDetector(target: combo), downAt: nil, combo: combo, onPress: onPress)
        logger.info("""
            modifier-only hotkey registered -- id \(String(describing: id), privacy: .public), \
            keyCode \(combo.keyCode, privacy: .public)
            """)
        return true
    }

    /// Installs the shared monitor pair, if it is not already up. Idempotent: a second
    /// modifier-only binding registering while the first is still live is a no-op here.
    ///
    /// **Both monitors, not just `globalMonitor`, gate "already installed".** The two are
    /// installed together, right below, and removed together (`teardownModifierOnlyMonitors()`)
    /// -- there is no path that is meant to leave one nil and the other live. But "meant to" is
    /// not "provably true", and treating a lone non-nil `globalMonitor` as proof the pair is up
    /// would leave `localMonitor` silently nil forever if it ever happened: every modifier-only
    /// binding would then go on missing every keystroke sent to Murmure's OWN window (the local
    /// monitor's whole job, its own doc comment above), with nothing to say why. Tearing down
    /// whichever half survived and reinstalling both is cheap and always correct, unlike trusting
    /// a partial state to mean what it is supposed to.
    private func ensureModifierOnlyMonitorsInstalled() -> Bool {
        guard globalMonitor == nil || localMonitor == nil else { return true }
        teardownModifierOnlyMonitors()

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
        guard globalMonitor != nil, localMonitor != nil else {
            logger.error(
                "modifier-only hotkey registration refused -- a monitor came back nil despite Accessibility trust")
            teardownModifierOnlyMonitors()
            return false
        }
        return true
    }

    private func teardownModifierOnlyMonitorsIfUnused() {
        guard modifierOnlyBindings.isEmpty else { return }
        teardownModifierOnlyMonitors()
    }

    private func teardownModifierOnlyMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    /// One `.flagsChanged`, `.keyDown`, or mouse-button-down, from either monitor, fed to EVERY
    /// live modifier-only binding's own detector -- `ModifierTapDetector`'s own note has the
    /// decision rule; this is only the AppKit glue around it: turning an `NSEvent` into the plain
    /// numbers that pure type reads, and stamping the one thing it deliberately does not own --
    /// when each binding's own hold began, so the elapsed time it asks for on a release can be
    /// computed at all.
    ///
    /// **Every binding sees every event, and decides for itself.** A binding whose target is not
    /// the key this event names simply reads `.notYet` back (`ModifierTapDetector`'s own dispatch
    /// on `keyCode == target.keyCode`) -- or, for a DIFFERENT modifier changing while ITS target is
    /// held, an interruption. Two modifier-only bindings on two different keys therefore never
    /// interfere: Right-⌥ tapped alone does not touch Left-⌘'s detector at all.
    ///
    /// **Iterated over a snapshot of the ids, not over the dictionary itself.** Mutating
    /// `modifierOnlyBindings` (writing back an updated detector) while a `for` loop is reading
    /// that SAME dictionary is exactly the kind of simultaneous access Swift traps on; a
    /// `[HotkeyBindingID]` taken before the loop starts owns no reference into the dictionary's
    /// storage, so the loop body is free to mutate it entry by entry.
    ///
    /// **`downAt` is stamped and cleared only on a transition `tapDetector` itself reports, never
    /// by a toggle of its own.** An earlier version toggled it independently, stamping on one
    /// target-key event and reading-then-clearing on the next -- exactly the same class of bug
    /// `ModifierTapDetector`'s own note describes for `isDown`, and traced the same way: a
    /// duplicate down event (the dropped-event recovery case) would have read back and cleared a
    /// stamp the detector itself still considers live, so the NEXT, genuine up would measure its
    /// elapsed time from the wrong instant. Comparing `isTargetDown` before and after `observe(_:
    /// ...)` -- both readings of the SAME authoritative state -- means this can only ever stamp or
    /// clear when something genuinely changed.
    private func observeModifierOnlyEvent(_ event: NSEvent) {
        guard !modifierOnlyBindings.isEmpty else { return }

        for id in Array(modifierOnlyBindings.keys) {
            guard var entry = modifierOnlyBindings[id] else { continue }
            let outcome: ModifierTapDetector.Outcome
            if event.type == .keyDown {
                outcome = entry.detector.observe(
                    .keyDown(keyCode: event.keyCode, appKitModifierFlags: event.modifierFlags.rawValue),
                    elapsedSinceDown: 0, ceiling: Self.modifierOnlyTapCeiling)
            } else if event.type == .flagsChanged {
                let wasDown = entry.detector.isTargetDown
                let elapsed = entry.downAt.map { Date().timeIntervalSince($0) } ?? 0
                outcome = entry.detector.observe(
                    .flagsChanged(
                        keyCode: event.keyCode, appKitModifierFlags: event.modifierFlags.rawValue),
                    elapsedSinceDown: elapsed, ceiling: Self.modifierOnlyTapCeiling)
                switch (wasDown, entry.detector.isTargetDown) {
                case (false, true): entry.downAt = Date() // this binding's own target down
                case (true, false): entry.downAt = nil // this binding's own target up
                default: break // no transition -- some other key, or a duplicate/glitched event
                }
            } else {
                // One of the three mouse-button kinds in the monitor mask -- an interruption, not
                // a target event: an ⌥-click must not read as a clean tap just because no KEY
                // interrupted it.
                outcome = entry.detector.observeMouseDown()
            }
            modifierOnlyBindings[id] = entry

            if outcome == .fire {
                logger.info("modifier-only hotkey tapped -- id \(String(describing: id), privacy: .public)")
                entry.onPress()
            }
        }
    }

    // MARK: - Teardown

    /// Releases whichever binding is registered under `id` -- Carbon's hotkey, or a modifier-only
    /// detector -- and, if that was the last of its kind, the shared handler or monitors behind
    /// it. Idempotent: safe when `id` is not registered at all, and safe twice.
    ///
    /// A Carbon reference is cleared **only** when its OS call succeeded. Clearing it regardless
    /// would turn "the OS may still hold this" into "Swift believes it is clean", and the object
    /// could then be deallocated under a handler that is still installed -- a use-after-free on
    /// the next press. Keeping the reference makes the next `register(id:)` for the SAME id refuse
    /// loudly and lets `deinit` retry; the failure is logged at `.fault`. `NSEvent.removeMonitor`
    /// has no such failure mode -- it cannot refuse -- so a modifier-only binding is always
    /// cleared outright.
    func unregister(id: HotkeyBindingID) {
        if let entry = chords[id] {
            let status = UnregisterEventHotKey(entry.hotKeyRef)
            if status == noErr {
                chords.removeValue(forKey: id)
                numericIDs.removeValue(forKey: entry.numericID)
                teardownChordHandlerIfUnused()
            } else {
                logger.fault("""
                    hotkey unregister FAILED for id \(String(describing: id), privacy: .public) -- \
                    OSStatus \(status, privacy: .public); the combination may still be held by this process
                    """)
                // The entry stays: `register(id:)` refuses for this id, and `deinit` retries.
            }
        }
        if modifierOnlyBindings.removeValue(forKey: id) != nil {
            teardownModifierOnlyMonitorsIfUnused()
        }
    }

    /// Every binding this manager holds, released at once -- General's shortcut recorder
    /// (`releaseToggleHotkey()`/`restoreToggleHotkey()`) needs this rather than a loop over one id,
    /// because a per-mode chord left live while Louis records a NEW combo would consume the very
    /// keys he is trying to capture, the same hazard the toggle alone used to have.
    func unregisterAll() {
        for id in Set(chords.keys).union(modifierOnlyBindings.keys) {
            unregister(id: id)
        }
    }
}
