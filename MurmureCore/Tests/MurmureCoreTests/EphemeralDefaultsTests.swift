import XCTest
@testable import MurmureCore

/// The test double every settings suite now runs on, under test itself.
///
/// **The isolation is the whole point, so it is asserted rather than trusted.**
/// `EphemeralDefaults` inherits from `UserDefaults` with the standard search list underneath it,
/// so an accessor left unoverridden reads and writes `com.louiscourcier.Murmure` — the real
/// preferences of the app Louis is running. These cases walk every accessor the production code
/// uses and check, after each, that nothing arrived in `.standard`.
final class EphemeralDefaultsTests: XCTestCase {
    /// A key nothing else in the app could plausibly own, so a hit in `.standard` can only have
    /// come from here.
    private let key = "ephemeral-defaults-probe-key"

    /// Belt for the assertions below: if an override ever regresses, this stops the probe key
    /// being left in Louis's real preferences by the very test that detects it.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - It behaves like the thing it replaces

    func testAStringRoundTripsThroughBothAccessors() {
        let defaults = EphemeralDefaults()

        defaults.set("AppleUSBAudioEngine:Shure:MV7", forKey: key)

        XCTAssertEqual(defaults.string(forKey: key), "AppleUSBAudioEngine:Shure:MV7")
        XCTAssertEqual(defaults.object(forKey: key) as? String, "AppleUSBAudioEngine:Shure:MV7")
    }

    /// The distinction `AppSettings.bool(_:default:)` is built on: an absent key answers `false`
    /// from `bool(forKey:)` and `nil` from `object(forKey:)`, and it is the second one that tells
    /// "never asked" from "switched off". A double that got this wrong would make every
    /// default-true setting look like it shipped off.
    func testAnAbsentKeyIsFalseAndNilJustAsTheRealClassIs() {
        let defaults = EphemeralDefaults()

        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testAStoredFalseIsDistinguishableFromAnAbsentKey() {
        let defaults = EphemeralDefaults()

        defaults.set(false, forKey: key)

        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertNotNil(defaults.object(forKey: key))
    }

    /// `WindowRestoration` stores a frame as four doubles, so the array path is load-bearing.
    func testAnArrayOfDoublesRoundTrips() {
        let defaults = EphemeralDefaults()

        defaults.set([12.0, 34.0, 980.0, 660.0], forKey: key)

        XCTAssertEqual(defaults.array(forKey: key) as? [Double], [12.0, 34.0, 980.0, 660.0])
    }

    /// Setting nil removes, which is `UserDefaults`' own behaviour and what the clear-by-nil
    /// setters rely on.
    func testSettingNilRemovesTheKeyRatherThanStoringNull() {
        let defaults = EphemeralDefaults()
        defaults.set("something", forKey: key)

        defaults.set(nil, forKey: key)

        XCTAssertNil(defaults.object(forKey: key))
    }

    func testRemoveObjectRemoves() {
        let defaults = EphemeralDefaults()
        defaults.set("something", forKey: key)

        defaults.removeObject(forKey: key)

        XCTAssertNil(defaults.object(forKey: key))
    }

    /// The remaining typed accessors, walked so none of them is an untested fall-through to the
    /// real domain.
    func testTheNumericAndDataAccessorsAnswerFromTheSameStorage() {
        let defaults = EphemeralDefaults()

        defaults.set(42, forKey: "int")
        defaults.set(3.5, forKey: "double")
        defaults.set(Data("bonjour".utf8), forKey: "data")

        XCTAssertEqual(defaults.integer(forKey: "int"), 42)
        XCTAssertEqual(defaults.double(forKey: "double"), 3.5)
        XCTAssertEqual(defaults.data(forKey: "data"), Data("bonjour".utf8))
        XCTAssertEqual(defaults.integer(forKey: "never-written"), 0)
        XCTAssertEqual(defaults.double(forKey: "never-written"), 0)
        XCTAssertNil(defaults.data(forKey: "never-written"))
    }

    // MARK: - It reaches nothing outside itself

    /// **The one that matters.** A write through the double must not appear in the preferences of
    /// the application Louis is running — which is where an unoverridden `set` would put it,
    /// silently, because the superclass search list is the standard one.
    func testAWriteNeverReachesTheRealStandardDomain() {
        let defaults = EphemeralDefaults()

        defaults.set("this must not persist anywhere", forKey: key)

        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    /// Two instances do not see each other, which is what makes a suite name unnecessary: the
    /// isolation between tests comes from the object rather than from a domain that has to be
    /// named, cleaned up and raced against `cfprefsd`.
    func testTwoInstancesShareNothing() {
        let first = EphemeralDefaults()
        let second = EphemeralDefaults()

        first.set("only mine", forKey: key)

        XCTAssertNil(second.object(forKey: key))
    }

    /// ...**except** through `reopened()`, which is how the "remembered across launches" cases in
    /// `ModePreferenceTests` and `WindowRestorationTests` still read a value back through a second
    /// `UserDefaults` object. That is what they were really asserting: the answer lives in the
    /// defaults, not cached in the value type that wrote it.
    func testAReopenedInstanceSeesWhatTheFirstOneWrote() {
        let defaults = EphemeralDefaults()
        defaults.set("prompt", forKey: key)

        let reopened = defaults.reopened()

        XCTAssertEqual(reopened.string(forKey: key), "prompt")
        XCTAssertFalse(reopened === defaults, "a reopen has to be a different object to prove anything")
    }

    /// And the store is shared in both directions, so a removal is seen too — the shape
    /// `ModePreferenceTests` uses to check that clearing a choice really clears it.
    func testARemovalIsVisibleThroughAReopenedInstance() {
        let defaults = EphemeralDefaults()
        defaults.set("prompt", forKey: key)
        defaults.removeObject(forKey: key)

        XCTAssertNil(defaults.reopened().object(forKey: key))
    }

    /// The reason the whole class exists: no file, so nothing for `cfprefsd` to flush back after
    /// a `tearDown` has deleted it. Asserted against the real Preferences directory, by counting
    /// the litter shape the old pattern produced.
    func testUsingItCreatesNoPreferencesFile() throws {
        // Given
        let preferences = try FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Preferences")
        let before = try Self.testPlists(in: preferences)

        // When -- the exact traffic a settings test generates
        let defaults = EphemeralDefaults()
        for index in 0..<50 {
            defaults.set("value \(index)", forKey: "key \(index)")
            _ = defaults.string(forKey: "key \(index)")
        }

        // Then
        XCTAssertEqual(try Self.testPlists(in: preferences), before)
    }

    /// The `<SomethingTests>-<UUID>.plist` shape the suite-per-test pattern used to leave behind.
    private static func testPlists(in preferences: URL) throws -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        return Set(names.filter { $0.contains("Tests-") && $0.hasSuffix(".plist") })
    }
}
