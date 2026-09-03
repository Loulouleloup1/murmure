import XCTest
@testable import MurmureCore

/// A fresh install behaves the way the app behaved before there were settings, and every answer
/// survives being written.
final class AppSettingsTests: XCTestCase {
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

    // MARK: - A fresh install

    /// The one that matters most, and the reason the booleans do not go through
    /// `defaults.bool(forKey:)` alone: it answers `false` for a key nobody wrote, which would ship
    /// both sounds off and the clipboard restore off on a machine that has never opened Settings.
    func testAnEmptyDomainReadsAsTheDefaults() {
        // Given -- nothing has ever been written
        let settings = AppSettings(defaults: defaults)

        // Then
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.isSoundEnabled(.recordingStarted))
        XCTAssertTrue(settings.isSoundEnabled(.textInserted))
        XCTAssertEqual(settings.pasteBehaviour, .pasteIntoFrontmostApp)
        XCTAssertTrue(settings.restoreClipboardAfterPaste)
    }

    /// Every default is the behaviour the app already had before this file existed. Stated as its
    /// own test because "the defaults are these values" and "the defaults change nothing" are two
    /// different claims, and only the second one is the promise.
    func testTheDefaultsAreWhatTheAppAlreadyDoes() {
        let settings = AppSettings(defaults: defaults)

        // `PasteInserter` pastes into the frontmost app and hands the clipboard back.
        XCTAssertTrue(settings.willRestoreClipboard)
        // Lot 3 T11 shipped both cues audible.
        XCTAssertTrue(FeedbackCue.allCases.allSatisfy(settings.isSoundEnabled))
    }

    // MARK: - Round trips

    func testEveryToggleReadsBackWhatWasWritten() {
        // Given
        let settings = AppSettings(defaults: defaults)

        // When
        settings.launchAtLogin = true
        settings.restoreClipboardAfterPaste = false
        settings.pasteBehaviour = .copyToClipboardOnly
        settings.setSoundEnabled(false, for: .textInserted)

        // Then -- read through a SECOND instance, so this is the stored value and not a cached one
        let reread = AppSettings(defaults: defaults)
        XCTAssertTrue(reread.launchAtLogin)
        XCTAssertFalse(reread.restoreClipboardAfterPaste)
        XCTAssertEqual(reread.pasteBehaviour, .copyToClipboardOnly)
        XCTAssertFalse(reread.isSoundEnabled(.textInserted))
    }

    /// Turning something off and back on lands on the default rather than somewhere near it. The
    /// failure this catches is a setter that stores "off" as a removal: the value would then read
    /// back as the default, which is `true` for this one, so the toggle would refuse to turn off.
    func testATogglePutBackWhereItStartedIsWhereItStarted() {
        let settings = AppSettings(defaults: defaults)

        settings.restoreClipboardAfterPaste = false
        XCTAssertFalse(settings.restoreClipboardAfterPaste)

        settings.restoreClipboardAfterPaste = true
        XCTAssertTrue(settings.restoreClipboardAfterPaste)
    }

    /// The two cues have their own storage. The bug this exists for is one key serving both,
    /// which looks exactly like the toggle working -- until the other sound goes quiet too.
    func testTheTwoSoundsSwitchIndependently() {
        // Given
        let settings = AppSettings(defaults: defaults)

        // When
        settings.setSoundEnabled(false, for: .recordingStarted)

        // Then
        XCTAssertFalse(settings.isSoundEnabled(.recordingStarted))
        XCTAssertTrue(settings.isSoundEnabled(.textInserted))
    }

    // The microphone section is gone with the setting it covered. `AudioRecorder` opens
    // `engine.inputNode` and nothing else, so a stored device was written and read back correctly
    // and changed nothing about which microphone recorded -- the General pane now REPORTS the
    // system input instead of offering it (`MicrophoneStatus`, tested beside this file), and the
    // stored value went with the picker.

    // MARK: - Paste behaviour

    /// A hand-edited domain, or -- the real one -- a case renamed in a later lot. Degrading to
    /// pasting means an app that still inserts text; refusing would mean an app that inserts
    /// nowhere and says nothing about why.
    func testAnUnrecognisedPasteBehaviourReadsAsPasting() {
        // Given
        defaults.set("teleport", forKey: "pasteBehaviour")

        // Then
        XCTAssertEqual(AppSettings(defaults: defaults).pasteBehaviour, .pasteIntoFrontmostApp)
    }

    /// The scoping rule, and the only place the stored toggle and the actual behaviour differ:
    /// under copy-only the transcript on the clipboard IS the delivery, so handing the clipboard
    /// back would erase the dictation a moment after producing it.
    func testCopyOnlyNeverRestoresTheClipboardHoweverTheToggleIsSet() {
        // Given
        let settings = AppSettings(defaults: defaults)
        settings.pasteBehaviour = .copyToClipboardOnly

        // When -- the toggle says restore, which is also its default
        settings.restoreClipboardAfterPaste = true

        // Then
        XCTAssertTrue(settings.restoreClipboardAfterPaste)
        XCTAssertFalse(settings.willRestoreClipboard)
    }

    func testPastingRestoresTheClipboardWhenTheToggleSaysSo() {
        // Given
        let settings = AppSettings(defaults: defaults)
        settings.pasteBehaviour = .pasteIntoFrontmostApp

        // Then
        XCTAssertTrue(settings.willRestoreClipboard)

        // When
        settings.restoreClipboardAfterPaste = false

        // Then
        XCTAssertFalse(settings.willRestoreClipboard)
    }
}
