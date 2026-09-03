import AppKit
import XCTest
@testable import MurmureCore

/// The Advanced pane's two rows, and what they actually do to a clipboard.
///
/// **Half of this file asserts on a real `NSPasteboard`, and that is the point.** A test reading
/// `XCTAssertFalse(settings.restoreClipboardAfterPaste)` proves the switch stores a boolean and
/// nothing about whether any clipboard is ever handed back — which is exactly the shape of bug
/// this lot has been finding. So the cases below borrow a pasteboard, apply the plan, and look at
/// what is on it afterwards.
///
/// A **private** pasteboard per case, never `.general`: the general one belongs to Louis, who is
/// working, and a test that borrows it destroys whatever he last copied.
final class InsertionPlanTests: XCTestCase {
    /// In memory, never a `UserDefaults(suiteName:)`. The suite-per-test pattern this file used
    /// to carry could not be cleaned up: `cfprefsd` owns the domain and flushes an empty plist
    /// back into `~/Library/Preferences` after the `tearDown` has deleted it, which is why 31 of
    /// them were found in Louis's home directory. `EphemeralDefaults` removes the domain from the
    /// picture rather than racing it, so there is nothing to tear down.
    private var defaults: EphemeralDefaults!

    /// Nothing to tear down, which is the point: `EphemeralDefaults` registers no domain, so
    /// there is no plist for `cfprefsd` to flush back into Louis's home directory afterwards.
    override func setUpWithError() throws {
        defaults = EphemeralDefaults()
    }

    /// A **private** pasteboard per case, never `.general`: the general one belongs to Louis, who
    /// is working, and a test that borrowed it would destroy whatever he last copied.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("murmure-plan-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        return pasteboard
    }

    /// One insertion, carried out the way `PasteInserter` carries it out: borrow the clipboard,
    /// write the transcript, then hand it back **through the plan**. Returns what is on the
    /// clipboard when it is over, which is the only thing worth asserting on.
    private func insert(
        _ transcript: String, over previousClipboard: String, under plan: InsertionPlan
    ) throws -> String? {
        let pasteboard = makePasteboard()
        pasteboard.setString(previousClipboard, forType: .string)

        guard case let .borrowed(handle) = PasteboardSnapshot.borrow(
            pasteboard, writing: { $0.setString(transcript, forType: .string) })
        else {
            XCTFail("the private pasteboard refused the transcript")
            return nil
        }
        // The line the app runs. Not an `if` written here: the branch is the overload's, so this
        // test cannot pass while the app's call site has forgotten it.
        _ = handle.handBack(plan)
        return pasteboard.string(forType: .string)
    }

    // MARK: - Restore clipboard after paste, observed on a clipboard

    /// The default, and the reason it is the default: Louis dictates every few minutes, and a tool
    /// that ate his clipboard each time would be unusable next to any copy-and-paste work.
    func testWithTheSwitchOnTheClipboardComesBack() throws {
        // Given
        let settings = AppSettings(defaults: defaults)  // restoreClipboardAfterPaste defaults true

        // When
        let after = try insert(
            "le transcript dicté", over: "ce que Louis avait copié",
            under: InsertionPlan(settings))

        // Then
        XCTAssertEqual(after, "ce que Louis avait copié")
    }

    /// **The behaviour test the switch exists for.** Turning it off is a real request and not a
    /// degradation: it leaves the transcript on the clipboard, which is what someone who wants to
    /// paste it a second time somewhere else actually wants.
    func testWithTheSwitchOffTheTranscriptStaysOnTheClipboard() throws {
        // Given
        let settings = AppSettings(defaults: defaults)
        settings.restoreClipboardAfterPaste = false

        // When
        let after = try insert(
            "le transcript dicté", over: "ce que Louis avait copié",
            under: InsertionPlan(settings))

        // Then
        XCTAssertEqual(after, "le transcript dicté")
    }

    /// Under copy-only the transcript on the clipboard IS the delivery, so a hand-back would erase
    /// the only copy of the dictation a moment after producing it. The switch says "restore" and
    /// is deliberately overruled — which is why the pane disables the row rather than letting it
    /// read as a promise it cannot keep.
    func testCopyOnlyKeepsTheTranscriptEvenWithTheRestoreSwitchOn() throws {
        // Given -- restore is ON, which is the default, and copy-only is chosen
        let settings = AppSettings(defaults: defaults)
        settings.pasteBehaviour = .copyToClipboardOnly
        XCTAssertTrue(settings.restoreClipboardAfterPaste)

        // When
        let after = try insert(
            "le transcript dicté", over: "ce que Louis avait copié",
            under: InsertionPlan(settings))

        // Then
        XCTAssertEqual(after, "le transcript dicté")
    }

    /// A hand-back that did not happen is **not** a clipboard failure to report. Louis ticked the
    /// box; `PasteInserter.onClipboardOutcome` feeds `AppState.clipboardWarning`, and a notice
    /// after every dictation about a setting he chose is the notice he stops reading.
    func testAHandBackThatWasNotAskedForReportsNoOutcomeAtAll() throws {
        // Given
        let pasteboard = makePasteboard()
        pasteboard.setString("ce que Louis avait copié", forType: .string)
        guard case let .borrowed(handle) = PasteboardSnapshot.borrow(
            pasteboard, writing: { $0.setString("le transcript", forType: .string) })
        else { return XCTFail("the private pasteboard refused the transcript") }

        // When
        let outcome = handle.handBack(
            InsertionPlan(pastesIntoFrontmostApp: true, handsClipboardBack: false))

        // Then
        XCTAssertNil(outcome)
    }

    /// And a hand-back that WAS asked for still reports, because that is the path on which the
    /// user's clipboard can be lost for real.
    func testAHandBackThatWasAskedForStillReportsWhatHappened() throws {
        // Given
        let pasteboard = makePasteboard()
        pasteboard.setString("ce que Louis avait copié", forType: .string)
        guard case let .borrowed(handle) = PasteboardSnapshot.borrow(
            pasteboard, writing: { $0.setString("le transcript", forType: .string) })
        else { return XCTFail("the private pasteboard refused the transcript") }

        // When
        let outcome = handle.handBack(
            InsertionPlan(pastesIntoFrontmostApp: true, handsClipboardBack: true))

        // Then
        XCTAssertEqual(outcome, .restored)
    }

    // MARK: - Paste behaviour

    /// The shipped answer, and what every other part of the app is written around.
    func testTheDefaultPlanPastesAndRestores() {
        let plan = InsertionPlan(AppSettings(defaults: defaults))
        XCTAssertTrue(plan.pastesIntoFrontmostApp)
        XCTAssertTrue(plan.handsClipboardBack)
    }

    /// Copy-only posts no keystroke, which is the half of it that matters most: it is the only
    /// behaviour that needs no Accessibility permission at all.
    func testCopyOnlyPostsNoKeystroke() {
        let settings = AppSettings(defaults: defaults)
        settings.pasteBehaviour = .copyToClipboardOnly

        let plan = InsertionPlan(settings)

        XCTAssertFalse(plan.pastesIntoFrontmostApp)
        XCTAssertFalse(plan.handsClipboardBack)
    }

    /// Pasting with the restore turned off — the fourth corner of the two switches, and the one
    /// that is neither a default nor a special case.
    func testPastingWithRestoreOffPastesAndKeeps() {
        let settings = AppSettings(defaults: defaults)
        settings.restoreClipboardAfterPaste = false

        let plan = InsertionPlan(settings)

        XCTAssertTrue(plan.pastesIntoFrontmostApp)
        XCTAssertFalse(plan.handsClipboardBack)
    }

    /// The plan is read ONCE per insertion, which is why it is a value and not a settings
    /// reference: `PasteInserter` decides on the keystroke at the top of `insert` and on the
    /// hand-back 300 ms later, and a toggle flipped across that gap must not produce a dictation
    /// that pasted and never gave the clipboard back.
    func testAPlanDoesNotChangeUnderASettingFlippedAfterItWasRead() {
        // Given
        let settings = AppSettings(defaults: defaults)
        let plan = InsertionPlan(settings)

        // When
        settings.restoreClipboardAfterPaste = false

        // Then
        XCTAssertTrue(plan.handsClipboardBack)
        XCTAssertNotEqual(plan, InsertionPlan(settings))
    }
}
