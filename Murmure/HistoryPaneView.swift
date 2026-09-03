import MurmureCore
import SwiftUI

/// History: the list on the left, one dictation on the right (D9).
///
/// Two panes and not the doc corpus's three. Their third is a metadata inspector whose rows are
/// largely things Murmure does not have -- cloud voice model, separate-speakers, system-audio,
/// tier, app version -- and what survives is about six rows, which fits under the transcript.
///
/// **No colour is written in this file.** Every one goes through `Color(role:)`, which is the
/// condition attached to shipping the window dark-only (Q-NB6): light mode is a second table in
/// `WindowPalette`, and a single `Color(white: 0.2)` written here is what would turn that into
/// five panes to revisit.
struct HistoryPaneView: View {
    @ObservedObject var model: HistoryPaneModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: HistoryLayout.listWidth.ideal)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        // A dictation made while the window is open writes a row the pane would otherwise not
        // show until Louis navigated away and back.
        //
        // Watched on the ROW COUNTER and not on `appState.status`, which is the obvious cue and
        // the wrong one: `DictationSession.finishRecording` transitions to `.completed` and
        // `.idle` and only then awaits `archive(...)`, so a reload on `.idle` races the insert and
        // draws a list missing the dictation that just ended.
        .onChange(of: appState.historyRevision) { _, _ in model.reload() }
    }

    // MARK: - The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HistoryLayout.rowSpacing) {
                ForEach(model.groups) { group in
                    // The date header sits OUTSIDE and above the cards (design notes §1.3), muted
                    // and small. It is not a card and it is not a rule.
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                        .padding(.top, group.id == model.groups.first?.id
                            ? 0 : HistoryLayout.groupHeaderSpacing)
                        .padding(.leading, HistoryLayout.rowPadding.horizontal)
                    ForEach(group.records, id: \.id) { record in
                        row(record)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .background(Color(role: .paneBackground))
        .overlay { if let message = model.emptyListMessage { emptyList(message) } }
    }

    /// Two lines: one truncated line of transcript, then date · time with the duration at the
    /// right edge (D10). Against the installed app, which renders only the excerpt -- see
    /// `HistoryRow`.
    private func row(_ record: HistoryRecord) -> some View {
        let isSelected = record.id != nil && record.id == model.selectedID
        return Button {
            model.selectedID = record.id
            model.resetLens()
            model.stopPlayback()
        } label: {
            VStack(alignment: .leading, spacing: HistoryLayout.rowLineSpacing) {
                Text(HistoryRow.preview(for: record))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(HistoryRow.timestamp(for: record.startedAt, calendar: .current))
                    Spacer(minLength: 8)
                    Text(HistoryRow.duration(record.durationSeconds))
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            }
            .padding(.horizontal, HistoryLayout.rowPadding.horizontal)
            .padding(.vertical, HistoryLayout.rowPadding.vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: WindowLayout.rowCornerRadius, style: .continuous
                ).fill(Color(role: .cardBackground))
            )
            // **A ring, not a fill.** A filled row would be the third strong colour in the window
            // -- the sidebar's selected row already carries the accent -- and it would compete
            // with the transcript, which is the row's identity.
            .overlay(
                RoundedRectangle(cornerRadius: WindowLayout.rowCornerRadius, style: .continuous)
                    .strokeBorder(
                        Color(role: .selection),
                        lineWidth: isSelected ? HistoryLayout.selectionRingWidth : 0)
            )
        }
        .buttonStyle(.plain)
    }

    /// The list has nothing in it, which is four different events and one of them is an archive
    /// that would not open. **Which sentence that is, is not decided here** -- it is
    /// `HistoryEmptyState`, in `MurmureCore`, where the four can be walked by a test. This view
    /// draws the sentence and no more.
    ///
    /// Kept narrow: these run to two lines, and a wrapped sentence centred across a 900 pt pane
    /// is a sentence nobody's eye tracks back to the start of.
    private func emptyList(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .multilineTextAlignment(.center)
            .frame(maxWidth: HistoryLayout.listWidth.ideal - 48)
            .padding(24)
    }

    // MARK: - The detail

    @ViewBuilder
    private var detail: some View {
        if let record = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                transcript(of: record)
                // A re-refinement that could not run, a delete that failed, a WAV that would not
                // play. Shown HERE and not only over an empty list, because none of those empties
                // the list -- and a failure held in a property nothing draws is a failure that
                // did not happen as far as Louis is concerned.
                if let problem = model.problem {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(problem).lineLimit(3)
                        Spacer(minLength: 8)
                        Button("Dismiss") { model.dismissProblem() }
                            .buttonStyle(.plain)
                    }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
                actions(for: record)
            }
            .background(Color(role: .paneBackground))
        } else {
            Color(role: .paneBackground)
        }
    }

    private func transcript(of record: HistoryRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                lensSwitch(for: record)
                Text(HistoryDetail.text(model.lens, of: record) ?? "")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                    .lineSpacing(HistoryLayout.transcriptLineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: HistoryLayout.transcriptMeasure, alignment: .leading)
                metadata(of: record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    /// D11: shown only when there is a refinement to switch TO, and absent rather than disabled
    /// when there is not. The rule that decides is `HistoryDetail.lenses` -- it compares the two
    /// texts **trimmed**, because a refinement that changed nothing but the edges would otherwise
    /// offer two panes that look identical.
    @ViewBuilder
    private func lensSwitch(for record: HistoryRecord) -> some View {
        let lenses = HistoryDetail.lenses(for: record)
        if !lenses.isEmpty {
            Picker("", selection: $model.lens) {
                ForEach(lenses, id: \.self) { lens in
                    Text(lens.title).tag(lens)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private func metadata(of record: HistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(HistoryDetail.metadata(for: record, calendar: .current)) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .foregroundStyle(Color(role: .secondaryText))
                        .frame(width: 110, alignment: .leading)
                    Text(row.value)
                        .foregroundStyle(Color(role: .primaryText))
                        .textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12, design: .rounded))
        .padding(14)
        .frame(maxWidth: HistoryLayout.transcriptMeasure, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.surfaceCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
        )
    }

    // MARK: - The actions

    @State private var confirmingDelete = false

    private func actions(for record: HistoryRecord) -> some View {
        let audio = model.audioURL(for: record)
        return HStack(spacing: 8) {
            action("Copy", "doc.on.doc") { model.copySelection() }
                .disabled(HistoryDetail.text(model.lens, of: record) == nil)
            // Both audio actions go the same way the day the WAV does, which is three days after
            // the dictation (the retention policy of 2026-09-01). Disabled rather than hidden:
            // a button that comes and goes is a button Louis has to look for.
            action(model.isPlaying ? "Stop" : "Play",
                   model.isPlaying ? "stop.fill" : "play.fill") { model.togglePlayback() }
                .disabled(audio == nil)
            action("Reveal audio", "folder") { model.revealAudio() }
                .disabled(audio == nil)

            Spacer(minLength: 12)

            processAgain(for: record)

            action("Delete", "trash") { confirmingDelete = true }
                .confirmationDialog(
                    "Delete this dictation?", isPresented: $confirmingDelete
                ) {
                    Button("Delete", role: .destructive) { model.deleteSelection() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // Says what it destroys, both halves, because the audio goes with the row and
                    // neither comes back.
                    Text(audio == nil
                        ? "The transcript will be removed. This cannot be undone."
                        : "The transcript and its recording will be removed. "
                            + "This cannot be undone.")
                }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(role: .hairline))
                .frame(height: WindowLayout.hairlineWidth)
        }
    }

    /// D12, and the reason it is a menu rather than a button: a re-refinement is only useful when
    /// it runs through a *different* mode -- it is how a dictation refined by the wrong one gets
    /// fixed -- so picking the mode is the action, not a setting beside it.
    ///
    /// Only modes that have a refiner are offered: a transcribe-only mode would hand the
    /// transcript straight back.
    @ViewBuilder
    private func processAgain(for record: HistoryRecord) -> some View {
        let modes = model.refiningModes(from: appState.availableModes)
        Menu {
            ForEach(modes, id: \.key) { mode in
                Button(mode.name) {
                    Task { await model.processAgain(with: mode) }
                }
            }
        } label: {
            Label(model.isProcessing ? "Processing…" : "Process again", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(modes.isEmpty || model.isProcessing || !HistoryDetail.canProcessAgain(record))
    }

    private func action(_ title: String, _ symbol: String, run: @escaping () -> Void)
        -> some View
    {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(role: .secondaryText))
    }
}

/// The search field that IS the section header for a list section (design notes §1.4).
///
/// Its own view rather than a branch inside `MainWindowView.header`, because Models gets the same
/// slot and the same treatment in T8, and because the focus state below has to belong to
/// something.
struct HistorySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(role: .secondaryText))
            TextField("Search history", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(role: .secondaryText))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
        )
    }
}
