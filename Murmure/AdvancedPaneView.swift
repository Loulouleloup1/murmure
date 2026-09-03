import AppKit
import MurmureCore
import SwiftUI

/// Advanced: what happens to a transcript, where the files are, and the two ways to destroy things.
///
/// **No colour is written in this file** (Q-NB6), like every other pane.
///
/// The three groups are in that order deliberately: the settings are what Louis came for, the
/// folders are harmless, and the two erasures are last because a destructive button is not
/// something to scroll past on the way to a toggle.
struct AdvancedPaneView: View {
    @ObservedObject var model: AdvancedPaneModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pasteBehaviourRow
                clipboardRow
                Divider().overlay(Color(role: .hairline))
                revealRows
                Divider().overlay(Color(role: .hairline))
                clearingRows
                if let outcome = model.outcome {
                    note(outcome, isProblem: false)
                }
                if let problem = model.problem {
                    note(problem, isProblem: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(role: .paneBackground))
        .onAppear { model.refresh() }
        // The dialog for the one erasure that asks. Driven from `model.confirmation` being
        // non-nil, and every string in it comes off `HistoryClearing` -- including the button,
        // which repeats the action rather than saying OK, so the last thing read before the click
        // is still the name of what is about to happen.
        .alert(
            model.confirmation?.title ?? "",
            isPresented: Binding(
                get: { model.confirmation != nil },
                set: { if !$0 { model.dismissConfirmation() } })
        ) {
            if let prompt = model.confirmation {
                Button(prompt.confirmTitle, role: .destructive) { model.confirmPending() }
                Button(prompt.cancelTitle, role: .cancel) { model.dismissConfirmation() }
            }
        } message: {
            if let prompt = model.confirmation {
                Text(prompt.message)
            }
        }
    }

    // MARK: - Insertion

    /// Two cases, drawn as two radio rows rather than a segmented control: each needs its own
    /// sentence (one requires Accessibility, the other requires nothing at all), and a segmented
    /// picker has nowhere to put them.
    private var pasteBehaviourRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When a dictation finishes")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            // Walked rather than written twice, so a third behaviour appears here without this
            // file changing -- and `AppSettings.willRestoreClipboard` is written without a
            // `default` so it would have to answer the clipboard question too.
            ForEach(PasteBehaviour.allCases, id: \.self) { behaviour in
                behaviourRow(behaviour)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func behaviourRow(_ behaviour: PasteBehaviour) -> some View {
        let isChosen = model.pasteBehaviour.wrappedValue == behaviour
        return Button {
            model.pasteBehaviour.wrappedValue = behaviour
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        Color(role: isChosen ? .selection : .secondaryText))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label(for: behaviour))
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(role: .primaryText))
                    Text(model.note(for: behaviour))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.rowCornerRadius, style: .continuous)
                    .fill(isChosen ? Color(role: .cardBackground) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    /// Disabled under copy-only rather than quietly overridden — see
    /// `AdvancedPaneModel.canRestoreClipboard`. The note takes the place of the row's usual one so
    /// the greying always has a reason beside it.
    private var clipboardRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Put my clipboard back afterwards")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        Color(role: model.canRestoreClipboard ? .primaryText : .secondaryText))
                Spacer(minLength: 8)
                Toggle("", isOn: model.restoreClipboardAfterPaste)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.canRestoreClipboard)
            }
            Text(
                model.clipboardDisabledNote
                    ?? "Murmure borrows the clipboard to paste and hands it straight back. Turn "
                        + "this off to leave the transcript on it."
            )
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    // MARK: - Reveal

    /// The three folders, walked off `RevealTarget.allCases` so a fourth needs no change here.
    ///
    /// Design notes §6's closing sentence is the reason they exist: Application Support is more
    /// correct than `~/Documents` "but it does hide them", and these files are meant to be opened
    /// in a text editor.
    private var revealRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            HStack(spacing: 8) {
                ForEach(RevealTarget.allCases, id: \.self) { target in
                    Button(target.buttonTitle) { model.reveal(target) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(
                                cornerRadius: WindowLayout.chipCornerRadius, style: .continuous
                            )
                            .fill(Color(role: .cardBackground))
                        )
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: - The two erasures

    /// One row per `HistoryClearing` case, walked rather than written twice — so the pane cannot
    /// end up offering one of them and not the other, and so the ellipsis rule stays where it was
    /// decided.
    private var clearingRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete history")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            ForEach(HistoryClearing.allCases, id: \.self) { action in
                clearingRow(action)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// **The title comes off `HistoryClearing.buttonTitle` and is never written here**, ellipsis
    /// included: that `…` is derived from `requiresConfirmation`, so a button that acts
    /// immediately cannot wear one. It is the only warning that there is no second chance coming.
    ///
    /// The summary is under BOTH buttons, not only the one that asks — the action without a dialog
    /// is precisely the one whose only chance to explain itself is before the click.
    private func clearingRow(_ action: HistoryClearing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button(action.buttonTitle) { model.press(action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(
                            cornerRadius: WindowLayout.chipCornerRadius, style: .continuous
                        )
                        .fill(Color(role: .cardBackground))
                    )
                    .disabled(!model.isEnabled(action))
                    .opacity(model.isEnabled(action) ? 1 : 0.4)
                Spacer(minLength: 0)
                if model.isClearing {
                    ProgressView().controlSize(.small)
                }
            }
            Text(action.summary)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ message: String, isProblem: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isProblem ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(Color(role: .secondaryText))
        .frame(maxWidth: 520, alignment: .leading)
    }
}
