import MurmureCore
import SwiftUI

/// General: the shortcut, the microphone, the login item, the two sounds.
///
/// **No colour is written in this file.** Every one goes through `Color(role:)`, the rule
/// `HistoryPaneView`, `VocabularyPaneView` and `ModesPaneView` all follow and for the same reason
/// (Q-NB6): dark-only is cheap now and expensive to retrofit, and the difference between the two is
/// entirely whether the colours are in one table or spread across six panes.
///
/// The microphone row is a **report drawn as a row, not a control**. It deliberately does not
/// look like a picker -- there is nothing to click, and the note under it says why, which is the
/// difference between a decision and a control that appears broken.
struct GeneralPaneView: View {
    @ObservedObject var model: GeneralPaneModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hotkeyRow
                microphoneRow
                launchRow
                soundRows
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(role: .paneBackground))
        .onAppear { model.refresh() }
        // The monitor `startRecordingHotkey()` installs is local to this window; the pane leaving
        // the screen -- another section picked, the window closed -- must stop it, or it goes on
        // swallowing every keystroke Murmure's window receives with nothing left on screen to say
        // why. `GeneralPaneModel.deinit` is the same removal for the case this never fires.
        .onDisappear { model.stopRecordingHotkey() }
    }

    // MARK: - The hotkey

    /// One chip per key, never a concatenated string (design notes §2). The decomposition and the
    /// ⌃⌥⇧⌘ order are `Keycap`'s, tested there; this only draws them, beside the Record button
    /// that captures a new combination.
    private var hotkeyRow: some View {
        row("Start and stop dictation", note: model.hotkeyNote) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(model.toggleKeycaps.enumerated()), id: \.offset) { _, cap in
                        keycap(cap)
                    }
                }
                Button(model.isRecordingHotkey ? "Cancel" : "Record") {
                    if model.isRecordingHotkey {
                        model.stopRecordingHotkey()
                    } else {
                        model.startRecordingHotkey()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// 18 × 18 pt for a glyph, and as wide as its text plus a little for a word key — the two
    /// widths design notes §2 measured, which is the whole reason `Keycap` distinguishes them.
    /// A `frame(minWidth:)` rather than a fixed one, so `Page Down` grows and `⌘` does not.
    private func keycap(_ cap: Keycap) -> some View {
        Text(cap.label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color(role: .primaryText))
            .padding(.horizontal, cap.shape == .glyph ? 0 : Keycap.wordHorizontalPadding)
            .frame(minWidth: Keycap.glyphWidth, minHeight: Keycap.height)
            .frame(height: Keycap.height)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .cardBackground))
            )
    }

    // MARK: - The microphone

    /// A report, and drawn as one: text where a picker would be, with the note saying where the
    /// choice actually lives. `MicrophoneStatus` owns both sentences.
    private var microphoneRow: some View {
        row(MicrophoneStatus.label, note: MicrophoneStatus.note) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.microphoneLine)
                    .font(.system(size: 13, design: .rounded))
            }
            .foregroundStyle(Color(role: .primaryText))
        }
    }

    // MARK: - Launch at login

    private var launchRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(
                "Start Murmure when I log in",
                note: "Murmure is a hotkey daemon with no Dock icon — it is only useful while it "
                    + "is running."
            ) {
                Toggle("", isOn: model.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            // macOS is refusing until Louis says yes in System Settings. Without this the row is a
            // switch that will not stay where it is put, with nothing anywhere saying why.
            if let approval = model.loginApprovalNote {
                inlineNote(approval, url: LoginItem.settingsURL, action: "Open Login Items")
            }
            if let problem = model.loginProblem {
                inlineNote(problem, url: nil, action: nil)
            }
        }
    }

    // MARK: - The two sounds

    /// One row per `FeedbackCue`, walked rather than written twice: the list of sounds is
    /// `FeedbackCue`'s, so a third one appears here without this file changing.
    private var soundRows: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(FeedbackCue.allCases, id: \.self) { cue in
                let text = model.soundRow(cue)
                row(text.title, note: text.note) {
                    Toggle("", isOn: model.soundEnabled(cue))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Building blocks

    /// A label, the control or report on the right, and the sentence under it.
    ///
    /// **Every row carries its note**, which is a departure from the installed app: design notes
    /// §2 records a `?`-in-circle glyph there and "no per-row explanatory paragraph anywhere". Two
    /// of these rows are reports rather than controls and one of them destroys a login-item
    /// registration, so the explanation is the row rather than something behind a hover.
    private func row(
        _ label: String, note: String?, @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                Spacer(minLength: 8)
                control()
            }
            if let note {
                Text(note)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// A sentence that is about something being wrong, with the one thing that can be done about
    /// it when there is one. Same shape the menu uses for `AppAlert`: the label and the
    /// destination are unwrapped together, because a link with no title does nothing and a title
    /// with no link says nothing.
    private func inlineNote(_ message: String, url: String?, action: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if let action, let url, let destination = URL(string: url) {
                Button(action) { NSWorkspace.shared.open(destination) }
                    .buttonStyle(.plain)
                    .underline()
            }
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(Color(role: .secondaryText))
        .frame(maxWidth: 520, alignment: .leading)
    }
}
