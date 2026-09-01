import XCTest
@testable import MurmureCore

/// The window comes back where it was left — and, more to the point, does not come back where it
/// cannot be reached.
final class WindowRestorationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// A suite of its own per test, removed afterwards, and the housekeeping `ModePreferenceTests`
    /// already had to work out: nothing here may touch `.standard`, which is the real
    /// application's own preferences domain, and `cfprefsd` leaves an emptied suite's plist behind
    /// in Louis's home directory unless it is flushed and then deleted.
    override func setUpWithError() throws {
        suiteName = "WindowRestorationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        defaults.removeSuite(named: suiteName)
        let plist = try FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Preferences/\(suiteName!).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    /// The same safety net, and only ever this class's own prefix: `cfprefsd` writes
    /// asynchronously, so a flush can land after the deletion above and recreate the file.
    override class func tearDown() {
        guard let preferences = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Preferences"),
            let leftovers = try? FileManager.default.contentsOfDirectory(atPath: preferences.path)
        else { return }

        for name in leftovers
        where name.hasPrefix("WindowRestorationTests-") && name.hasSuffix(".plist") {
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(name))
        }
    }

    private var restoration: WindowRestoration { WindowRestoration(defaults: defaults) }

    /// One 1512 × 982 display with a menu bar, which is the machine this is being written on.
    private let builtInDisplay = [CGRect(x: 0, y: 0, width: 1512, height: 944)]

    // MARK: - The section

    /// The very first launch, and every launch after a section was removed in a later lot.
    func testNothingStoredOpensOnHistory() {
        XCTAssertEqual(restoration.section, .history)
    }

    /// What "remembered across launches" is testable as in one process, the same way
    /// `ModePreferenceTests` puts it: a restoration built from scratch over the same domain reads
    /// the choice back, so the choice lives in the defaults domain and not in the instance that
    /// wrote it.
    func testTheSectionIsReadBackByAFreshRestoration() throws {
        restoration.section = .vocabulary

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(WindowRestoration(defaults: reopened).section, .vocabulary)
    }

    /// **The one that matters.** A section renamed or removed in a later lot leaves every window
    /// last closed on it holding a name that no longer exists. It has to resolve to History and
    /// not to nothing: a window with no selection and an empty detail pane looks exactly like a
    /// bug, and the user's first move would be to quit and reopen, which changes nothing.
    func testASectionNameThatNoLongerExistsOpensOnHistory() {
        defaults.set("statistics", forKey: "windowSection")

        XCTAssertEqual(restoration.section, .history)
    }

    /// A value of the right type but the wrong shape, and a value of the wrong type entirely.
    /// Both are reachable through a hand-run `defaults write`.
    func testAnEmptyOrNonsenseSectionEntryOpensOnHistory() {
        defaults.set("", forKey: "windowSection")
        XCTAssertEqual(restoration.section, .history)

        defaults.set(42, forKey: "windowSection")
        XCTAssertEqual(restoration.section, .history)
    }

    /// The literal name, written out with a real value: this is what the section is filed under,
    /// and a test that only ever expected History under it would agree with any rename.
    func testTheSectionIsFiledUnderTheNameItAlreadyHas() {
        defaults.set("advanced", forKey: "windowSection")

        XCTAssertEqual(restoration.section, .advanced)
    }

    // MARK: - The frame, as a codec

    func testNothingStoredHasNoFrame() {
        XCTAssertNil(restoration.storedFrame)
    }

    func testTheFrameIsReadBackByAFreshRestoration() throws {
        let frame = CGRect(x: 120, y: 84, width: 1040, height: 700)
        restoration.storedFrame = frame

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(WindowRestoration(defaults: reopened).storedFrame, frame)
    }

    /// Clearing is a real operation and not the absence of one — it is what a frame refused on
    /// read should be able to turn into, so that the next launch does not re-litigate the same
    /// unreachable rectangle. Stored as the absence of an entry, never as an empty array, so that
    /// the two cannot drift apart.
    func testClearingTheFrameLeavesNoStaleEntry() {
        restoration.storedFrame = CGRect(x: 10, y: 10, width: 800, height: 600)

        restoration.storedFrame = nil

        XCTAssertNil(restoration.storedFrame)
        XCTAssertNil(defaults.object(forKey: "windowFrame"))
    }

    /// Only reachable through a hand-run `defaults write` or a plist edited by hand, and it must
    /// not decode into a rectangle with three of its four numbers guessed.
    func testAStoredValueOfTheWrongShapeIsNotAFrame() {
        defaults.set([10.0, 10.0, 800.0], forKey: "windowFrame")
        XCTAssertNil(restoration.storedFrame)

        defaults.set("980x660", forKey: "windowFrame")
        XCTAssertNil(restoration.storedFrame)
    }

    /// `NaN` cannot be written to a property list, so the guard is on the way *out* as much as on
    /// the way in: a frame containing one would take the app down as it closed rather than as it
    /// opened, which is the harder crash to explain.
    ///
    /// Seeded, for the reason the test below it gives at length.
    func testANonFiniteFrameIsIgnoredRatherThanWrittenToThePlist() {
        let good = CGRect(x: 40, y: 60, width: 900, height: 620)
        restoration.storedFrame = good
        XCTAssertEqual(restoration.storedFrame, good, "the seed has to land, or this is vacuous")

        restoration.storedFrame = CGRect(x: CGFloat.nan, y: 0, width: 900, height: 600)

        XCTAssertEqual(restoration.storedFrame, good)
        XCTAssertEqual(
            defaults.array(forKey: "windowFrame") as? [Double],
            [good.origin.x, good.origin.y, good.width, good.height],
            "a NaN reached the plist, or erased the frame that was good")
    }

    // MARK: - The frame, as a fact about the hardware attached right now

    func testAFrameOnTheAttachedDisplayIsRestored() {
        let frame = CGRect(x: 200, y: 120, width: 980, height: 660)

        XCTAssertEqual(WindowRestoration.usableFrame(frame, onScreens: builtInDisplay), frame)
    }

    /// **The other one that matters, and the ordinary one.** An external display unplugged since
    /// the last launch leaves a perfectly well-formed frame at x = 2560 — no corruption, no bad
    /// data, just a window nobody will ever see again. An accessory app makes it worse than it
    /// sounds: there is no ⌘Tab entry and no Dock icon to bring it back with (plan §2.4).
    func testAFrameOnADisplayThatIsNoLongerAttachedIsRefused() {
        let onTheUnpluggedMonitor = CGRect(x: 2560, y: 300, width: 980, height: 660)

        XCTAssertNil(WindowRestoration.usableFrame(onTheUnpluggedMonitor, onScreens: builtInDisplay))
    }

    /// Plugged back in, the same frame is fine again — which is what makes refusing it above a
    /// placement decision rather than a purge.
    func testTheSameFrameIsRestoredOnceThatDisplayIsBack() {
        let onTheSecondMonitor = CGRect(x: 2560, y: 300, width: 980, height: 660)
        let bothDisplays = builtInDisplay + [CGRect(x: 1512, y: 0, width: 2560, height: 1440)]

        XCTAssertEqual(
            WindowRestoration.usableFrame(onTheSecondMonitor, onScreens: bothDisplays),
            onTheSecondMonitor)
    }

    /// A window with four points on screen is as lost as one with none: the question is not
    /// whether any of it is visible but whether it can be dragged back.
    func testAFrameWithOnlyASliverOnScreenIsRefused() {
        let almostOff = CGRect(x: 1512 - 40, y: 400, width: 980, height: 660)

        XCTAssertNil(WindowRestoration.usableFrame(almostOff, onScreens: builtInDisplay))
    }

    /// Exactly the graspable patch, on the same edge — the boundary the line above sits just
    /// outside of, so that the two together pin a threshold rather than a direction.
    func testAFrameShowingExactlyTheGraspablePatchIsRestored() {
        let patch = WindowRestoration.minimumGrab
        let justEnough = CGRect(
            x: 1512 - patch.width, y: 944 - patch.height, width: 980, height: 660)

        XCTAssertEqual(WindowRestoration.usableFrame(justEnough, onScreens: builtInDisplay),
                       justEnough)
    }

    /// No screens at all — a lid closed on a Mac with nothing else plugged in, which
    /// `NSScreen.screens` really does report as empty.
    func testAFrameIsRefusedWhenThereAreNoScreens() {
        let frame = CGRect(x: 0, y: 0, width: 980, height: 660)

        XCTAssertNil(WindowRestoration.usableFrame(frame, onScreens: []))
    }

    func testADegenerateFrameIsRefused() {
        XCTAssertNil(WindowRestoration.usableFrame(
            CGRect(x: 100, y: 100, width: 0, height: 660), onScreens: builtInDisplay))
        XCTAssertNil(WindowRestoration.usableFrame(
            CGRect(x: 100, y: 100, width: 980, height: 0), onScreens: builtInDisplay))
    }

    /// The write side of the same guard, and the half the test above does **not** cover: a
    /// rectangle with no area is refused on read anyway, because a zero-width intersection can
    /// never reach the graspable patch — so nothing on screen would go wrong and the guard in
    /// `isWellFormed` looks redundant. It is not. Without it the store holds something that is not
    /// a rectangle, and every later reader of `storedFrame` has to decide about it again.
    ///
    /// Measured: a mutant deleting `width > 0 && height > 0` survived the whole suite until this
    /// existed.
    /// **Seeded on purpose, and the seed is an assertion.** Each test gets a fresh suite, so a
    /// domain that is empty at the end proves nothing on its own: it is equally the answer if the
    /// setter refused the frame, and if the setter does nothing at all. Measured — the first
    /// version of this test passed against a setter mutated to an empty body.
    ///
    /// Writing a good frame first is what makes the assertion mean something, and it pins the
    /// behaviour that matters rather than only the absence of the bad one: a malformed write is
    /// **ignored**, so the last frame that was good is still there and the next launch still opens
    /// where Louis left the window. Refusing it by *erasing* would pass a test that only checked
    /// the junk was absent, and would cost him the position.
    ///
    /// `defaults.array(forKey:)` reads the raw entry, so nothing the getter does can satisfy this.
    func testAMalformedFrameIsIgnoredAndLeavesTheLastGoodOneStanding() {
        for degenerate in [
            CGRect(x: 100, y: 100, width: 0, height: 660),
            CGRect(x: 100, y: 100, width: 980, height: 0),
        ] {
            let good = CGRect(x: 40, y: 60, width: 900, height: 620)
            restoration.storedFrame = good
            XCTAssertEqual(restoration.storedFrame, good, "the seed has to land, or this is vacuous")

            restoration.storedFrame = degenerate

            XCTAssertEqual(
                defaults.array(forKey: "windowFrame") as? [Double],
                [good.origin.x, good.origin.y, good.width, good.height],
                "\(degenerate.size) was stored, or erased the frame that was good")
            XCTAssertEqual(restoration.storedFrame, good)
        }
    }

    /// The two halves composed, which is the call the window actually makes.
    func testTheStoredFrameIsOfferedOnlyWhenItIsUsable() {
        restoration.storedFrame = CGRect(x: 2560, y: 300, width: 980, height: 660)

        XCTAssertNil(restoration.frame(onScreens: builtInDisplay))
        XCTAssertNotNil(restoration.storedFrame, "refusing to use it must not erase it")
    }
}
