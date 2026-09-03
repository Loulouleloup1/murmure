import XCTest
@testable import MurmureCore

/// The microphone row, which is a report and not a control.
///
/// Small, because the decision is small — but it is the decision that replaced a picker, and the
/// cases below are what stop it drifting back into looking like one.
final class MicrophoneStatusTests: XCTestCase {
    /// The suffix is the whole difference between a report and a control. A bare device name
    /// sitting where a picker would be invites a click; `(system input)` says where the answer
    /// comes from and, by saying it, that Murmure is not the thing that decides it.
    func testTheRowNamesTheDeviceAndSaysWhereTheAnswerComesFrom() {
        XCTAssertEqual(
            MicrophoneStatus.line(defaultDeviceName: "MacBook Pro Microphone"),
            "MacBook Pro Microphone (system input)")
    }

    /// A Mac with nothing plugged in gets a sentence, not a blank or a dash. It is the state the
    /// next dictation fails in, and this row is the only place it is visible beforehand.
    func testNoDeviceGetsASentenceRatherThanAnEmptyRow() {
        XCTAssertEqual(
            MicrophoneStatus.line(defaultDeviceName: nil), "No microphone is connected")
    }

    /// `AVCaptureDevice.localizedName` is a string from another process's plist and can be empty;
    /// an empty name is the same news as no device, and must not draw as " (system input)".
    func testAnEmptyNameIsTreatedAsNoDeviceRatherThanPrintedAsOne() {
        XCTAssertEqual(
            MicrophoneStatus.line(defaultDeviceName: ""), "No microphone is connected")
    }

    /// The row is read-only, so the note is the only thing that stops it being a dead end: the
    /// reasonable move on seeing the wrong microphone named is to look for what changes it, and it
    /// has to say that it is not here.
    func testTheNoteNamesWhereTheChoiceActuallyLives() {
        XCTAssertTrue(MicrophoneStatus.note.contains("System Settings"))
        XCTAssertTrue(MicrophoneStatus.note.contains("Input"))
    }

    /// The label is a verb phrase, not a noun. "Microphone" would read as the name of a setting,
    /// which is the reading the whole row exists to avoid.
    func testTheLabelReadsAsAReportAndNotAsASettingName() {
        XCTAssertEqual(MicrophoneStatus.label, "Recording from")
    }
}
