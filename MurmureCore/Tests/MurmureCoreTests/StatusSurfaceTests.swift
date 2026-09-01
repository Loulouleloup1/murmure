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

    func testThePanelIsCentredJustAboveTheBottomOfTheUsableArea() {
        let size = CGSize(width: 220, height: 34)
        let frame = StatusSurfaceChoice.frame(size: size, on: external)
        XCTAssertEqual(frame.midX, external.visibleFrame.midX)
        XCTAssertEqual(frame.minY, external.visibleFrame.minY + StatusSurfaceChoice.bottomMargin)
        XCTAssertEqual(frame.size, size)
    }

    /// `visibleFrame`, not `frame`. A Dock along the bottom edge raises `visibleFrame.minY`, and a
    /// panel measured from `frame` would sit behind it -- on the display Louis is working on,
    /// which is the display whose Dock is showing.
    func testABottomDockPushesThePanelUpInsteadOfHidingItBehindItself() {
        let dockHeight: CGFloat = 80
        let docked = ScreenGeometry(
            frame: external.frame,
            visibleFrame: CGRect(
                x: external.visibleFrame.minX,
                y: external.visibleFrame.minY + dockHeight,
                width: external.visibleFrame.width,
                height: external.visibleFrame.height - dockHeight
            ),
            hasNotch: false
        )
        let frame = StatusSurfaceChoice.frame(size: CGSize(width: 220, height: 34), on: docked)
        XCTAssertEqual(
            frame.minY,
            external.visibleFrame.minY + dockHeight + StatusSurfaceChoice.bottomMargin
        )
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
}
