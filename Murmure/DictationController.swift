import AppKit
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
        let notch = NotchController(levels: levels)
        self.notch = notch

        // A local for the same reason `notch` is one: the state-change closure below captures
        // these directly, so it never has to reach back through `self`.
        let statusPanel = StatusPanelController(levels: levels)
        self.statusPanel = statusPanel

        // Task 6 made `onClipboardOutcome` a REQUIRED init parameter with no default, precisely so
        // this line cannot forget to decide. `PasteInserter()` no longer compiles.
        let inserter = PasteInserter { outcome in
            Task { @MainActor in appState.noteClipboard(outcome) }
        }
        self.inserter = inserter

        // `modes/`, never the `Murmure/` folder above it: `recordings/` and the Whisper models
        // are its siblings. Nil when Application Support cannot be reached at all -- dictation
        // then runs on the built-in `Voice`, which is the right answer rather than a failure:
        // Louis can still dictate, and only the modes he edited are missing.
        let modesDirectory: URL?
        do {
            modesDirectory = try Storage.appSupportDirectory(subfolder: "modes")
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

        session = DictationSession(
            recorder: AudioRecorder(levels: levels),
            transcriber: WhisperKitEngine(progress: transcriptionProgress),
            inserter: inserter,
            refiner: ModeAwareRefinement(modesDirectory: modesDirectory, appState: appState)
        ) { state in
            Task { @MainActor in
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
            do {
                try await inserter.insert(text)
            } catch {
                // A re-paste is itself an insertion and fails for the same reasons. Swallowing it
                // would make the menu item look like it did nothing for no stated reason.
                log.error("re-paste failed: \(error.localizedDescription, privacy: .public)")
                appState.lastFailureMessage = "Recollage échoué : \(error.localizedDescription)"
                appState.status = .failed
            }
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
