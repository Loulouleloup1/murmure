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
            if let error = model.installError {
                deletionError(error)
            }
            addModelSection
            if model.hasLanguageRows {
                footer
            }
        }
        // The disk, plus one listing read of the local Ollama -- `reload()`'s own doc comment
        // has the reasoning that read is safe on appear. What stays a press (`checkOllama`) is a
        // per-model reachability probe with its own remedy wording, and any download or pull.
        .onAppear { Task { await model.reload() } }
        .sheet(isPresented: Binding(
            get: { model.inspection != nil },
            set: { if !$0 { model.dismissInspection() } }
        )) {
            InspectSheetView(model: model)
        }
        // Matches the app's other two destructive confirmations (`ModesPaneView`,
        // `AdvancedPaneView`): a short title naming the row, the full sentence as the message, and
        // the destructive button declared FIRST so it is the one nearest the reader's eye rather
        // than an afterthought beside Cancel.
        .alert(
            model.pendingRemoval.map { "Delete \($0.row.name)?" } ?? "",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.cancelDeletion() } })
        ) {
            Button("Delete", role: .destructive) { Task { await model.confirmDeletion() } }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text(model.pendingRemoval?.removal.question ?? "")
        }
    }

    /// A delete that did not happen -- drawn here, outside the Inspect sheet, because deleting a
    /// row is a table action and Louis is looking at the table when it fails, not at a sheet that
    /// is not open. Same shape `AdvancedPaneView.note` already uses for its own failures.
    private func deletionError(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(Color(role: .secondaryText))
        .padding(.horizontal, 22)
        .padding(.top, 8)
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
            // A pull in progress or a pull that just failed takes over the second line -- it is
            // the more current story about this row than the static sentence `detail` carries for
            // the same "not installed" state. `firstUseNotice` is speech-only and `detail` is
            // already `nil` whenever it would apply, so the three never compete for real.
            if let secondary = model.pullStatus(for: row.identifier) ?? row.detail ?? row.firstUseNotice {
                Text(secondary)
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
    /// **`download` stays inert.** Re-downloading an existing row from here is a second way to
    /// fetch the same bytes `addModelSection`'s Install button already fetches, and this task's
    /// scope is "add a model" and "delete a model", not a third download path for a row already on
    /// the table.
    ///
    /// **`delete` is wired for real.** `model.requestDeletion(of:)` computes the confirmation
    /// (`ModelInventory.removal`/`removal(forLanguageModel:)`, the sentence that names a mode still
    /// pointing at this model) and the view's own `.alert` asks before anything is removed.
    ///
    /// **`pull` is wired for real.** Asking Ollama to pull is Ollama's own multi-gigabyte transfer,
    /// on its own disk, which this pane only ever triggers and reads progress from.
    @ViewBuilder
    private func action(_ row: ModelRow) -> some View {
        switch row.action {
        case .download:
            actionButton(
                "arrow.down.circle", label: "Download \(row.name)",
                help: "Downloading an existing row from this pane is not wired yet -- use \"Add a model\" above.")
        case .delete:
            Button {
                model.requestDeletion(of: row)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(role: .secondaryText))
            }
            .buttonStyle(.plain)
            .help("Delete \(row.name).")
            .accessibilityLabel("Delete \(row.name)")
        // The one language button that is real: asking Ollama to pull what it does not have.
        // Pulling does NOT license a delete button next to it -- Ollama's store stays Ollama's,
        // and `ollama rm` remains the only thing that removes from it (see `managedElsewhere`
        // below, which is every OTHER language state, delete included).
        case .pull:
            if model.isPulling(row.identifier) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: WindowLayout.sidebarTileSize, height: WindowLayout.sidebarTileSize)
            } else {
                Button {
                    Task { await model.pull(modelIdentifier: row.identifier) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(role: .secondaryText))
                }
                .buttonStyle(.plain)
                .help("Pull \(row.name) with Ollama.")
                .accessibilityLabel("Pull \(row.name)")
            }
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

    // MARK: - Adding a model

    /// One field, any of Louis's own three shapes: *"connecter Hugging Face ou alors mettre juste
    /// le lien de Hugging Face"*, or an Ollama name. Always visible, unlike `footer`: a machine
    /// with no refining mode still has exactly one speech model, and this is the one way to add
    /// another model of either kind without editing a mode file by hand.
    ///
    /// Only the field and the press live here -- everything "Inspect" found is the sheet
    /// (`InspectSheetView`), which owns its own layout rather than growing this one downward every
    /// time a repository answers with more to show.
    private var addModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a model")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            HStack(spacing: 8) {
                TextField("owner/repo, a huggingface.co link, or an Ollama model name", text: $model.addModelInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                            .fill(Color(role: .cardBackground))
                    )
                Button("Inspect") { Task { await model.inspect() } }
                    .buttonStyle(.plain)
                    .disabled(model.isInspecting || model.addModelInput.isEmpty)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                            .fill(Color(role: .cardBackground))
                    )
                if model.isInspecting {
                    Text("Asking Hugging Face...")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                }
            }
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
