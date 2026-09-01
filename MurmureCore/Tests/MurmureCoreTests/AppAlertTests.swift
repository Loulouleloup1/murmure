import XCTest
@testable import MurmureCore

final class AppAlertTests: XCTestCase {
    /// Without ⌥Space no dictation can start, so the Accessibility problem is real and
    /// unreachable. Fixing them in this order terminates; the other order sends Louis to grant a
    /// permission and press a key that still does nothing.
    func testTheHotkeyOutranksAccessibilityWhenBothAreStanding() {
        XCTAssertEqual(
            AppAlert.mostSevere(among: [.accessibilityDenied, .hotkeyUnavailable]),
            .hotkeyUnavailable)
        XCTAssertEqual(
            AppAlert.mostSevere(among: [.hotkeyUnavailable, .accessibilityDenied]),
            .hotkeyUnavailable)
    }

    func testOneStandingAlertIsItsOwnAnswerAndNoneIsNil() {
        XCTAssertEqual(AppAlert.mostSevere(among: [.accessibilityDenied]), .accessibilityDenied)
        XCTAssertNil(AppAlert.mostSevere(among: []))
    }

    /// The ranking is the declaration order, which is a fact about the source rather than about
    /// this list -- so a case added in the wrong place is caught here rather than by Louis.
    func testEveryAlertIsRankedAndTheRankingIsTotal() {
        for alert in AppAlert.allCases {
            XCTAssertEqual(AppAlert.mostSevere(among: [alert]), alert)
        }
        XCTAssertEqual(AppAlert.allCases, [.hotkeyUnavailable, .accessibilityDenied])
    }

    /// The deep link, checked as a URL rather than as a string. `NSWorkspace.open` cannot cross
    /// into this package; a typo in the value can, and it opens nothing at all without reporting
    /// anything -- the silent failure this suite keeps catching.
    func testTheAccessibilityAlertCarriesAParsableDeepLinkToTheRightPane() throws {
        let raw = try XCTUnwrap(AppAlert.accessibilityDenied.settingsURL)
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        // The pane identifier and its anchor, which is the whole address: the pane alone opens
        // Privacy & Security at the top of a list Accessibility is some way down.
        XCTAssertEqual(url.absoluteString.hasSuffix("Privacy_Accessibility"), true)
        XCTAssertTrue(raw.contains("com.apple.preference.security"))
    }

    /// The hotkey alert has no button, and that is a decision rather than an omission: nothing
    /// Murmure can open takes the combination back from the application holding it.
    func testTheHotkeyAlertOffersNothingToClick() {
        XCTAssertNil(AppAlert.hotkeyUnavailable.settingsURL)
        XCTAssertNil(AppAlert.hotkeyUnavailable.actionTitle)
    }

    /// A button title without a destination is a control that does nothing; a destination without
    /// a title is a link with nothing to click. Neither can be shipped by halves.
    func testEveryAlertEitherHasBothAButtonAndADestinationOrNeither() {
        for alert in AppAlert.allCases {
            XCTAssertEqual(
                alert.actionTitle == nil, alert.settingsURL == nil,
                "\(alert) has a button and no destination, or the reverse")
        }
    }

    /// Every alert says something. An empty message would draw a panel with a button and no
    /// reason for it.
    func testEveryAlertSaysSomething() {
        for alert in AppAlert.allCases {
            XCTAssertFalse(alert.message.isEmpty, "\(alert) has no message")
        }
    }

    /// The transient surface renders an alert through `StatusPanelText`, which collapses
    /// whitespace and would silently swallow a message written across two lines: a strip 34 pt
    /// tall does not wrap, it pushes the rest out of the panel.
    func testEveryAlertMessageSurvivesTheOneLineSurfaceUnchanged() {
        for alert in AppAlert.allCases {
            XCTAssertEqual(
                StatusPanelText.label(for: .alert(message: alert.message)), alert.message,
                "\(alert)'s message is reshaped by the strip")
        }
    }
}
