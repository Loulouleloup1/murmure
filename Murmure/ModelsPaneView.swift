import MurmureCore
import SwiftUI

/// Models: a **data table**, the only one in the app (design notes §1.1). Four columns — name, a
/// type glyph, size, and one action column that flips between download and delete.
///
/// **No colour is written in this file** and no number that means anything: every colour goes
/// through `Color(role:)` and every column width through `WindowLayout`, the rule
/// `VocabularyPaneView` and `HistoryPaneView` already follow.
///
/// **No decision is written here either.** Which rows exist, whether a half-downloaded model reads
/// as installed, which of the two Ollama sentences a row carries and which button it offers are
/// all `ModelRow` properties, decided and tested in `MurmureCore`. What is below is the drawing.
///
/// **What §1.1 describes and this deliberately drops.** The installed app's Models library opens
/// on a search field and an `All providers` filter, because it lists a catalogue of dozens of
/// cloud models. Murmure has one speech model and as many language models as Louis has refining
/// modes — three rows, on this machine. A search field over three rows is a control that can only
/// ever hide two of them. The star, lock, provider-avatar and cloud columns go for the reason the
/// notes give: everything here is local and nothing is tier-locked.
struct ModelsPaneView: View {
    @ObservedObject var model: ModelsPaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeaders
            table
            if model.hasLanguageRows {
                footer
            }
        }
        // The disk, and only the disk. The Ollama probe is a press (`checkOllama`), never an
        // appearance -- opening a settings pane must not start a conversation with another
        // process.
        .onAppear { model.reload() }
    }

    // MARK: - The columns

    /// Muted ~11 pt labels, as measured (design notes §1.1). Not sortable: sorting is worth a
    /// caret when the table is a catalogue, and `ModelInventory.table` already fixes the one order
    /// three rows can meaningfully have.
    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("Model name")
                .frame(minWidth: WindowLayout.modelsNameMinimum, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Type")
                .frame(width: WindowLayout.modelsColumns.type, alignment: .leading)
            Text("Size")
                .frame(width: WindowLayout.modelsColumns.size, alignment: .trailing)
            // The action column's header is empty: the button under it says what it does, and a
            // word above two icons that already differ would be a label for nothing.
            Color.clear
                .frame(width: WindowLayout.modelsColumns.action)
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(Color(role: .secondaryText))
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.rows) { row in
                    self.row(row)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .background(Color(role: .paneBackground))
    }

    // MARK: - One row

    private func row(_ row: ModelRow) -> some View {
        HStack(spacing: 0) {
            name(row)
                .frame(minWidth: WindowLayout.modelsNameMinimum, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            typeGlyph(row.kind)
                .frame(width: WindowLayout.modelsColumns.type, alignment: .leading)
            Text(row.size ?? "--")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
                .frame(width: WindowLayout.modelsColumns.size, alignment: .trailing)
            action(row)
                .frame(width: WindowLayout.modelsColumns.action)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.rowCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
        )
    }

    /// The name, and under it the one sentence the row has to say — why a download is incomplete,
    /// which `ollama pull` is missing, or that Ollama has not been asked yet. `ModelRow.detail`
    /// decides which; this only knows whether there is one.
    private func name(_ row: ModelRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `Type` is a mark and never a word (design notes §1.1): a waveform for the model that
    /// listens, stacked lines for the one that writes. Two families, one column, zero text — the
    /// accessibility label is where the word goes.
    ///
    /// The tile is the machinery pair, matching the sidebar row this pane sits under: Models is a
    /// machinery section, and a coloured tile here would say it was a material one.
    private func typeGlyph(_ kind: ModelKind) -> some View {
        Image(systemName: kind == .speech ? "waveform" : "text.alignleft")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(role: .machineryGlyph))
            .frame(width: WindowLayout.sidebarTileSize, height: WindowLayout.sidebarTileSize)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .machineryTile))
            )
            .accessibilityLabel(kind == .speech ? "Speech model" : "Language model")
    }

    /// The single action column, doing the two jobs §1.1 describes plus Murmure's third.
    ///
    /// **Both buttons are inert in this task, and that is deliberate rather than unfinished.**
    /// Deleting is 1.6 GB of Louis's disk going away and downloading is 1.6 GB arriving; neither
    /// could be exercised while this pane was written (no model may be fetched and nothing may be
    /// removed from the real store), and an action that has never once been run is not an action
    /// that has been verified. What the wiring needs is already decided and tested in
    /// `MurmureCore`: `ModelInventory.removal(for:in:)` gives the two directories to remove — the
    /// variant and its `.cache` sidecars, never the repository root — and the sentence to confirm
    /// with. Enabling this button is that call plus a confirmation, behind Louis's eye-gate.
    @ViewBuilder
    private func action(_ row: ModelRow) -> some View {
        switch row.action {
        case .download:
            actionButton(
                "arrow.down.circle", label: "Download \(row.name)",
                help: "Downloading from this pane is not wired yet.")
        case .delete:
            actionButton(
                "trash", label: "Delete \(row.name)",
                help: "Deleting from this pane is not wired yet.")
        // Ollama's store is Ollama's. `ollama pull` and `ollama rm` are the only two things that
        // move it, so this row shows the state and no button that would imply otherwise.
        case .managedElsewhere:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func actionButton(_ symbol: String, label: String, help: String) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color(role: .secondaryText))
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: - The Ollama check

    /// One press, and the reason it is a press rather than an `onAppear` is in
    /// `ModelsPaneModel.checkOllama`.
    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.hasChecked ? "Check Ollama again" : "Check Ollama") {
                Task { await model.checkOllama() }
            }
            .buttonStyle(.plain)
            .disabled(model.isChecking)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color(role: .primaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .cardBackground))
            )
            if model.isChecking {
                Text("Asking Ollama...")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(role: .hairline))
                .frame(height: WindowLayout.hairlineWidth)
        }
    }
}
