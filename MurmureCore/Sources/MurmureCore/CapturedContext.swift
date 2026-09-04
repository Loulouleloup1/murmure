import Foundation

/// What Louis had selected, on his clipboard, and in front of him when a dictation started.
///
/// Captured once, at the moment the recording begins (`DictationSession.toggle()`), and carried
/// through the whole pipeline as a value -- never re-read. That is deliberate: a refinement can
/// run for over a minute (`OllamaChat.timeout`), and by the time it finishes Louis may have
/// switched applications, changed his selection or copied something else. What has to reach the
/// model is what was true when he STARTED speaking, the same rule `DictationTarget` already
/// follows for the frontmost application.
///
/// All three fields are optional, and deliberately not folded into `""` for "nothing there": see
/// ``RefinementRequest``, which treats an absent value and an empty one the same way but needs
/// both shapes to be representable to do it on purpose rather than by accident.
public struct CapturedContext: Equatable, Sendable {
    public var selectedText: String?
    public var clipboard: String?
    public var frontmostAppName: String?

    public init(
        selectedText: String? = nil, clipboard: String? = nil, frontmostAppName: String? = nil
    ) {
        self.selectedText = selectedText
        self.clipboard = clipboard
        self.frontmostAppName = frontmostAppName
    }

    /// Nothing was captured -- every mode whose three toggles are off, and what `DictationSession`
    /// holds before a dictation's capture step has run.
    public static let none = CapturedContext()
}

/// The two sources of context that need AppKit or the Accessibility API to read, neither of which
/// `MurmureCore` imports.
///
/// This lives here rather than as a closure pair for the same reason `RefinementClient` is a
/// protocol and not one: the app target has no test bundle, so `DictationSession`'s use of
/// whatever answers this has to be checkable against a fake, not against the real Accessibility
/// API or the real pasteboard.
///
/// The third source, the frontmost application's name, has no method here on purpose.
/// `DictationSession` already resolves a `DictationTarget` for this same dictation
/// (`DictationRecording/targetForNewDictation()`, read once at the same moment as this), and
/// asking `NSWorkspace` a second time could name a different application from the one the history
/// row records -- the two must never be able to disagree about which app it was.
public protocol ContextCapturing: Sendable {
    /// The focused element's selected text, or nil -- no selection, no focused element,
    /// Accessibility permission not granted, or a selection that reads as empty.
    ///
    /// Never logged, saved, printed or quoted by an implementation: this can be client material.
    func captureSelectedText() async -> String?

    /// The general pasteboard's string contents, or nil -- nothing there, or it is not text.
    ///
    /// Same rule as ``captureSelectedText()``: read, returned, never recorded anywhere else.
    func captureClipboard() async -> String?
}
