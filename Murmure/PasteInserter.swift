import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "insert")

/// Why an insertion could not even be attempted. Every case is thrown BEFORE the clipboard is
/// touched, so the user's clipboard is intact and the transcript is still held by the caller
/// (spec §9: a paste failure keeps the text recoverable, it never loses it).
enum InsertError: LocalizedError, Equatable {
    case accessibilityDenied
    case noFrontmostApplication
    case frontmostApplicationIsMurmure
    case eventCreationFailed
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Murmure needs Accessibility permission to paste into other apps."
        case .noFrontmostApplication:
            "No app is in front to paste into."
        case .frontmostApplicationIsMurmure:
            "Murmure itself is in front -- click into the app you want the text in."
        case .eventCreationFailed:
            "The system refused to create the paste keystroke."
        case .pasteboardWriteFailed:
            "The clipboard refused the transcript."
        }
    }
}

/// Inserts text into the frontmost app the way a human would: put it on the clipboard,
/// press ⌘V, put the clipboard back.
///
/// The clipboard is borrowed, not taken. `PasteboardSnapshot` keeps every item and every
/// representation, and the hand-back is guarded by the pasteboard's generation counter so a
/// copy the user makes mid-paste is never overwritten with stale contents.
///
/// Main-actor isolated: it drives AppKit (`NSPasteboard`, `NSWorkspace`) and there is no reason
/// for it to run anywhere else. A `@MainActor` method still satisfies Task 7's nonisolated
/// `async` `TextInserter` requirement -- verified with the compiler in both Swift 5 and 6 modes.
@MainActor
final class PasteInserter {
    /// How long the target app gets to consume the ⌘V before the clipboard is handed back.
    ///
    /// The two failure modes are not symmetric. Restoring too EARLY means the app pastes the
    /// user's old clipboard instead of the dictation -- wrong text, silently. Restoring too
    /// LATE only means the old clipboard comes back a moment later, and the generation-counter
    /// guard covers the case where the user copied something in between. So this errs long.
    private static let pasteWindow: Duration = .milliseconds(300)

    /// `kVK_ANSI_V` is a physical key position, not a character. Measured on this machine's
    /// actual layout (French AZERTY): position 9 still produces "v", so ⌘V is the right chord.
    /// A layout that moves V (Dvorak) would need the key code derived through `UCKeyTranslate`.
    private static let virtualKeyV = CGKeyCode(kVK_ANSI_V)

    func insert(_ text: String) async throws {
        // An empty transcript is a real outcome, not an error (ruling L11: WhisperKit returns
        // empty even for real speech). Pasting nothing would still clear and rewrite the
        // clipboard for no reason.
        guard !text.isEmpty else {
            logger.info("insert skipped -- empty transcript")
            return
        }
        // Checked first, and before the clipboard is touched: without this permission
        // `CGEvent.post` does exactly nothing and reports nothing -- the silent failure this
        // whole class exists to avoid.
        guard AXIsProcessTrusted() else { throw InsertError.accessibilityDenied }
        let target = try Self.frontmostTarget()
        let (keyDown, keyUp) = try Self.makePasteEvents()

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        if !snapshot.droppedTypes.isEmpty {
            logger.warning(
                "clipboard captured incompletely -- unreadable types: \(snapshot.droppedTypes.map(\.rawValue), privacy: .public)"
            )
        }

        // `clearContents()` is the only call that bumps the generation counter, and it returns
        // the new value: that is the number the restore is checked against.
        let ourGeneration = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard, ifChangeCountIs: ourGeneration)
            throw InsertError.pasteboardWriteFailed
        }

        logger.info("pasting \(text.count) characters into \(target.localizedName ?? "?", privacy: .public)")
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        do {
            try await Task.sleep(for: Self.pasteWindow)
        } catch {
            // Cancellation must not leave the transcript sitting on the user's clipboard;
            // hand it back immediately instead.
            logger.notice("paste window interrupted -- restoring the clipboard now")
        }

        switch snapshot.restore(to: pasteboard, ifChangeCountIs: ourGeneration) {
        case .restored:
            logger.debug("clipboard restored")
        case .declinedPasteboardChanged:
            // Someone copied during the paste window. Their clipboard is newer than the one we
            // saved, so it wins -- the pre-dictation contents are deliberately not brought back.
            logger.notice("clipboard changed during the paste window -- newer contents kept")
        case .writeFailed:
            logger.error("clipboard could NOT be restored -- it still holds the dictated text")
        }
    }

    /// Prompts for Accessibility permission if it has not been granted. Returns whether the
    /// process is trusted, so the caller can say something rather than fail silently later.
    static func requestAccessibilityIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The app the keystroke will land in. This is a proxy for keyboard focus, and an honest
    /// one only up to a point: it catches "nothing is in front" and "we are in front, so the
    /// paste would go nowhere", but an app in front with no editable field focused swallows
    /// the ⌘V and there is no API that reports it. That residual case is why the caller keeps
    /// the transcript.
    private static func frontmostTarget() throws -> NSRunningApplication {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw InsertError.noFrontmostApplication
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw InsertError.frontmostApplicationIsMurmure
        }
        return app
    }

    private static func makePasteEvents() throws -> (down: CGEvent, up: CGEvent) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else {
            throw InsertError.eventCreationFailed
        }
        // Assigning the flags REPLACES them rather than adding to whatever the user is
        // physically holding, so a held ⌥ or ⇧ cannot turn ⌘V into a different shortcut.
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Posting a synthetic event otherwise suppresses real hardware events for a moment,
        // which would eat the keystrokes the user types right after the paste.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return (down, up)
    }
}
