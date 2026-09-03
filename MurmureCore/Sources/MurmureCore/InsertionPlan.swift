import AppKit

/// What one insertion is going to do, read off the Advanced pane's two rows.
///
/// **Two booleans rather than the settings object, because the two questions are asked at
/// different moments and both have to be answered from one reading.** `PasteInserter.insert`
/// decides whether to post ⌘V near the top and whether to hand the clipboard back 300 ms later;
/// consulting `AppSettings` twice across that gap would let a toggle flipped in between produce a
/// dictation that pasted and never gave the clipboard back, or one that did neither.
///
/// It exists at all because both mechanisms are already written and were unconditional:
/// `PasteInserter` posted the keystroke and called `handBack()` whatever the settings said. The
/// `if` is here rather than there so that it is a value a test can produce, and so
/// ``PasteboardSnapshot/Borrowed/handBack(_:)`` below can make the hand-back branch structural --
/// the app has no `if` to forget.
public struct InsertionPlan: Equatable, Sendable {
    /// Whether a ⌘V is posted into whatever is in front.
    ///
    /// False under ``PasteBehaviour/copyToClipboardOnly``, which is not a degraded paste: it is
    /// the answer for the applications where a synthetic ⌘V lands in the wrong field, and it is
    /// the only behaviour that needs no Accessibility permission at all.
    public let pastesIntoFrontmostApp: Bool

    /// Whether the clipboard Louis had before the dictation is given back afterwards.
    ///
    /// This is ``AppSettings/willRestoreClipboard`` and deliberately not
    /// ``AppSettings/restoreClipboardAfterPaste``: under `copyToClipboardOnly` the transcript on
    /// the clipboard **is** the delivery, so handing the clipboard back would erase the only copy
    /// of the dictation a moment after producing it.
    public let handsClipboardBack: Bool

    /// The plan for a dictation about to be inserted, read once.
    ///
    /// Written without a `default` in `AppSettings.willRestoreClipboard`, which is what makes a
    /// third paste behaviour answer this question rather than inherit an answer here.
    public init(_ settings: AppSettings) {
        switch settings.pasteBehaviour {
        case .pasteIntoFrontmostApp: pastesIntoFrontmostApp = true
        case .copyToClipboardOnly: pastesIntoFrontmostApp = false
        }
        handsClipboardBack = settings.willRestoreClipboard
    }

    /// A plan stated directly, for a test that is about the plan rather than about the settings
    /// that produced it.
    public init(pastesIntoFrontmostApp: Bool, handsClipboardBack: Bool) {
        self.pastesIntoFrontmostApp = pastesIntoFrontmostApp
        self.handsClipboardBack = handsClipboardBack
    }
}

extension PasteboardSnapshot.Borrowed {
    /// Hands the clipboard back, or deliberately keeps the transcript on it.
    ///
    /// **The whole point is that this is the overload the app calls, so there is no `if` at the
    /// call site to leave out.** `handBack()` with no argument is unconditional and stays that way
    /// for the tests that are about restoring itself; an inserter reaching for it would be the
    /// clipboard setting quietly doing nothing, which is the failure this lot keeps finding.
    ///
    /// **nil is "kept, because that is what was asked", and it is not an outcome to report.**
    /// `PasteInserter.onClipboardOutcome` exists so a clipboard that was destroyed reaches a
    /// surface; a clipboard holding the transcript on purpose is the feature working, and warning
    /// about it would put a notice on screen after every dictation for a box Louis ticked himself.
    public func handBack(_ plan: InsertionPlan) -> PasteboardSnapshot.RestoreOutcome? {
        guard plan.handsClipboardBack else { return nil }
        return handBack()
    }
}
