import AppKit
import ApplicationServices
import Foundation
import MurmureCore
import os
import SwiftUI

/// Owns the one dictation session, the one hotkey registration, and the binding between the
/// session's state and what the menu bar shows.
///
/// No capture list on the closures below: nothing `AppState` holds points back here, so a strong
/// capture is not a cycle — and the controller lives for the whole process anyway.
@MainActor
final class DictationController {
    private let session: DictationSession
    private let hotkeys = HotkeyManager()
    private let inserter: PasteInserter
    private let appState: AppState
    /// The notch surface. Owned here because the only thing allowed to drive it is the session's
    /// own state changes -- never the hotkey, which fires on presses the session then ignores.
    private let notch: NotchController
    /// The surface for a display that has no notch to grow, which is every external one. Driven
    /// from the same state changes as the notch; on any one display only one of the two can draw,
    /// because each asks `StatusSurfaceChoice.surface(on:)` about the display it resolved. They
    /// resolve that display by different signals, though -- see `StatusPanelController`.
    private let statusPanel: StatusPanelController
    /// The one surface that takes clicks and the only one that waits: it holds a dictation the
    /// paste could not deliver, with Re-paste and Copy, and it holds an `AppAlert` when Murmure
    /// itself cannot work. Everything else in lot 3 retracts on a timer; this does not, and that
    /// asymmetry is the whole of task T6.
    ///
    /// Not the notch, and `ProblemPanelController` argues why at length: buttons need mouse
    /// events, both existing surfaces refuse them on purpose, and the notch's window is
    /// DynamicNotchKit's -- `canBecomeKey` is `true` there and cannot be overridden from outside,
    /// so the guarantee that keeps ⌘V going to Louis's terminal could not be made.
    private let problemPanel: ProblemPanelController
    /// The third surface, and the only one Louis does not have to look at. Driven from the same
    /// state changes as the other two, and by the same rule: nothing but the session's own state
    /// is allowed to make Murmure a sound.
    private let feedback: CueFeedback
    /// Nil when Application Support could not be reached at all; see `init`. Kept so the menu can
    /// re-read the folder without a restart.
    private let modesDirectory: URL?
    /// How far into the audio the transcription has got, for whatever draws the `.transcribing`
    /// phase to pull. Internal rather than private for exactly that reason: it is one box shared
    /// between the engine that advances it and the surface that reads it, the same arrangement as
    /// `AudioLevels`.
    ///
    /// It is honest for roughly half of Louis's dictations and only for those: WhisperKit advances
    /// its progress once per 30 s decoding window, so audio that fits in one window measures
    /// nothing at all (0 updates in 0.43-0.60 s, on 3.1 s to 13.7 s recordings), while an 87.8 s
    /// one gets 3 updates and a 478.9 s one gets 19. Across the 1 469 real dictations in the
    /// corpus, 50 % are under 29.7 s. `DecodeProgress.steps` is what says which case a given
    /// dictation turned out to be.
    let transcriptionProgress = DecodeProgressBox()
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "dictation")

    init(appState: AppState) {
        self.appState = appState

        // The waveform's one box: the recorder writes into it from the audio thread, the notch's
        // wings read it while a dictation records. Built here because it is the only place that
        // sees both of them, and shared rather than owned by either -- a second box would be a
        // waveform of a recording nobody is making.
        let levels = AudioLevels()

        // Built at launch and never rebuilt; see `NotchController`. No window exists yet -- idle
        // costs zero pixels -- so this is a `DynamicNotch` object and a screen-parameters
        // observer, nothing on screen.
        let notch = NotchController(levels: levels, progress: transcriptionProgress)
        self.notch = notch

        // A local for the same reason `notch` is one: the state-change closure below captures
        // these directly, so it never has to reach back through `self`.
        let statusPanel = StatusPanelController(levels: levels, progress: transcriptionProgress)
        self.statusPanel = statusPanel

        // Task 6 made `onClipboardOutcome` a REQUIRED init parameter with no default, precisely so
        // this line cannot forget to decide. `PasteInserter()` no longer compiles.
        let inserter = PasteInserter { outcome in
            Task { @MainActor in appState.noteClipboard(outcome) }
        }
        self.inserter = inserter

        // Built here, before the session, because its re-paste needs only the inserter -- and it
        // has to exist before the state-change closure below, which is what drives it. There is
        // exactly one `PasteInserter` in the process and both re-paste routes go through it, so
        // the clipboard-restore consumer stays unique (`PasteInserter.onClipboardOutcome` is a
        // required parameter for precisely that reason).
        //
        // It is handed the TEXT rather than asked to fetch it. The menu's `repasteLast()` reads
        // `session.lastTranscript`, which is the right question there -- it is offered even when
        // nothing failed. The panel already holds the transcript it is displaying, so pasting
        // that one is what makes the button unable to deliver a different dictation from the one
        // on screen. `Self.repaste` is the single implementation both call.
        let problemPanel = ProblemPanelController { [log] text in
            Task { @MainActor in
                await Self.repaste(text, inserter: inserter, appState: appState, log: log)
            }
        }
        self.problemPanel = problemPanel

        // Built at launch rather than at the first dictation: `CuePlayer` decodes both sounds and
        // gets an `AVAudioEngine` running here, so the press that starts a dictation only has to
        // enqueue a buffer that is already in memory (measured at 0.06 ms, against 21.8 ms for
        // `NSSound.play()` -- see `CuePlayer`).
        //
        // A cue that cannot be loaded is logged and nothing more, which is the one place in this
        // file where that is the right answer: the sound is a convenience laid over surfaces that
        // already say everything it says, so a missing file must not cost Louis a dictation. It
        // still has to be SAID, or a bundle that shipped without its sounds would go mute with
        // nothing anywhere admitting why.
        let feedback = CueFeedback(player: CuePlayer { [log] problem in
            log.error("cue unavailable: \(problem, privacy: .public)")
        })
        self.feedback = feedback

        // `modes/`, never the `Murmure/` folder above it: `recordings/` and the Whisper models
        // are its siblings. Nil when Application Support cannot be reached at all -- dictation
        // then runs on the built-in `Voice`, which is the right answer rather than a failure:
        // Louis can still dictate, and only the modes he edited are missing.
        let modesDirectory: URL?
        do {
            modesDirectory = try Storage.directory(subfolder: "modes")
        } catch {
            modesDirectory = nil
            log.error("modes folder unavailable: \(error.localizedDescription, privacy: .public)")
            appState.modeProblems = [
                "Modes folder unavailable (\(error.localizedDescription)). "
                    + "Dictation runs on the built-in Voice mode.",
            ]
        }
        self.modesDirectory = modesDirectory
        if let modesDirectory {
            // Every launch, not only the first: a built-in deleted by hand comes back, which is
            // how `voice.json` repairs itself. It writes only files that are ABSENT, so a mode
            // Louis has edited is never overwritten.
            //
            // This `report` cannot fire on this path, and that is not an oversight to read as a
            // covered failure: `createBuiltInsIfMissing()` only ever calls `save()`, which THROWS
            // -- the `catch` below is the real failure path here -- and it never reads the folder,
            // so no `ModeLoadProblem` is ever produced. It is still passed because `ModeStore.init`
            // requires it on purpose (a store built without one would drop modes in silence), and
            // it logs rather than does nothing so that the day this store is asked to read
            // anything, the problem has somewhere to go. The reporting paths that DO fire are
            // `refreshModes()` and `ModeAwareRefinement.modeForNewDictation()`, each building its
            // own store precisely so its problems go somewhere of their own.
            let store = ModeStore(directory: modesDirectory) { [log] problem in
                log.error("mode file problem: \(problem.description, privacy: .public)")
            }
            do {
                try store.createBuiltInsIfMissing()
            } catch {
                // Only the missing built-ins are lost; the modes already on disk still load.
                log.error("""
                    could not write the built-in modes: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                appState.modeProblems = [
                    "Could not write the built-in modes (\(error.localizedDescription)).",
                ]
            }
        }

        // The archive, and §5.4 rule 3 in one place: the real path is resolved HERE and handed
        // down, which is exactly why `HistoryStore(databaseURL:)` has no convenience initializer.
        // `murmure.sqlite` lives in `Murmure/` itself, a sibling of `modes/` and `recordings/`
        // (spec §7), so what has to exist first is the folder rather than a subfolder of its own.
        //
        // Nil when it cannot be opened, and that is the whole recovery: a history that will not
        // open must not cost a dictation, which is spec §9's rule for the refiner one layer down.
        // Said once here rather than once per row -- a broken database would otherwise log a line
        // per dictation for ever. The window that will show it to Louis is T9's, not this task's.
        let history: HistoryStore?
        do {
            let folder = try Storage.directory()
            history = try HistoryStore(
                databaseURL: folder.appendingPathComponent("murmure.sqlite"))
        } catch {
            history = nil
            log.error("history unavailable: \(error.localizedDescription, privacy: .public)")
        }

        session = DictationSession(
            recorder: AudioRecorder(levels: levels),
            transcriber: WhisperKitEngine(progress: transcriptionProgress),
            inserter: inserter,
            refiner: ModeAwareRefinement(modesDirectory: modesDirectory, appState: appState),
            recording: DictationArchive(store: history)
        ) { state in
            Task { @MainActor in
                // FIRST, ahead of every line below it, and that ordering is the feature. Louis
                // starts speaking the moment he hears the start cue, so everything queued in front
                // of it is time his microphone is live and he does not know it. What follows is a
                // `DynamicNotch` being asked to put a window on screen, which is the most
                // expensive thing in this closure by a wide margin.
                //
                // It is also the reason the cue is queued from HERE rather than played inside
                // `DictationSession`: the session emits `.recording` only once `recorder.start()`
                // has returned, and everything between that and this line is a read of four small
                // mode files (measured: median 0.45 ms) plus one hop onto the main actor
                // (median 0.02 ms). Half a millisecond, against the 27 ms the output device itself
                // costs -- so the session keeps its side effects and its tests unchanged.
                feedback.apply(state)
                if case .recording = state {
                    // Starting a dictation clears the previous one's warnings, and this is the only
                    // thing that ever will: `PasteInserter` reports an outcome only when it actually
                    // touched the clipboard, so its empty-transcript early return would otherwise
                    // leave the last warning on screen indefinitely.
                    appState.clipboardWarning = nil
                    appState.lastFailureMessage = nil
                    appState.recoveredText = nil
                    // Same reason: a refinement notice is about the dictation that just ended,
                    // and nothing else would ever take it off the screen. `modeProblems` is
                    // deliberately NOT cleared here -- a broken mode file survives the press.
                    appState.refinementNotice = nil
                    // **Re-asked here, and not only at launch.** Accessibility is granted against
                    // the app's code signature, so a rebuild revokes it with no dialog and no
                    // error -- `CGEvent.post` simply does nothing. Louis lost it exactly that way,
                    // and the only symptom was a paste that did not happen. A flag read once at
                    // launch would keep answering for a world that has changed underneath it.
                    //
                    // `AXIsProcessTrusted()` READS the trust database and never prompts;
                    // `PasteInserter.requestAccessibilityIfNeeded()`, which does prompt, is called
                    // once at launch and never from here -- a permission dialog opening on the
                    // hotkey would land on top of whatever Louis is dictating into.
                    //
                    // Assigned, not or-ed: this is a fresh reading, so granting the permission
                    // clears the alert on the very next dictation without anything else running.
                    appState.accessibilityDenied = !AXIsProcessTrusted()
                }
                // The message is not just an icon (ruling L7): `.failed`'s payload says whether the
                // microphone is denied, the model failed to download or the paste was refused, and
                // an exclamation triangle with no text is a failure mechanism with no consumer.
                if case .failed(let message, let recovered) = state {
                    appState.lastFailureMessage = message
                    // Kept, where lot 1 dropped it: this is the dictation the paste could not
                    // deliver, and it exists nowhere else. Lot 3 T6 offers it for a re-paste.
                    appState.recoveredText = recovered
                }
                appState.status = switch state {
                case .idle: .idle
                case .recording: .recording
                case .transcribing: .transcribing
                case .refining: .refining
                case .inserting: .inserting
                // The menu bar gets no new symbol for it. `.completed` is emitted and immediately
                // followed by `.idle`, so a glyph of its own would be a flicker of a frame or
                // two; the surface that shows a completion is the notch, which holds it on
                // purpose. What lot 1's menu did is exactly what it keeps doing.
                case .completed: .idle
                case .failed: .failed
                }
                // The notch is driven from the same state changes as the menu, and from nothing
                // else. Driving it from the hotkey instead would put a black band on screen for
                // presses `DictationSession.toggle()` deliberately ignores -- a band with no
                // dictation behind it.
                //
                // Every phase, not just the recording: `NotchPresenter` (in `MurmureCore`, where
                // it is tested) turns each state change into the phase to show, including the two
                // the machine used to collapse into one -- a dictation that inserted text and one
                // that inserted nothing.
                notch.apply(state)
                // And the panel, which is what Louis sees when the display he is working on has
                // no cutout for the line above to grow. It is not an alternative wired by a
                // setting: both are driven, and each draws only on the kind of display it is for,
                // so plugging a monitor in mid-session needs nothing switched.
                statusPanel.apply(state)
                // And the surface that waits. Driven from the same state changes as the other
                // two so there is one source of truth, but it is the only one that outlives the
                // dictation: `FailureSurface.standing` says which of a paste failure, an alert
                // and a clipboard loss gets it, and `ProblemPanelController` keeps a dismissal.
                //
                // `clipboardWarning` is read here rather than passed in because it is set on a
                // main-actor `Task` that `PasteInserter` enqueues BEFORE the throw that produces
                // this `.failed` -- so it has already run by the time this line does. If that
                // ordering ever changed, the clipboard note would arrive one state change late,
                // which is a missing second line and never a missing offer.
                problemPanel.show(FailureSurface.standing(
                    state: state, alert: appState.alert,
                    clipboardWarning: appState.clipboardWarning))
            }
        }

        // Task 4 deliberately shipped `register` WITHOUT `@discardableResult`. A ⌥Space that
        // another app already owns leaves Murmure with no way to start a dictation at all, so the
        // failure has to reach the only surface lot 1 has.
        let registered = hotkeys.register(.defaultToggle) { [session] in
            Task { await session.toggle() }
        }
        if !registered {
            log.error("⌥Space registration refused -- another application owns the combination")
            appState.hotkeyUnavailable = true
            appState.status = .failed
        }

        // Whatever is already wrong at launch, put on screen now rather than at the first
        // dictation. For the hotkey that is the ONLY chance: without ⌥Space no dictation can
        // start, so no phase can ever arrive and no transient surface would ever appear to say
        // why. `MurmureApp` has already asked for Accessibility by this point and stored the
        // answer, so both flags are settled.
        //
        // Two surfaces, two lifetimes, and both are wanted. The notch or the strip flashes it so
        // it is NOTICED -- a menu-bar app has no window Louis is looking at -- and the standing
        // panel keeps it, with the System Settings button for the one alert that has somewhere to
        // go. `NotchController.raise` and `StatusPanelController.raise` each draw only on the kind
        // of display they are for, so this shows once, not twice.
        //
        // Deferred by one main-actor turn rather than done inline. This init runs inside
        // `MurmureApp.init`, i.e. before SwiftUI has finished bringing the application up, and
        // two of the three lines below put a window on screen (`StatusPanelController` makes an
        // `NSPanel` synchronously; `ProblemPanelController` the same). Ordering a window in from
        // inside an `App`'s initialiser is not something this task can verify, and a hop costs
        // nothing here -- the alert is about a permission, not about a dictation in flight.
        if let alert = appState.alert {
            Task { @MainActor in
                notch.raise(alert)
                statusPanel.raise(alert)
                problemPanel.show(.alert(alert))
            }
        }

        // The menu has to be able to list the modes before the first dictation ever resolves one.
        refreshModes()
    }

    /// Re-reads `modes/` into the list the menu draws, so a mode file added, renamed or deleted by
    /// hand is offered without restarting Murmure.
    ///
    /// Deliberately does NOT touch `appState.modeProblems`. That list is owned by the resolution
    /// of a dictation, and a mode chosen then deleted is reported there by `ModeSelection` and
    /// nowhere else: overwriting it here -- from the very act of opening the menu to read it --
    /// would erase the explanation at the instant it is being looked at. A broken file's own
    /// problem still reaches the menu, on the next dictation, which is when it starts to matter.
    func refreshModes() {
        guard let modesDirectory else { return }
        appState.availableModes = ModeStore(directory: modesDirectory) { [log] problem in
            log.error("mode file problem: \(problem.description, privacy: .public)")
        }.loadAll()
    }

    /// Menu action: paste the last transcript again — after an insertion failure, or into a second
    /// app. Reuses the session's own inserter; a second `PasteInserter` would be a second
    /// clipboard-outcome consumer.
    func repasteLast() {
        Task {
            guard let text = await session.lastTranscript else {
                log.notice("re-paste requested but the last dictation produced no text")
                return
            }
            await Self.repaste(text, inserter: inserter, appState: appState, log: log)
        }
    }

    /// Menu action: put the last transcript on the clipboard.
    ///
    /// The standing panel's Copy button reaches the same `PasteInserter.copyToClipboard`, and this
    /// item is deliberately its fallback rather than a duplicate feature. Whether a click on a
    /// panel that can never become key reaches a SwiftUI button is AppKit behaviour on real
    /// hardware that no test here can settle, and the one outcome T6 exists to prevent is a
    /// transcript with no way out. A menu item is a route that is known to work.
    func copyLast() {
        Task {
            guard let text = await session.lastTranscript else {
                log.notice("copy requested but the last dictation produced no text")
                return
            }
            PasteInserter.copyToClipboard(text)
        }
    }

    /// Puts this text into the frontmost application, and says so when it cannot.
    ///
    /// The one implementation behind both re-paste routes -- the menu item above and the standing
    /// panel's button -- and a `static` for a reason rather than for tidiness: the panel is built
    /// before `self` is complete, so its closure cannot capture the controller. What it captures
    /// instead is the same `inserter`, which is the invariant that matters (one
    /// clipboard-restore consumer, `PasteInserter.onClipboardOutcome`).
    ///
    /// A re-paste is itself an insertion and fails for the same reasons. Swallowing it would make
    /// the control look like it did nothing for no stated reason -- and after an Accessibility
    /// revocation, that is exactly what would happen twice in a row.
    @MainActor
    private static func repaste(
        _ text: String, inserter: PasteInserter, appState: AppState, log: Logger
    ) async {
        do {
            try await inserter.insert(text)
        } catch {
            log.error("re-paste failed: \(error.localizedDescription, privacy: .public)")
            appState.lastFailureMessage = MenuText.repasteFailed(error.localizedDescription)
            appState.status = .failed
        }
    }
}

/// The app's `DictationRecording`: the frontmost application on one side, `murmure.sqlite` on the
/// other.
///
/// Thin on purpose, like `ModeAwareRefinement` below it and for the same reason -- the app target
/// has no test bundle, so everything decided here would be verified by reading. What is left is
/// the two things `MurmureCore` cannot do: read the desktop, and write to the real database. The
/// row itself is built in `DictationSession`, where it is tested.
private struct DictationArchive: DictationRecording {
    /// Nil when the database could not be opened; see `DictationController.init`. A dictation
    /// still runs, and still pastes -- it is simply not remembered.
    let store: HistoryStore?
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "history")

    init(store: HistoryStore?) {
        self.store = store
    }

    /// On the main actor because `NSWorkspace` is read there, the same hop
    /// `ModeAwareRefinement.modeForNewDictation()` makes -- and for the same reason it reads the
    /// same thing at the same moment: Murmure is `LSUIElement` and the hotkey is a Carbon one, so
    /// pressing it does not bring Murmure forward. What this reads is still Louis's editor.
    ///
    /// The two reads are deliberately not shared. They answer different questions -- which mode
    /// to use, and what to write in the row -- and the day one of them moves, the other must not
    /// move with it by accident.
    /// `isSelf` is answered by comparing PROCESS IDENTIFIERS, which is `PasteInserter`'s own test
    /// for the same question (`frontmostTarget()`) and is used here for its reasons: a bundle
    /// identifier can be absent, and a second copy of Murmure running from another build shares
    /// it. This is the one fact about the desktop `MurmureCore` cannot work out for itself, which
    /// is why the guard that reads it lives in the session and the answer is computed here.
    func targetForNewDictation() async -> DictationTarget {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
            return DictationTarget(
                bundleID: app.bundleIdentifier, name: app.localizedName,
                isSelf: app.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        }
    }

    /// A row that cannot be written is logged and nothing more. The alternative -- surfacing it --
    /// would put an error on screen at the end of a dictation that otherwise worked perfectly,
    /// about an archive Louis was not thinking about.
    func record(_ dictation: HistoryRecord) async {
        guard let store else { return }
        do {
            try store.insert(dictation)
        } catch {
            log.error("history row not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The app's `DictationRefining`: the modes folder on one side, `AppState` on the other.
///
/// Everything it decides is decided in `MurmureCore` -- `ModeSelection.resolve` picks the mode,
/// `TranscriptRefiner.refine` decides what to insert, `OllamaChat` reads the answer. What is left
/// here is the three things the package cannot test: the frontmost application, the real modes
/// folder, and the hop to `AppState`. That is why this type is verified by reading and by
/// compiling, and why none of the logic above lives in it.
///
/// `ModeStore` and `TranscriptRefiner` are built per call rather than stored, because each is a
/// value carrying a non-`Sendable` `report` closure. Building them costs nothing, and it is what
/// lets each resolution collect its own problems instead of appending to a list that only grows.
private struct ModeAwareRefinement: DictationRefining {
    /// Nil when Application Support could not be reached; see `DictationController.init`.
    let modesDirectory: URL?
    let appState: AppState
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "modes")

    init(modesDirectory: URL?, appState: AppState) {
        self.modesDirectory = modesDirectory
        self.appState = appState
    }

    func modeForNewDictation() async -> Mode {
        guard let modesDirectory else { return .voice }

        var problems: [String] = []
        let modes = ModeStore(directory: modesDirectory) { problems.append($0.description) }
            .loadAll()

        // Both sampled here, on the main actor, because this runs on the toggle that STARTS the
        // recording (`DictationSession`, R-T5-2): the frontmost application is the one Louis was
        // looking at when he pressed, and the ticked menu item is the one that was ticked then.
        // Murmure is `LSUIElement` and the hotkey is a Carbon one, so pressing it does not bring
        // Murmure forward -- what this reads is still his editor.
        let (manualKey, frontmost) = await MainActor.run {
            (appState.manualModeKey, NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }

        // Rule 1 of spec §5: what he ticked in the menu, and nil when he ticked "Automatique" --
        // which is the whole of lot 2's behaviour, and what Murmure ships doing.
        let mode = ModeSelection.resolve(
            among: modes, manualKey: manualKey, frontmostBundleID: frontmost
        ) { problems.append($0.description) }

        log.info("""
            mode \(mode.key, privacy: .public) for \
            \(frontmost ?? "no frontmost app", privacy: .public)
            """)
        for problem in problems {
            log.error("mode problem: \(problem, privacy: .public)")
        }
        // Replaced, not appended: the list is what is wrong *now*, so a file Louis has fixed
        // stops being listed on the next dictation.
        let resolved = problems
        await MainActor.run {
            appState.modeProblems = resolved
            // The menu is drawn from these two while the recording runs. `activeMode` is what
            // answers "does what I am saying go to the LLM": with "Automatique" ticked, the
            // checkmark cannot say. `availableModes` is refreshed from the same read that just
            // happened rather than left for the next menu opening -- it costs nothing here.
            appState.availableModes = modes
            appState.activeMode = mode
        }
        return mode
    }

    func refine(_ transcript: String, with mode: Mode) async -> String {
        // The failure is carried by `refine`'s return value and turned into a `RefinementNotice`
        // below, so `onFailure` is the log's copy only -- reporting it to `AppState` here as well
        // would put the same failure on screen twice, once of the two without saying what was
        // inserted in its place.
        let client = OllamaClient { [log] failure in
            log.error("refinement failed: \(failure.description, privacy: .public)")
        }
        let refiner = TranscriptRefiner(client: client) { [appState] notice in
            Task { @MainActor in appState.noteRefinement(notice) }
        }
        return await refiner.refine(transcript, with: mode)
    }
}
