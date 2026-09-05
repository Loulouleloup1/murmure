import XCTest
@testable import MurmureCore

/// `ContextSource` is the one place a toggle's field, its model-facing label, its editor
/// description and its preview placeholder are named -- so a rename of one cannot silently leave
/// the other three behind.
final class ContextSourceTests: XCTestCase {
    private func mode(selectedText: Bool, clipboard: Bool, appContext: Bool) -> Mode {
        var mode = Mode.voice
        mode.context = .init(selectedText: selectedText, clipboard: clipboard, appContext: appContext)
        return mode
    }

    func testIsEnabledReadsItsOwnField() {
        let mode = mode(selectedText: true, clipboard: false, appContext: true)

        XCTAssertTrue(ContextSource.selectedText.isEnabled(for: mode))
        XCTAssertFalse(ContextSource.clipboard.isEnabled(for: mode))
        XCTAssertTrue(ContextSource.frontmostApp.isEnabled(for: mode))
    }

    /// Selected text and the clipboard get their own line, because either can run to several
    /// sentences; the frontmost application is a name and reads better inline.
    func testSectionFormatDiffersOnlyForTheFrontmostApplication() {
        XCTAssertEqual(ContextSource.selectedText.section(body: "hello"), "Selected text:\nhello")
        XCTAssertEqual(ContextSource.clipboard.section(body: "hello"), "Clipboard:\nhello")
        XCTAssertEqual(ContextSource.frontmostApp.section(body: "Xcode"), "Frontmost application: Xcode")
    }

    /// The placeholder names the section and says when it fills in -- never real text, since
    /// nothing has been captured while the editor is open.
    func testPlaceholderNamesTheSourceAndWhenItFillsIn() {
        for source in ContextSource.allCases {
            let placeholder = source.placeholder
            XCTAssertTrue(placeholder.hasPrefix("[\(source.label) —"), placeholder)
            XCTAssertTrue(placeholder.contains("captured when you start recording"), placeholder)
        }
    }

    func testEveryDescriptionIsNonEmptyAndDistinct() {
        let descriptions = ContextSource.allCases.map(\.description)
        XCTAssertFalse(descriptions.contains { $0.isEmpty })
        XCTAssertEqual(Set(descriptions).count, descriptions.count)
    }

    /// The answer to "it does not seem to work with s1": named where the toggles are drawn, so
    /// the reason is on screen rather than left to be worked out by trial and error.
    ///
    /// Asserts the "fixed by the model card" clause specifically, not merely a substring the
    /// earlier (false) wording -- "the s1-mini API takes no system turn" -- would also have
    /// matched (review, lot 3a, item 2): s1 does have a system turn, `OllamaS1.conversation`
    /// writes one, and the preview's own "System prompt" block shows it. What actually closes off
    /// context is that the turn is fixed rather than absent.
    func testS1DisabledReasonNamesWhyTheTurnIsFixedAndTheEscapeHatch() {
        let reason = ContextSource.s1DisabledReason
        XCTAssertTrue(reason.contains("fixed by the model card"))
        XCTAssertFalse(reason.contains("takes no system turn"))
        XCTAssertTrue(reason.contains("chat"))
        XCTAssertTrue(reason.contains("gemma4:12b-it-qat"))
    }
}
