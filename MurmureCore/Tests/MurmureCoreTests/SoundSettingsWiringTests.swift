import XCTest
@testable import MurmureCore

private final class SpyPlayer: CuePlaying {
    private(set) var played: [FeedbackCue] = []

    func play(_ cue: FeedbackCue) {
        played.append(cue)
    }
}

/// The join between the General pane's two switches and the two sounds — `AppSettings` composed
/// into `CueFeedback`, which is neither type's own subject and is where the bug lives.
///
/// **`CueFeedback.init`'s `isEnabled` defaults to `{ _ in true }`.** That default is right for the
/// sixty call sites that do not care, and it is a trap for the one that does: an app that forgets
/// to pass the settings gets two switches that flip, persist, read back correctly, and change
/// nothing — with no error, no warning and nothing in the log. A settings switch that does nothing
/// is the worst kind, because the only thing that would report it is the sound not happening, and
/// the sound not happening is exactly what the user asked for.
///
/// So every case below builds the composition **the app builds**, `settings.isSoundEnabled`, rather
/// than a closure written for the test. A test with its own `{ _ in false }` would prove that
/// `CueFeedback` can filter and prove nothing about whether the two switches are wired to the
/// filter.
final class SoundSettingsWiringTests: XCTestCase {
    /// In memory, never a `UserDefaults(suiteName:)`. The suite-per-test pattern this file used
    /// to carry could not be cleaned up: `cfprefsd` owns the domain and flushes an empty plist
    /// back into `~/Library/Preferences` after the `tearDown` has deleted it, which is why 31 of
    /// them were found in Louis's home directory. `EphemeralDefaults` removes the domain from the
    /// picture rather than racing it, so there is nothing to tear down.
    private var defaults: EphemeralDefaults!
    private var settings: AppSettings!

    /// Nothing to tear down, which is the point: `EphemeralDefaults` registers no domain, so
    /// there is no plist for `cfprefsd` to flush back into Louis's home directory afterwards.
    override func setUpWithError() throws {
        defaults = EphemeralDefaults()
        settings = AppSettings(defaults: defaults)
    }

    /// The one line the app has to write. Spelled once here so every case below is the same
    /// composition, and so the shape is visible beside the tests that depend on it.
    private func makeFeedback(_ player: SpyPlayer) -> CueFeedback {
        CueFeedback(player: player, isEnabled: settings.isSoundEnabled)
    }

    /// One whole dictation with both switches on — the fresh-install state, and the behaviour
    /// lot 3 T11 shipped. Exactly two sounds, so a filter that silenced everything would not read
    /// as a pass here.
    func testBothSwitchesOnSoundsTwiceForADictationThatDelivered() {
        // Given -- nothing written; both cues default to ON
        let player = SpyPlayer()
        let feedback = makeFeedback(player)

        // When
        for state in [
            DictationSession.State.recording, .transcribing, .refining, .inserting,
            .completed(insertedCharacters: 42), .idle,
        ] {
            feedback.apply(state)
        }

        // Then
        XCTAssertEqual(player.played, [.recordingStarted, .textInserted])
    }

    /// **The case that catches the missing wiring.** Both switches off, a dictation that would
    /// otherwise make two sounds, and nothing is played. An app that forgot the `isEnabled:`
    /// argument fails exactly here and nowhere else.
    func testBothSwitchesOffMakeAWholeDictationSilent() {
        // Given
        settings.setSoundEnabled(false, for: .recordingStarted)
        settings.setSoundEnabled(false, for: .textInserted)
        let player = SpyPlayer()
        let feedback = makeFeedback(player)

        // When
        feedback.apply(.recording)
        feedback.apply(.completed(insertedCharacters: 42))
        feedback.apply(.idle)

        // Then
        XCTAssertEqual(player.played, [])
    }

    /// The two switches are two switches. Turning the start cue off must not cost the confirmation
    /// — one key per cue is what `AppSettings.soundKey(for:)` is written without a `default` to
    /// guarantee, and this is that guarantee observed from the other end: a shared key would make
    /// one switch silence both, which looks exactly like the switch working.
    func testSilencingTheStartCueLeavesTheInsertionCueAudible() {
        // Given
        settings.setSoundEnabled(false, for: .recordingStarted)
        let player = SpyPlayer()
        let feedback = makeFeedback(player)

        // When
        feedback.apply(.recording)
        feedback.apply(.completed(insertedCharacters: 42))

        // Then
        XCTAssertEqual(player.played, [.textInserted])
    }

    /// And the other way round, which is the switch Louis is likelier to reach for: the start cue
    /// is the one T11 exists for, the confirmation is the one that gets tiring.
    func testSilencingTheInsertionCueLeavesTheStartCueAudible() {
        // Given
        settings.setSoundEnabled(false, for: .textInserted)
        let player = SpyPlayer()
        let feedback = makeFeedback(player)

        // When
        feedback.apply(.recording)
        feedback.apply(.completed(insertedCharacters: 42))

        // Then
        XCTAssertEqual(player.played, [.recordingStarted])
    }

    /// **The switch takes effect on the next dictation without anything being rebuilt.** This is
    /// why `isEnabled` is a closure and not two stored booleans: the answer is read at the instant
    /// the sound would play, so one `CueFeedback` built at launch — which is what
    /// `DictationController` does — still obeys a switch flipped in the window an hour later.
    /// Passing `settings.isSoundEnabled(.recordingStarted)` by value instead would compile and
    /// would freeze the answer at launch.
    func testFlippingASwitchBetweenTwoDictationsChangesTheSecondOne() {
        // Given -- one long-lived feedback, as the app has
        let player = SpyPlayer()
        let feedback = makeFeedback(player)

        // When -- one dictation, then the switch, then another
        feedback.apply(.recording)
        feedback.apply(.completed(insertedCharacters: 42))
        settings.setSoundEnabled(false, for: .recordingStarted)
        feedback.apply(.recording)
        feedback.apply(.completed(insertedCharacters: 42))

        // Then -- the second dictation lost its start cue and kept its confirmation
        XCTAssertEqual(
            player.played, [.recordingStarted, .textInserted, .textInserted])
    }

    /// The switches only ever REMOVE sounds. `FeedbackPolicy` decides which cue a state earns, and
    /// a switch left on cannot conjure one for a state that earns none — a failed dictation stays
    /// silent whatever the settings say, because the start cue means "the microphone is live".
    func testASwitchLeftOnCannotAddASoundToAStateThatEarnsNone() {
        // Given -- both on, which is the default
        let player = SpyPlayer()
        let feedback = makeFeedback(player)

        // When
        feedback.apply(.failed(message: "mic start failed", recoveredText: nil))
        feedback.apply(.cancelled)
        feedback.apply(.completed(insertedCharacters: 0))
        feedback.apply(.idle)

        // Then
        XCTAssertEqual(player.played, [])
    }

    /// A switch turned off and back on is audible again — the setting is a filter, not a
    /// destruction. Trivial to state and the reason `isEnabled` is asked per sound rather than
    /// consulted once.
    func testTurningASwitchBackOnRestoresItsSound() {
        // Given
        let player = SpyPlayer()
        let feedback = makeFeedback(player)
        settings.setSoundEnabled(false, for: .recordingStarted)
        feedback.apply(.recording)

        // When
        settings.setSoundEnabled(true, for: .recordingStarted)
        feedback.apply(.recording)

        // Then
        XCTAssertEqual(player.played, [.recordingStarted])
    }
}
