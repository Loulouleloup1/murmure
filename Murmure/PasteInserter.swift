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
/// Whether the hand-back actually succeeded is reported to the caller through
/// ``onClipboardOutcome``, because `insert(_:)` can succeed at pasting and still have destroyed
/// the clipboard, and only the caller can offer the user anything about it.
///
/// Main-actor isolated: it drives AppKit (`NSPasteboard`, `NSWorkspace`) and there is no reason
/// for it to run anywhere else. A `@MainActor` method still satisfies Task 7's nonisolated
/// `async` `TextInserter` requirement -- verified with the compiler in both Swift 5 and 6 modes.
@MainActor
final class PasteInserter {
    /// What happened to the user's clipboard once the insertion was over, handed to whoever
    /// constructed the inserter.
    ///
    /// Required, with no default and no `@discardableResult` escape hatch: `.writeFailed` and a
    /// `.restoredPartially` with everything lost both mean the user's pre-dictation clipboard is
    /// permanently gone, and `insert(_:)` returns `Void` because task 7's `TextInserter`
    /// requirement does. Logging it and returning nothing is the "failure mechanism with no
    /// consumer" shape ruling L7 keeps catching -- so the compiler makes every construction site
    /// decide. A call site that genuinely does not care writes `{ _ in }` and means it.
    private let onClipboardOutcome: (PasteboardSnapshot.RestoreOutcome) -> Void

    init(onClipboardOutcome: @escaping (PasteboardSnapshot.RestoreOutcome) -> Void) {
        self.onClipboardOutcome = onClipboardOutcome
    }

    /// How long the target app gets to consume the ⌘V before the clipboard is handed back.
    ///
    /// The two failure modes are not symmetric. Restoring too EARLY means the app pastes the
    /// user's old clipboard instead of the dictation -- wrong text, silently. Restoring too
    /// LATE only means the old clipboard comes back a moment later, and the generation-counter
    /// guard covers the case where the user copied something in between. So this errs long.
    private static let pasteWindow: Duration = .milliseconds(300)

    /// `kVK_ANSI_V` is a virtual key code -- a physical key POSITION. That much is
    /// layout-independent by construction and needed no checking. What did need checking is the
    /// other half: a menu shortcut is matched against the CHARACTER the active layout produces,
    /// so ⌘ + position 9 is only Paste if position 9 still means "v" there. Measured against the
    /// live input source (`TISCopyCurrentKeyboardLayoutInputSource` reports French, AZERTY) with
    /// `UCKeyTranslate`: position 9 produces "v", so this is the right chord on Louis's keyboard.
    /// A layout that moves V (Dvorak) would need the key code derived at runtime instead.
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

        // The whole capture/clear/write sequence belongs to `PasteboardSnapshot.borrow`, not here:
        // assembled by hand it leaves a gap between the capture and the clear in which a third
        // party's fresh copy is destroyed and then papered over with a `.restored`. The core owns
        // it so that gap cannot be reopened by a call site -- and so it can be tested, which a
        // guard living in this method never could be: this one posts a ⌘V.
        let pasteboard = NSPasteboard.general
        let borrowed: PasteboardSnapshot.Borrowed
        switch PasteboardSnapshot.borrow(pasteboard, writing: { $0.setString(text, forType: .string) }) {
        case let .borrowed(handle):
            borrowed = handle
        case let .writeRefused(handedBack, droppedTypes):
            // Same care as the hand-back below: the clipboard's fate is reported even on the
            // throwing path, where the user loses both the dictation and possibly the clipboard.
            warnAboutUnreadableTypes(droppedTypes)
            report(handedBack, from: .writeRefused)
            throw InsertError.pasteboardWriteFailed
        }
        // Logged HERE, and not a line earlier. This warning used to sit between the capture and
        // the `clearContents()`, i.e. inside the window the borrow now closes -- a `logger` call
        // in there widens it for nothing.
        warnAboutUnreadableTypes(borrowed.droppedTypes)

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

        report(borrowed.handBack(), from: .pasteWindow)
    }

    /// Which hand-back is being reported. `.declinedPasteboardChanged` is the same fact told from
    /// two very different places -- after a paste, and after a write the pasteboard refused before
    /// any ⌘V was posted -- and one message for both described a paste window that had not opened.
    private enum HandBack {
        case pasteWindow
        case writeRefused
    }

    /// Says out loud what happened to the user's clipboard, and tells the caller.
    private func report(_ outcome: PasteboardSnapshot.RestoreOutcome, from handBack: HandBack) {
        switch outcome {
        case .restored:
            logger.debug("clipboard restored")
        case let .restoredPartially(lost, captured, _) where lost > 0 && lost == captured:
            logger.error(
                "clipboard NOT restored -- all \(captured, privacy: .public) copied item(s) were promises nobody could materialise and are gone"
            )
        case let .restoredPartially(lost, captured, _) where lost > 0:
            logger.error(
                "clipboard restored only in part -- \(lost, privacy: .public) of \(captured, privacy: .public) copied items could not be rebuilt and are gone"
            )
        case let .restoredPartially(_, _, types):
            // Every item is back, but not everything they held: styled text returning as bare
            // characters is a loss the user can see, so it is not a `.restored`.
            logger.error(
                "clipboard restored without \(types.map(\.rawValue), privacy: .public) -- the items are back, that content is gone"
            )
        case .declinedPasteboardChanged:
            switch handBack {
            case .pasteWindow:
                // Someone copied during the paste window. Their clipboard is newer than the one we
                // saved, so it wins -- the pre-dictation contents are deliberately not brought back.
                logger.notice("clipboard changed during the paste window -- newer contents kept")
            case .writeRefused:
                // Nothing was pasted and no ⌘V was posted: the pasteboard refused the transcript
                // because someone else took ownership of it first. Their copy is on it, intact.
                logger.notice(
                    "clipboard refused the transcript -- someone else copied first, their contents are kept"
                )
            }
        case .writeFailed:
            logger.error("clipboard could NOT be restored -- it still holds the dictated text")
        }
        onClipboardOutcome(outcome)
    }

    private func warnAboutUnreadableTypes(_ types: [NSPasteboard.PasteboardType]) {
        guard !types.isEmpty else { return }
        logger.warning(
            "clipboard captured incompletely -- unreadable types: \(types.map(\.rawValue), privacy: .public)"
        )
    }

    /// Puts text on the clipboard and leaves it there.
    ///
    /// **The one write in Murmure that does not borrow.** `insert(_:)` goes through
    /// `PasteboardSnapshot.borrow` and hands the clipboard back 300 ms later, because the user did
    /// not ask for their clipboard to be touched. This is the user asking: it is what the standing
    /// panel's Copy button and the menu item behind it do, and a copy that undid itself would be a
    /// Copy that does not copy.
    ///
    /// It exists because it is the recovery that survives a denied Accessibility. Without that
    /// permission `CGEvent.post` does nothing at all, so re-pasting cannot work and the clipboard
    /// is the only way the transcript leaves Murmure.
    ///
    /// Returns whether the pasteboard accepted it. False means someone else took ownership between
    /// the two calls and the transcript is NOT on the clipboard -- which matters more here than
    /// anywhere, because the next thing the user does is press ⌘V.
    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            logger.error("copy refused by the pasteboard -- the transcript is NOT on the clipboard")
            return false
        }
        logger.info("transcript copied (\(text.count, privacy: .public) characters)")
        return true
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

/// `@MainActor` isolation satisfies the nonisolated `async` requirement, as noted on the class.
extension PasteInserter: TextInserter {}
