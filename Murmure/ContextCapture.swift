import AppKit
import ApplicationServices
import Foundation
import MurmureCore

/// The app's `ContextCapturing`: the Accessibility API on one side, the general pasteboard on the
/// other.
///
/// This lives here rather than in `MurmureCore` for the same reason `OllamaClient` does: both
/// reads need AppKit or `ApplicationServices`, which the package deliberately does not import, and
/// the app target has no test bundle -- so this type is verified by reading and by compiling, and
/// none of the DECISION about what a mode's context looks like lives here (that is
/// `RefinementRequest`, tested in `MurmureCore`).
///
/// **Never logs, saves, prints or quotes what it reads.** A selection or a clipboard can be
/// client material, and this type is a straight read with nowhere for the value to go except the
/// return -- no `Logger` call anywhere in it, on purpose.
struct AppKitContextCapture: ContextCapturing {
    /// The focused element's selected text, via the same Accessibility API `PasteInserter` already
    /// holds permission for (its ⌘V paste). No new prompt: `AXIsProcessTrusted()` reads whatever
    /// was already granted, or refuses this rather than asking again.
    ///
    /// Nil for every one of: permission not granted, no focused element, the focused element does
    /// not expose a selection, or the selection is empty -- `RefinementRequest` treats an empty
    /// string exactly like nil, so collapsing every "nothing usable" case to nil here changes
    /// nothing it reads.
    func captureSelectedText() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        // Force-cast rather than `as?`: `CFGetTypeID` above already confirmed this CFTypeRef IS
        // an `AXUIElement`, so `as?` could only ever succeed too -- this reads as what it is.
        let element = focused as! AXUIElement
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &value
            ) == .success
        else { return nil }
        return value as? String
    }

    /// The general pasteboard's string contents, or nil when there is none -- an image, a file
    /// reference, or nothing at all.
    ///
    /// `NSPasteboard.general` is not a new surface: `PasteInserter` already reads and writes it
    /// on every dictation, borrowing it for the ⌘V and handing it back (`PasteboardSnapshot`).
    /// This is a second, unrelated reader of a pasteboard the app already touches throughout its
    /// own pipeline, not a new capability or a new permission.
    func captureClipboard() async -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
