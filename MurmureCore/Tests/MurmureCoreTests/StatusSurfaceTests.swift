import XCTest
@testable import MurmureCore

/// Louis's own arrangement, and the reason this file exists: a notched MacBook **and** an external
/// display with no notch, side by side. Every interesting case below is one where "this Mac has a
/// notch" is true and irrelevant.
///
/// The laptop holds the coordinate origin, so it is `screens.first`; the external display sits to
/// its right. Menu-bar and Dock heights are taken off `visibleFrame` the way AppKit does.
private let laptop = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
    hasNotch: true
)
private let external = ScreenGeometry(
    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
    hasNotch: false
)

/// A window filling the middle of one screen, which is what a terminal being typed into looks like.
private func window(on screen: ScreenGeometry) -> CGRect {
    screen.frame.insetBy(dx: 200, dy: 150)
}

final class StatusSurfaceTests: XCTestCase {
    // MARK: - Which surface, on one display

    func testTheNotchIsOnlyUsedOnADisplayThatHasOne() {
        XCTAssertEqual(StatusSurfaceChoice.surface(on: laptop), .notch)
        XCTAssertEqual(StatusSurfaceChoice.surface(on: external), .panel)
    }

    /// The bug, stated as a test. Both displays are attached and one of them has a cutout, so any
    /// rule that asks "does this Mac have a notch" answers yes -- and Louis, working on the
    /// external display, sees nothing at all.
    func testTheExternalDisplayGetsThePanelEvenThoughTheMacHasANotch() throws {
        let chosen = try XCTUnwrap(StatusSurfaceChoice.screen(
            among: [laptop, external], focusedWindow: window(on: external), mouseLocation: nil))
        XCTAssertEqual(chosen, external)
        XCTAssertEqual(StatusSurfaceChoice.surface(on: chosen), .panel)
    }

    // MARK: - The one decision both surfaces are given

    /// **Defect 1, stated as a test.** Louis dictates into a window on the external display while
    /// the app window is up on the laptop, and both surfaces light up: the notch card grows on the
    /// built-in display and the floating strip opens on the external one, saying the same thing.
    ///
    /// The mechanism is that the choice was made twice. `NotchController` resolved its display
    /// from `NSScreen.main`, which -- measured on this machine, for a process with no key window,
    /// while the frontmost application and the pointer were both on the external display --
    /// returns the built-in notched display, i.e. `screens[0]`. `StatusPanelController` resolved
    /// its own from the ranked signals and got the external one. Each then asked "does MY display
    /// suit MY surface", and both answers were yes.
    ///
    /// One route cannot say that. The display Louis is dictating into is the external one, so the
    /// surface is the strip, and the notch is refused by the same value.
    func testTheStatusFollowsTheWindowBeingDictatedIntoAndNotTheDisplayHoldingTheMenuBar() {
        let route = StatusSurfaceChoice.route(
            among: [laptop, external],
            focusedWindow: window(on: external),
            mouseLocation: CGPoint(x: 2000, y: 700)
        )
        XCTAssertEqual(route, StatusRoute(screenIndex: 1, surface: .panel))
    }

    /// The same decision on the other display, so the test above cannot be passed by a function
    /// that has simply stopped believing in the notch.
    func testADictationIntoAWindowOnTheLaptopStillGrowsTheNotch() {
        let route = StatusSurfaceChoice.route(
            among: [laptop, external],
            focusedWindow: window(on: laptop),
            mouseLocation: CGPoint(x: 2000, y: 700)
        )
        XCTAssertEqual(route, StatusRoute(screenIndex: 0, surface: .notch))
    }

    /// **The structural claim, over every signal this arrangement can produce.** Whatever is
    /// focused and wherever the pointer is, the route names one display and the surface that
    /// display can actually show -- so exactly one of the two surfaces is ever told to draw, and
    /// the "both at once" of defect 1 and the "neither at all" of defect 2 are the same
    /// impossibility.
    func testTheRoutesSurfaceIsAlwaysTheOneItsOwnDisplayCanShow() {
        let screens = [laptop, external]
        let windows: [CGRect?] = [
            nil, window(on: laptop), window(on: external),
            CGRect(x: -5000, y: -5000, width: 100, height: 100),
        ]
        let mice: [CGPoint?] = [
            nil, CGPoint(x: 400, y: 400), CGPoint(x: 2000, y: 700),
            CGPoint(x: -5000, y: -5000),
        ]
        for focused in windows {
            for mouse in mice {
                let route = StatusSurfaceChoice.route(
                    among: screens, focusedWindow: focused, mouseLocation: mouse)
                guard let route else {
                    return XCTFail("two displays are attached; there is always a route")
                }
                XCTAssertTrue(screens.indices.contains(route.screenIndex))
                XCTAssertEqual(
                    route.surface, StatusSurfaceChoice.surface(on: screens[route.screenIndex]),
                    "focused \(String(describing: focused)), mouse \(String(describing: mouse))")
            }
        }
    }

    func testNoScreensAtAllHasNoRoute() {
        XCTAssertNil(StatusSurfaceChoice.route(
            among: [], focusedWindow: nil, mouseLocation: CGPoint(x: 0, y: 0)))
    }

    // MARK: - How long a route is held

    /// A dictation resolves its display once, at the press, and nothing moves it afterwards: the
    /// pointer travelling to the other screen mid-sentence must not take the strip with it.
    func testEveryPhaseOfADictationKeepsTheDisplayThePressResolved() {
        let held = StatusRoute(screenIndex: 1, surface: .panel)
        let elsewhere = StatusRoute(screenIndex: 0, surface: .notch)
        for phase in [
            NotchPhase.transcribing, .preparingModel(.downloading(ModelDownload(expectedBytes: 1_638_467_188))),
            .preparingModel(.loading), .refining, .inserting,
            .completed(insertedCharacters: 12), .nothingHeard,
            .failed(message: "no", recoveredText: nil), .alert(message: "no"),
        ] {
            XCTAssertEqual(
                StatusSurfaceChoice.route(for: phase, held: held, resolved: elsewhere), held,
                "\(phase) moved the surface mid-dictation")
        }
    }

    /// The next press re-resolves, so plugging a display in between two dictations needs nothing
    /// switched.
    func testAFreshRecordingResolvesItsOwnDisplay() {
        let stale = StatusRoute(screenIndex: 0, surface: .notch)
        let fresh = StatusRoute(screenIndex: 1, surface: .panel)
        XCTAssertEqual(
            StatusSurfaceChoice.route(for: .recording, held: stale, resolved: fresh), fresh)
    }

    /// **Defect 2's half of the mechanism.** A held display must not outlive the dictation that
    /// resolved it. It did in the shipped panel -- `hide()` had already put the model in `.hidden`,
    /// so the `.hidden` phase that clears the hold was swallowed by the guard above it -- and the
    /// consequence is precise: the next thing to reach a surface WITHOUT a `.recording` in front
    /// of it, which is exactly the ⌥Space refused because Murmure is in front, was pinned to the
    /// display of a dictation that had already ended.
    func testAHeldDisplayDoesNotOutliveTheDictationThatResolvedIt() {
        XCTAssertNil(StatusSurfaceChoice.route(
            for: .hidden,
            held: StatusRoute(screenIndex: 0, surface: .notch),
            resolved: StatusRoute(screenIndex: 1, surface: .panel)))
    }

    /// A phase arriving with no dictation behind it -- the refusal above, an alert at launch --
    /// resolves a display of its own rather than saying nothing.
    func testAPhaseWithNoDictationBehindItResolvesItsOwnDisplay() {
        let fresh = StatusRoute(screenIndex: 1, surface: .panel)
        XCTAssertEqual(
            StatusSurfaceChoice.route(
                for: .failed(message: "Murmure is in front", recoveredText: nil),
                held: nil, resolved: fresh),
            fresh)
    }

    /// A dictation that succeeds emits `.completed` and `.idle` together, and both draw the
    /// `.completed` phase -- so the hold must survive the first and die on the second, or the
    /// flash Louis is looking at is re-placed halfway through and handed to the other surface.
    func testACompletionKeepsItsDisplayAndTheIdleBehindItReleasesIt() {
        XCTAssertTrue(StatusSurfaceChoice.routeOutlives(.completed(insertedCharacters: 12)))
        XCTAssertFalse(StatusSurfaceChoice.routeOutlives(.idle))
    }

    /// Every phase of a running dictation keeps it, so nothing re-resolves under a shape that is
    /// on screen.
    func testARunningDictationKeepsItsDisplay() {
        XCTAssertTrue(StatusSurfaceChoice.routeOutlives(.recording))
        XCTAssertTrue(StatusSurfaceChoice.routeOutlives(.transcribing))
        XCTAssertTrue(StatusSurfaceChoice.routeOutlives(.refining))
        XCTAssertTrue(StatusSurfaceChoice.routeOutlives(.inserting))
    }

    /// **Defect 2, at the state level.** A ⌥Space refused because Murmure is in front produces a
    /// `.failed` with no `.recording` before it and nothing after it. A hold kept there would
    /// place every later refusal on the display of the first one -- which is how the shipped panel
    /// came to hide a message on a screen Louis was not looking at.
    func testAFailureReleasesTheDisplayItWasShownOn() {
        XCTAssertFalse(
            StatusSurfaceChoice.routeOutlives(.failed(message: "in front", recoveredText: nil)))
    }

    // MARK: - Which display

    /// The ranking, at the one place it can be seen: the two best signals disagree.
    func testTheFocusedWindowOutranksTheMouse() {
        let chosen = StatusSurfaceChoice.screen(
            among: [laptop, external],
            focusedWindow: window(on: external),
            mouseLocation: CGPoint(x: 400, y: 400)
        )
        XCTAssertEqual(chosen, external, "the pointer was left on the laptop; the typing is not")
    }

    func testTheMouseIsUsedWhenThereIsNoFocusedWindow() {
        let chosen = StatusSurfaceChoice.screen(
            among: [laptop, external],
            focusedWindow: nil,
            mouseLocation: CGPoint(x: 2000, y: 700)
        )
        XCTAssertEqual(chosen, external)
    }

    /// A window dragged across the boundary belongs to the display showing most of it, not to the
    /// one holding its origin -- the origin is the top-left corner, the corner nobody reads.
    func testAStraddlingWindowGoesToTheDisplayShowingMostOfIt() {
        // 100 pt of it on the laptop, 900 pt on the external display.
        let straddling = CGRect(x: 1412, y: 300, width: 1000, height: 600)
        let chosen = StatusSurfaceChoice.screen(
            among: [laptop, external], focusedWindow: straddling, mouseLocation: nil)
        XCTAssertEqual(chosen, external)
    }

    /// A focused window that touches no screen is not an answer to fall back *from* silently: the
    /// mouse is asked next. This is a minimised window, and a window on a display unplugged since
    /// the frame was read.
    func testAFocusedWindowOnNoScreenFallsThroughToTheMouse() {
        let offscreen = CGRect(x: -8000, y: -8000, width: 800, height: 600)
        let chosen = StatusSurfaceChoice.screen(
            among: [laptop, external],
            focusedWindow: offscreen,
            mouseLocation: CGPoint(x: 2000, y: 700)
        )
        XCTAssertEqual(chosen, external)
    }

    /// An overlap of zero area is a window touching a screen edge, not a window on that screen.
    /// Without this, a zero-height window resting on the laptop would beat a pointer that says
    /// plainly where Louis is.
    func testAZeroAreaOverlapDoesNotWinTheDisplay() {
        let degenerate = CGRect(x: 100, y: 500, width: 400, height: 0)
        let chosen = StatusSurfaceChoice.screen(
            among: [laptop, external],
            focusedWindow: degenerate,
            mouseLocation: CGPoint(x: 2000, y: 700)
        )
        XCTAssertEqual(chosen, external)
    }

    /// Neither signal says anything: the pointer is in the gap between two displays of different
    /// heights, and nothing is focused. Somewhere beats nowhere.
    func testWithNoUsableSignalTheFirstScreenIsUsed() {
        let inTheGap = CGPoint(x: 1000, y: 1200)
        let chosen = StatusSurfaceChoice.screen(
            among: [laptop, external], focusedWindow: nil, mouseLocation: inTheGap)
        XCTAssertEqual(chosen, laptop)
    }

    /// Every display asleep. Nil rather than a crash: `screens[0]` on an empty array would take
    /// the whole app down over a decoration.
    func testNoScreensAtAllIsNil() {
        XCTAssertNil(
            StatusSurfaceChoice.screen(among: [], focusedWindow: nil, mouseLocation: .zero))
    }

    // MARK: - Where on that display

    /// The panel hangs from the top edge, and `topMargin` is the gap *above* it.
    ///
    /// This assertion is the reverse of the one it replaces, which pinned the panel to the bottom
    /// of the usable area. The change is Louis's: the notch is at the top, so the surface that
    /// stands in for it on a display without a cutout is at the top too. `StatusSurfaceChoice`'s
    /// own note carries the reasoning and what it costs.
    ///
    /// `maxY` rather than `minY` is the whole point of the assertion. A panel placed 96 pt above
    /// `visibleFrame.minY + height` would also be "96 from an edge" and would hang 34 pt lower
    /// than the number reads.
    func testThePanelIsCentredJustBelowTheTopOfTheUsableArea() {
        let size = CGSize(width: 220, height: 34)
        let frame = StatusSurfaceChoice.frame(size: size, on: external)
        XCTAssertEqual(frame.midX, external.visibleFrame.midX)
        XCTAssertEqual(frame.maxY, external.visibleFrame.maxY - StatusSurfaceChoice.topMargin)
        XCTAssertEqual(frame.size, size)
    }

    /// `visibleFrame`, not `frame`. This replaces the Dock test that guarded the bottom placement,
    /// and it guards strictly more: a panel that got the bottom edge wrong floated over the Dock,
    /// which is ugly, while one that gets the top edge wrong opens *inside the menu bar*, at
    /// `.screenSaver` level, on top of the clock.
    ///
    /// 33 pt is the band measured on Louis's built-in display. The external one reserves none
    /// today, which is exactly why this is tested against a fixture and not against his desk.
    func testTheMenuBarPushesThePanelDownInsteadOfOpeningInsideIt() {
        let menuBar: CGFloat = 33
        let withMenuBar = ScreenGeometry(
            frame: external.frame,
            visibleFrame: CGRect(
                x: external.frame.minX,
                y: external.frame.minY,
                width: external.frame.width,
                height: external.frame.height - menuBar
            ),
            hasNotch: false
        )
        let frame = StatusSurfaceChoice.frame(size: CGSize(width: 220, height: 34), on: withMenuBar)
        XCTAssertEqual(
            frame.maxY,
            external.frame.maxY - menuBar - StatusSurfaceChoice.topMargin
        )
        XCTAssertLessThanOrEqual(frame.maxY, withMenuBar.visibleFrame.maxY, "opened into the menu bar")
    }

    /// The horizontal half of the same rule, and the one every other fixture here is blind to.
    ///
    /// A Dock on the left or right edge is the only thing that moves `visibleFrame.midX` away from
    /// `frame.midX`. Without a side-docked screen the two are the same number, so "centred on the
    /// usable area" and "centred on the display" are the same assertion and an implementation that
    /// used `frame` would satisfy both.
    ///
    /// Found by mutation and not by reading: swapping `visibleFrame.midX` for `frame.midX` killed
    /// no test. It is a hole rather than a bug Louis can see -- neither of his displays reserves
    /// anything horizontally -- which is exactly the kind that waits for a new arrangement.
    func testASideDockCentresThePanelOnTheUsableAreaAndNotOnTheDisplay() {
        let dockWidth: CGFloat = 90
        let sideDocked = ScreenGeometry(
            frame: external.frame,
            visibleFrame: CGRect(
                x: external.frame.minX + dockWidth,
                y: external.frame.minY,
                width: external.frame.width - dockWidth,
                height: external.frame.height
            ),
            hasNotch: false
        )
        let frame = StatusSurfaceChoice.frame(size: CGSize(width: 220, height: 34), on: sideDocked)
        XCTAssertEqual(frame.midX, sideDocked.visibleFrame.midX)
        XCTAssertNotEqual(
            frame.midX, sideDocked.frame.midX, "centred on the display instead of the room left")
    }

    /// A display whose usable width and the panel's width have different parities puts the centred
    /// origin on a half point, and a half-point origin smears the capsule's 1 pt border across two
    /// physical pixels on a non-Retina display.
    func testTheOriginIsAWholeNumberOfPoints() {
        let oddWidth = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1511, height: 850),
            visibleFrame: CGRect(x: 0, y: 0.5, width: 1511, height: 825),
            hasNotch: false
        )
        let frame = StatusSurfaceChoice.frame(size: CGSize(width: 220, height: 34), on: oddWidth)
        XCTAssertEqual(frame.minX, frame.minX.rounded(), "x landed on a half point")
        XCTAssertEqual(frame.minY, frame.minY.rounded(), "y landed on a half point")
    }

    // MARK: - Reading a window frame out of the Accessibility API

    /// The Accessibility API measures downwards from the top-left of the primary display;
    /// `NSScreen` measures upwards from its bottom-left. A window pinned to the top-left corner is
    /// where the two disagree most and where an unconverted value still looks plausible.
    func testAWindowAtTheTopLeftOfThePrimaryDisplayLandsAtItsTop() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let converted = StatusSurfaceChoice.screenFrame(
            accessibilityPosition: CGPoint(x: 0, y: 0),
            size: CGSize(width: 800, height: 600),
            primaryScreenFrame: primary
        )
        XCTAssertEqual(converted, CGRect(x: 0, y: 982 - 600, width: 800, height: 600))
        XCTAssertEqual(converted.maxY, primary.maxY, "its top edge is the top of the display")
    }

    /// A display placed *above* the primary one reports negative Accessibility y values, and they
    /// have to come out above the primary display rather than inside it.
    func testADisplayAboveThePrimaryOneConvertsToPositionsAboveIt() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let converted = StatusSurfaceChoice.screenFrame(
            accessibilityPosition: CGPoint(x: 200, y: -900),
            size: CGSize(width: 1000, height: 700),
            primaryScreenFrame: primary
        )
        XCTAssertEqual(converted.minX, 200, "x is the same in both spaces")
        XCTAssertGreaterThan(converted.minY, primary.maxY)
    }

    /// The conversion is its own inverse, which is the cheap way of saying it is a reflection and
    /// not an offset: applying it twice has to give back the rectangle it started from.
    func testTheConversionIsItsOwnInverse() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let start = CGPoint(x: 340, y: 210)
        let size = CGSize(width: 900, height: 500)
        let once = StatusSurfaceChoice.screenFrame(
            accessibilityPosition: start, size: size, primaryScreenFrame: primary)
        let twice = StatusSurfaceChoice.screenFrame(
            accessibilityPosition: once.origin, size: size, primaryScreenFrame: primary)
        XCTAssertEqual(twice.origin.x, start.x)
        XCTAssertEqual(twice.origin.y, start.y)
    }
    // MARK: - The standing failure panel, placed under the strip

    /// The two surfaces can be on screen together: a paste failure opens the standing panel while
    /// the strip is still showing the failure it is about, for `NotchPresenter.failureDwell`. On a
    /// display with no cutout both are placed by the same function on the same midX, so an
    /// overlap would put the panel across the sentence explaining it.
    func testTheStandingPanelClearsTheStatusStripOnADisplayWithNoCutout() {
        let strip = StatusSurfaceChoice.frame(size: StatusPanelLayout.size, on: external)
        let standing = StatusSurfaceChoice.frame(
            size: StandingPanelLayout.size(for: .alert(.accessibilityDenied)),
            on: external, topMargin: StatusSurfaceChoice.standingTopMargin)
        XCTAssertFalse(strip.intersects(standing))
        // Below it, not above: the strip is nearer the menu bar, and y grows upwards.
        XCTAssertLessThan(standing.maxY, strip.minY)
    }

    /// The floor under `standingTopMargin`, stated as the inequality rather than as the digits.
    func testTheStandingMarginClearsTheWholeHeightOfTheStrip() {
        XCTAssertGreaterThanOrEqual(
            StatusSurfaceChoice.standingTopMargin,
            StatusSurfaceChoice.topMargin + StatusPanelLayout.height)
    }

    /// The default argument is the strip's margin, so every existing caller places what it always
    /// placed. A default that drifted would move the one surface Louis has been reading.
    func testThePlacementDefaultIsStillTheStripsOwnMargin() {
        XCTAssertEqual(
            StatusSurfaceChoice.frame(size: StatusPanelLayout.size, on: external),
            StatusSurfaceChoice.frame(
                size: StatusPanelLayout.size, on: external,
                topMargin: StatusSurfaceChoice.topMargin))
    }

}
