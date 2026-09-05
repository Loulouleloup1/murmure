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
            addSpeechModelSection
            if model.hasLanguageRows {
                footer
            }
        }
        // The disk, plus one listing read of the local Ollama -- `reload()`'s own doc comment
        // has the reasoning that read is safe on appear. What stays a press (`checkOllama`) is a
        // per-model reachability probe with its own remedy wording, and any download or pull.
        .onAppear { Task { await model.reload() } }
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
    /// **`download` and `delete` stay inert on THIS row -- the shipped speech model's own --
    /// deliberately rather than unfinished.** Re-downloading it from here is 1.6 GB arriving and
    /// deleting it is 1.6 GB of Louis's disk going away; neither could be exercised while this pane
    /// was written (no model may be fetched and nothing may be removed from the real store), and an
    /// action that has never once been run is not an action that has been verified. What the
    /// wiring needs is already decided and tested in `MurmureCore`:
    /// `ModelInventory.removal(for:in:namedByModes:)` gives the two directories to remove — the
    /// variant and its `.cache` sidecars, never the repository root — and the sentence to confirm
    /// with, including the one that warns a mode still names it. Enabling this button is that call
    /// plus a confirmation, behind Louis's eye-gate.
    ///
    /// **`pull` is wired for real.** It is the one button this task could add without downloading
    /// anything itself: asking Ollama to pull is Ollama's own multi-gigabyte transfer, on its own
    /// disk, which this pane only ever triggers and reads progress from -- unlike the speech
    /// download above, nothing here writes to a store this session was told not to touch.
    /// `addSpeechModelSection` below is the other real action this task adds, on its own new
    /// repository-picking rows rather than on this table's existing ones.
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

    // MARK: - Adding a speech model

    /// *"connecter Hugging Face ou alors mettre juste le lien de Hugging Face"* -- Louis's own two
    /// shapes, read by `HuggingFaceRepository.parse`. Always visible, unlike `footer`: a machine
    /// with no refining mode still has exactly one speech model, and this is the one way to add a
    /// second without editing a mode file by hand.
    private var addSpeechModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a speech model")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            HStack(spacing: 8) {
                TextField("owner/repo or a huggingface.co link", text: $model.repositoryInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                            .fill(Color(role: .cardBackground))
                    )
                Button("List") { Task { await model.fetchSpeechModelListing() } }
                    .buttonStyle(.plain)
                    .disabled(model.isFetchingListing || model.repositoryInput.isEmpty)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                            .fill(Color(role: .cardBackground))
                    )
                if model.isFetchingListing {
                    Text("Asking Hugging Face...")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                }
            }
            if let error = model.repositoryInputError {
                caption(error)
            }
            if let listing = model.listing {
                listingRows(listing)
            }
            if let installError = model.installError {
                caption(installError)
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

    /// What a repository answered, decided by `SpeechModelCatalog.fetchListing` and read here
    /// without a second opinion on it: `.derivedVariants` gets its own explanatory caption because
    /// it is the one case that needed research to get right (no `config.json`, listed from the
    /// repository's own files instead -- see that type's doc comment); the other three are told as
    /// plainly as they are named.
    @ViewBuilder
    private func listingRows(_ listing: SpeechModelCatalog.Listing) -> some View {
        switch listing {
        case .variants(let variants):
            ForEach(variants, id: \.self) { variantRow($0) }
        case .derivedVariants(let variants):
            caption("This repository has no WhisperKit support file; listed from its own files instead.")
            ForEach(variants, id: \.self) { variantRow($0) }
        case .none:
            caption("This repository does not look like it has a speech model Murmure could load.")
        case .failure(let detail):
            caption("Could not read this repository: \(detail)")
        }
    }

    /// One offered variant: its name, what pressing Download costs, and the download itself once
    /// it starts.
    ///
    /// **The size column has nothing to print, on purpose.** `WhisperKit`'s listing APIs answer
    /// with names, never sizes, so showing one here would be a number nobody measured -- exactly
    /// the kind of number `ModelSize.readable` exists to print honestly and never to invent. What
    /// is shown instead is the two costs that ARE known before committing: an unmeasured but
    /// certainly non-trivial download, and the machine-specific compile every newly installed
    /// speech model pays once (`ModelInventory.firstUseNotice`).
    private func variantRow(_ variant: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                if model.installingVariant == variant {
                    Text(installStatus)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                } else {
                    Text("""
                        Size unknown before download. On a machine with limited memory, check that \
                        it fits alongside anything else already running before installing it. \
                        First dictation with it will also take several minutes while this Mac \
                        compiles it.
                        """)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.installingVariant == variant {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Download") { Task { await model.install(variant: variant) } }
                    .buttonStyle(.plain)
                    .disabled(model.installingVariant != nil)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
            }
        }
        .padding(.vertical, 4)
    }

    /// What `installProgress` says while a download this pane started is running -- bytes only
    /// when a size is actually known, never a percentage computed against a number that was never
    /// measured for this repository.
    private var installStatus: String {
        guard let progress = model.installProgress else { return "Starting..." }
        switch progress {
        case .downloading(let download):
            return download.expectedBytes > 0
                ? "Downloading -- \(download.percent)%" : "Downloading..."
        case .loading:
            return "Preparing..."
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
