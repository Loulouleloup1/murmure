import MurmureCore
import SwiftUI

/// Modes: a card per mode, an editor that opens **inside** the card, and an advanced screen pushed
/// over the pane (design notes §5, plan T7).
///
/// The ladder is basic → advanced, and it is the shape the doc corpus shows. Only the *list* was
/// ever captured from the installed app; the editor below is the documentation's, which the notes
/// mark as possibly stale — so what is copied is the row (glyph, name, active dot, stage badges)
/// and what is reasoned from Murmure's own schema is everything under it.
///
/// **No colour is written in this file.** Every one goes through `Color(role:)`, the same rule
/// `HistoryPaneView` and `VocabularyPaneView` follow and for the same reason (Q-NB6).
///
/// `AppState` is read from the environment rather than passed: `MainWindowView` already holds it,
/// and the one thing this pane needs from it — which mode is running — is a single key.
struct ModesPaneView: View {
    @ObservedObject var model: ModesPaneModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            list
            if model.screen == .advanced, model.draft != nil {
                advanced
                    // A push, not a sheet: it comes in from the trailing edge and the sidebar
                    // never moves (design notes §1.4, observed). A sheet would darken the window
                    // and take the sidebar with it, which is what makes a sheet feel like leaving.
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.screen)
        // Re-read every time the pane appears. The same files are edited in a text editor, and a
        // list left on screen since yesterday is how a stale copy gets saved over a hand-edited
        // prompt (plan §6, the risk table). The date check in `ModeStore.save(_ draft:)` is the
        // other half; this one is what keeps the list itself honest.
        .onAppear { Task { await model.reload() } }
        .alert(
            model.pendingRemoval?.removalConfirmation.title ?? "",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval?.removalConfirmation
        ) { prompt in
            // `.destructive` and not a plain button: it is what makes the confirming action red,
            // and red is the only thing in this dialog the eye reads before the sentence.
            Button(prompt.confirmTitle, role: .destructive) { model.confirmRemoval() }
            Button(prompt.cancelTitle, role: .cancel) { model.pendingRemoval = nil }
        } message: { prompt in
            Text(prompt.message)
        }
        // The other loss: the one the app causes rather than the disk. Raised only when opening
        // another row or pressing `+` would throw away something typed -- Cancel goes straight
        // through, because pressing Cancel is already the answer.
        .alert(
            model.discardPrompt?.title ?? "",
            isPresented: Binding(
                get: { model.discardPrompt != nil },
                set: { if !$0 { model.cancelDiscard() } }),
            presenting: model.discardPrompt
        ) { prompt in
            Button(prompt.confirmTitle, role: .destructive) { model.confirmDiscard() }
            Button(prompt.cancelTitle, role: .cancel) { model.cancelDiscard() }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 0) {
            if let problem = model.writeProblem {
                problemRow(problem, dismiss: model.dismissWriteProblem)
            }
            // One line per file that could not be read. D15's payoff: the menu can only say
            // something is wrong, and this is beside the list the broken file is missing from.
            // T9 owns the full treatment of every empty and broken state.
            ForEach(model.problems, id: \.self) { problem in
                problemRow(problem, dismiss: nil)
            }
            cards
            footer
        }
        .background(Color(role: .paneBackground))
    }

    private var cards: some View {
        ScrollView {
            LazyVStack(spacing: ModesLayout.rowSpacing) {
                ForEach(model.modes, id: \.key) { mode in
                    card(for: mode)
                }
                // A mode being created has no row to expand, so it is its own card at the end of
                // the list. It reaches the disk on Save and not before -- a file written by the
                // act of picking a preset would leave `new-mode.json` behind on every misclick.
                if model.isCreating {
                    newCard
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .overlay { if model.modes.isEmpty { emptyList } }
    }

    private func card(for mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(mode)
            if model.isEditing(mode) {
                editor
            }
        }
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.surfaceCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
        )
    }

    private var newCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: ModesLayout.chevronWidth)
                Text("New mode")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Color(role: .secondaryText))
            .padding(.horizontal, ModesLayout.rowPadding.horizontal)
            .padding(.vertical, ModesLayout.rowPadding.vertical)
            editor
        }
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.surfaceCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
        )
    }

    /// The row itself: chevron, glyph, name, the active dot, and the stage readout at the trailing
    /// edge. The whole row is the disclosure control — a chevron that is the only hit target makes
    /// a 51 pt card behave like a 12 pt one.
    private func row(_ mode: Mode) -> some View {
        Button {
            model.toggleEditor(for: mode)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
                    .rotationEffect(.degrees(model.isEditing(mode) ? 90 : 0))
                    .frame(width: ModesLayout.chevronWidth)
                // `symbol` when the mode picked one from the Icon grid (task 4), otherwise
                // derived (D14): a microphone for a mode that only transcribes, sparkles for one
                // that sends what is said to a language model.
                Image(systemName: mode.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(role: .primaryText))
                Text(mode.name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                if mode.key == appState.activeMode.key {
                    activeDot
                }
                Spacer(minLength: 8)
                badges(mode)
            }
            .padding(.horizontal, ModesLayout.rowPadding.horizontal)
            .padding(.vertical, ModesLayout.rowPadding.vertical)
            .frame(maxWidth: .infinity, minHeight: ModesLayout.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: model.isEditing(mode))
    }

    /// **The entire active-mode indicator** — no highlight, no checkmark, no border (design notes
    /// §5). Their dot is green; this one is the accent, because Murmure's window has exactly one
    /// colour in it (D4) and a green here would be a second one, introduced for a 7 pt circle.
    private var activeDot: some View {
        Circle()
            .fill(Color(role: .selection))
            .frame(width: ModesLayout.activeDotSize, height: ModesLayout.activeDotSize)
            .help("The mode the next dictation will run")
    }

    /// One badge per model stage: one for a transcribe-only mode, two for a refining one. The
    /// availability half of Superwhisper's readout collapses here — everything is local, so there
    /// is no padlock — and the stage count is the half worth keeping.
    ///
    /// **Recessed** rather than the lighter tray the notes measured. The palette has one lift
    /// (`cardBackground`) and this tray sits *on* it, so going lighter would need a role that does
    /// not exist; recessed is the same design language's other direction, and it is the one it
    /// reserves for a readout that is not interactive (§2, the Home stats strip).
    private func badges(_ mode: Mode) -> some View {
        HStack(spacing: ModesLayout.badgeSpacing) {
            ForEach(mode.stages, id: \.self) { stage in
                Image(systemName: stage.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
                    .frame(width: ModesLayout.badgeSize, height: ModesLayout.badgeSize)
                    .background(
                        RoundedRectangle(
                            cornerRadius: WindowLayout.chipCornerRadius, style: .continuous
                        )
                        .fill(Color(role: .paneBackground))
                    )
                    // The badge names the model it stands for, so the readout is provenance and
                    // not decoration.
                    .help(mode.model(for: stage))
            }
        }
        .padding(ModesLayout.badgeTrayPadding)
    }

    // MARK: - The editor, inline in the row

    /// Every field visible, none hidden (task 3): name, icon, language, speech model, the refiner
    /// as one block (enabled, API, model), instructions, what it actually sends, then context --
    /// in that order, because that is the order a reader needs them to understand a mode: what it
    /// is called, what it looks like, what it hears, what cleans it up, and only then the two
    /// things that decide what the cleanup step is actually told (the words and the background).
    @ViewBuilder
    private var editor: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
                hairline
                field("Name", text: text(\.name), placeholder: "Voice")
                iconPicker(draft)
                languagePicker(draft)
                speechModelPicker(draft)

                // The one switch that changes what the mode *is*, which is why it is here and not
                // on the advanced screen: it decides whether what Louis says reaches a language
                // model at all, and it is what the row's second badge is drawn from.
                toggle("Refine the transcript", isOn: flag(\.llm.enabled))

                if draft.mode.llm.enabled {
                    // Moved here from the advanced screen (task 3): "for each mode I want to see
                    // ... its refiner model" was read as the whole refiner block, api included --
                    // a mode's dialect is not machinery the way its endpoint is, it is half of
                    // what "Instructions" even means (``Mode/LLM/API/s1``).
                    apiPicker(draft)
                    refinerModelPicker(draft)
                    // The note is the fix for Louis opening `Prompt`, reading
                    // `"[Context: general]"` and concluding there was no prompt at all: under
                    // `api: .s1` this field is a control line the model copies rather than reads,
                    // and that has to be readable right here, not only in `apiPicker`'s own note.
                    field("Instructions", text: text(\.instructions),
                          placeholder: draft.mode.llm.api == .s1
                              ? "[Context: general]" : "Clean up the transcript.",
                          note: draft.mode.llm.api == .s1
                              ? "A control line for the s1 model (bracketed fields only, e.g. "
                                  + "\u{201C}[Context: general]\u{201D}) -- the model copies this "
                                  + "into its answer instead of following it."
                              : "The written prompt sent to the refiner model as its system turn.",
                          lines: 2...6)
                }
                // Outside the `if`, deliberately: `RefinementPreview.render` has its own branch
                // for `llm.enabled == false` (`RefinementPreview.noRefinerText`), and a preview
                // nested inside this guard would never draw it -- Voice, the daily mode, would
                // show no preview at all rather than the one sentence that answers the question
                // "what does this mode send" (review, lot 3a, item 1). Between Instructions and
                // Context, matching the brief's own field order -- what the preview shows is the
                // Instructions field's own content plus whichever Context toggles are on, so it
                // reads as the answer to "what does Instructions actually produce", sitting
                // between the field that feeds it and the toggles that also feed it.
                previewBlock(draft)

                if draft.mode.llm.enabled {
                    contextGroup(draft)
                }

                advancedButton(draft)
                actions(draft)
            }
            .padding(.horizontal, ModesLayout.rowPadding.horizontal)
            .padding(.bottom, ModesLayout.rowPadding.vertical + 4)
        }
    }

    /// "What the refiner receives" (task 1): a read-only, monospaced, scrollable rendering of the
    /// exact request `RefinementRequest` would send for this draft, built from
    /// `RefinementPreview.render(mode:)` -- the same assembler `RefinementRequest.systemTurn`
    /// itself calls, so this can never show a system turn a real dictation would not actually
    /// send. Rebuilt on every edit: `RefinementPreview` is a pure function of `draft.mode`, so
    /// there is nothing to cache and nothing that can go stale while the field is being typed in.
    private func previewBlock(_ draft: ModeDraft) -> some View {
        let preview = RefinementPreview.render(mode: draft.mode)
        return VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
            Text("What the refiner receives")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            ScrollView {
                VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
                    ForEach(Array(preview.turns.enumerated()), id: \.offset) { _, turn in
                        previewTurn(turn)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: ModesLayout.previewHeight.minimum,
                maxHeight: ModesLayout.previewHeight.maximum)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .paneBackground)))
        }
    }

    /// One block of the preview: its heading, the fixed-wording note when there is one (only the
    /// s1-mini system prompt carries one -- Murmure did not write it and cannot change it), and
    /// the body, monospaced and selectable so it reads like the request it stands in for.
    private func previewTurn(_ turn: RefinementPreview.Turn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.heading)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            if let note = turn.note {
                Text(note)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(turn.body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(role: .primaryText))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Icon field (task 4): a grid of `ModeSymbol.library`'s twelve tiles, the same tile the
    /// sidebar draws for a section (`MainWindowView.row(_:)`) -- one rounded square, one glyph,
    /// coloured by whether it is the one in use. The tile matching `Mode.symbolName` -- the glyph
    /// this mode actually draws everywhere, `symbol` when set and the stage default otherwise -- is
    /// always the one shown selected, so the grid never reads as "nothing chosen" for a mode that
    /// has never had its icon touched.
    ///
    /// **A first "Default" tile, ahead of the twelve.** Without it, picking any tile here was a
    /// one-way door -- nothing in the grid could ever set `symbol` back to nil, so a mode explored
    /// out of curiosity would keep an explicit icon it never meant to keep (review, lot 3a, item
    /// 10). Its own glyph is the stage-derived default computed the same way ``ModeStage`` computes
    /// it for a nil `symbol` -- not `draft.mode.symbolName`, which would just echo back whatever is
    /// currently picked -- so the tile keeps showing what tapping it will produce, not what is
    /// already selected. It reads selected exactly when `symbol` is nil.
    private func iconPicker(_ draft: ModeDraft) -> some View {
        let columns = Array(
            repeating: GridItem(.fixed(WindowLayout.sidebarTileSize), spacing: ModesLayout.iconGridSpacing),
            count: ModesLayout.iconGridColumns)
        let stageDefault = draft.mode.llm.enabled
            ? ModeStage.refinement.symbolName : ModeStage.transcription.symbolName
        return labelled("Icon", note: nil) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: ModesLayout.iconGridSpacing) {
                defaultIconTile(stageDefault, isSelected: draft.mode.symbol == nil)
                ForEach(ModeSymbol.library, id: \.self) { symbol in
                    iconTile(symbol, isSelected: symbol == draft.mode.symbolName)
                }
            }
        }
    }

    /// The one tile that does not pick an entry from `ModeSymbol.library` -- it clears `symbol`
    /// back to nil, handing the glyph back to whatever `ModeStage` derives. `stageGlyph` is drawn
    /// on it regardless of the mode's current `symbol`, so the tile always previews what tapping it
    /// will produce, and `.help` says "Default" rather than the glyph's own SF Symbol name, since
    /// unlike every other tile this one is not that glyph so much as a rule that computes one.
    private func defaultIconTile(_ stageGlyph: String, isSelected: Bool) -> some View {
        let palette: (tile: WindowRole, glyph: WindowRole) = isSelected
            ? (.materialTile, .materialGlyph)
            : (.machineryTile, .machineryGlyph)
        return Button {
            model.draft?.mode.symbol = nil
        } label: {
            RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                .fill(Color(role: palette.tile))
                .frame(width: WindowLayout.sidebarTileSize, height: WindowLayout.sidebarTileSize)
                .overlay {
                    Image(systemName: stageGlyph)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(role: palette.glyph))
                }
        }
        .buttonStyle(.plain)
        .help("Default")
    }

    /// One tile of the grid. Selected uses the accent (`WindowRole.materialTile`), the same role
    /// `MainWindowView` gives a *material* sidebar section -- unselected is the neutral machinery
    /// tile: not a dimmer accent, because the split has to read as a kind (chosen vs not), not as
    /// an emphasis (`WindowPalette.token(for:)`'s own reasoning for the same two roles).
    private func iconTile(_ symbol: String, isSelected: Bool) -> some View {
        let palette: (tile: WindowRole, glyph: WindowRole) = isSelected
            ? (.materialTile, .materialGlyph)
            : (.machineryTile, .machineryGlyph)
        return Button {
            model.draft?.mode.symbol = symbol
        } label: {
            RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                .fill(Color(role: palette.tile))
                .frame(width: WindowLayout.sidebarTileSize, height: WindowLayout.sidebarTileSize)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(role: palette.glyph))
                }
        }
        .buttonStyle(.plain)
        .help(symbol)
    }

    /// The Language field, as a picker over what WhisperKit's decoder actually accepts
    /// (`ModesPaneModel.languageOptions`) rather than a free-text field a code could be mistyped
    /// into. Same fallback shape as `speechModelPicker`: a stored value absent from the table is
    /// still shown, tagged as what it is, rather than dropped the moment the editor opens.
    private func languagePicker(_ draft: ModeDraft) -> some View {
        let options = languageOptions(currentValue: draft.mode.stt.language)
        return labelled("Language", note: nil) {
            Picker("", selection: text(\.stt.language)) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func languageOptions(currentValue: String) -> [PickerOption] {
        var options = ModesPaneModel.languageOptions.map {
            PickerOption(value: $0.code, label: "\($0.name.capitalized) (\($0.code))")
        }
        if !options.contains(where: { $0.value == currentValue }) {
            options.append(PickerOption(
                value: currentValue,
                label: currentValue.isEmpty ? "(none)" : "\(currentValue) (not in WhisperKit's table)"))
        }
        return options
    }

    /// The way to the advanced screen, and — when what is wrong is over there — the reason to go.
    /// An error belongs under its own input; when that input is on the other screen, the only
    /// honest thing the basic editor can do is point at the door (`ModeDraft.messageElsewhere`).
    private func advancedButton(_ draft: ModeDraft) -> some View {
        VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
            Button {
                model.showAdvanced()
            } label: {
                HStack(spacing: 6) {
                    Text("Advanced")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color(role: .secondaryText))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let message = draft.messageElsewhere(from: .basic) {
                messageText(message)
            }
        }
    }

    /// Removal on the left, away from Save: the two are not a pair, and a destructive action
    /// beside the confirming one is a mis-click that costs a file. Absent while creating — there
    /// is nothing on disk to remove.
    ///
    /// The word is the mode's, not this file's: a built-in cannot be deleted, because Murmure
    /// writes it again at every launch, so its button says `Reset…` and its dialog says what
    /// actually goes (`ModeRemoval`). Both carry the ellipsis because both stop to ask.
    private func actions(_ draft: ModeDraft) -> some View {
        HStack(spacing: 8) {
            if let key = draft.previousKey, let mode = model.modes.first(where: { $0.key == key }) {
                Button(mode.removal.buttonTitle) { model.askToRemove(mode) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
            }
            Spacer(minLength: 8)
            Button("Cancel") { model.closeEditor() }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            // Disabled by `canSave`, which is `Mode.validate()` — so an `api: .s1` mode holding
            // prose cannot be written at all. That refusal exists here rather than at dictation
            // time because the measured consequence of letting it through is the model copying
            // the instruction back into Louis's own text.
            Button("Save") { model.save() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: draft.canSave ? .primaryText : .secondaryText))
                .disabled(!draft.canSave)
        }
        .padding(.top, 2)
    }

    // MARK: - The advanced screen

    @ViewBuilder
    private var advanced: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 0) {
                advancedHeader(draft)
                ScrollView {
                    VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
                        // The key is the file name, so it is the one field that moves something
                        // on disk. Here rather than in the basic editor for that reason: renaming
                        // what a mode is called is an everyday edit, renaming the file it lives in
                        // is not.
                        field("Key", text: text(\.key), placeholder: "voice",
                              note: "The file is modes/\(draft.mode.key).json.")
                        field("Endpoint", text: text(\.llm.endpoint),
                              placeholder: "http://localhost:11434",
                              note: "The server root. Murmure appends the API path itself.")
                        // `apiPicker` itself moved to the basic editor (task 3): a mode's dialect
                        // is read alongside Instructions now, not beside the endpoint here.
                        field("Auto-activate", text: autoActivateText,
                              placeholder: "com.googlecode.iterm2, com.apple.Terminal",
                              note: "Bundle ids, comma-separated. This mode is picked when one of "
                                  + "them is frontmost.")
                        // The three context toggles moved to the basic editor, next to
                        // `Instructions` -- they are what feeds that field's system turn, and
                        // that is where their consequence (or, under `api: .s1`, their absence
                        // of one) is visible. See `contextGroup(_:)`.
                        // **No `simulateKeypresses` row, and it is not an omission.** Nothing
                        // reads the field: `PasteInserter.insert()` always builds ⌘V events,
                        // whatever the mode says. A switch for a behaviour that does not exist
                        // does not lie about its word the way a Delete on a built-in did — it
                        // lies about there being anything behind it, which is worse, because
                        // there is no wrong outcome to notice afterwards. The field stays in
                        // `Mode` and in the JSON so no mode file becomes invalid and nothing has
                        // to be rewritten on disk; the row comes back when key-by-key typing is
                        // actually written. (Decided by Louis, 2026-09-03; `AppSettings` records
                        // the same absence for its own half.)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Opaque: this is a push over the pane, so what is underneath must not show through.
            .background(Color(role: .paneBackground))
        }
    }

    private func advancedHeader(_ draft: ModeDraft) -> some View {
        VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
            Button {
                model.showBasic()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(draft.mode.name.isEmpty ? "Advanced" : draft.mode.name)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color(role: .primaryText))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Same rule as the basic screen's Advanced button, mirrored: what is wrong back there
            // is said beside the way back there.
            if let message = draft.messageElsewhere(from: .advanced) {
                messageText(message)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: ModesLayout.backBarHeight, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(role: .hairline))
                .frame(height: WindowLayout.hairlineWidth)
        }
    }

    /// The `api` discriminator, as the two wire protocols it names — never as a model.
    ///
    /// Only meaningful when the refiner is on, because with it off the field decides nothing --
    /// which is why the call site (`editor`'s own `if draft.mode.llm.enabled`) is what decides
    /// whether this is drawn at all. No second guard here: a duplicate `if` around the whole body
    /// only ever agrees with the one the caller already checked (review, lot 3a, item 9).
    ///
    /// A segmented picker rather than a toggle: these are two dialects, not on and off, and a
    /// third one is a case in `Mode.LLM.API` rather than a redesign here.
    private func apiPicker(_ draft: ModeDraft) -> some View {
        labelled("Refiner API", note: draft.mode.llm.api == .s1
            ? "s1 takes a control line such as [Context: general], never written instructions."
            : "chat takes written instructions as the system turn.") {
            Picker("", selection: api) {
                Text("chat").tag(Mode.LLM.API.chat)
                Text("s1").tag(Mode.LLM.API.s1)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }

    /// One entry a `Picker` below can show: the value written into the mode, and the label drawn
    /// for it. Distinct so a stored value absent from the live list can still be shown, tagged as
    /// what it is, instead of leaving the control on a blank selection.
    private struct PickerOption: Identifiable, Hashable {
        let value: String
        let label: String
        var id: String { value }
    }

    /// The Speech model picker's own options, plus one more when `currentValue` names a reference
    /// this machine has not installed. Dropping the stored value in that case (rather than only
    /// ever offering what is installed) would rewrite a mode's `stt.model` the moment its editor
    /// opened, before Louis touched anything -- picking *a* model when none of these is what the
    /// file actually says would be its own silent rewrite.
    private func speechModelOptions(currentValue: String) -> [PickerOption] {
        var options = model.installedSpeechModels.map { PickerOption(value: $0.string, label: $0.string) }
        if !options.contains(where: { $0.value == currentValue }) {
            options.append(PickerOption(
                value: currentValue,
                label: currentValue.isEmpty ? "(none)" : "\(currentValue) (not installed)"))
        }
        return options
    }

    /// Same reasoning as ``speechModelOptions(currentValue:)``, over Ollama's own listing instead
    /// of the speech-model store -- with one more distinction that store never needs: **unreachable
    /// is not the same fact as "not installed".** When `model.ollamaUnreachableNote` is set, Ollama
    /// was never actually asked, so the fallback item names the stored value plain, with no
    /// "(not installed)" suffix -- the same line `ModelInventory`'s own `.undetermined` (a probe
    /// that could not be run) draws against `.absent` (a probe that ran and said no).
    private func refinerModelOptions(currentValue: String) -> [PickerOption] {
        var options = model.ollamaModels.map { PickerOption(value: $0.name, label: $0.name) }
        if !options.contains(where: { $0.value == currentValue }) {
            let label: String
            if currentValue.isEmpty {
                label = "(none)"
            } else if model.ollamaUnreachableNote != nil {
                label = currentValue
            } else {
                label = "\(currentValue) (not installed)"
            }
            options.append(PickerOption(value: currentValue, label: label))
        }
        return options
    }

    /// The Speech model field, as a picker over what `ModelInventory.installedSpeechModels` finds
    /// on disk rather than a text field a reference could be mistyped into. `ModeField.sttModel`'s
    /// validation message still surfaces underneath (`labelled`'s own lookup), unchanged by this
    /// being a picker rather than free text.
    private func speechModelPicker(_ draft: ModeDraft) -> some View {
        let options = speechModelOptions(currentValue: draft.mode.stt.model)
        return labelled("Speech model", note: nil) {
            Picker("", selection: text(\.stt.model)) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// The Refiner model field, as a picker over Ollama's own `/api/tags` listing
    /// (`ModesPaneModel.ollamaModels`). When Ollama could not be reached at all, the picker still
    /// holds the mode's stored value (`refinerModelOptions`'s fallback) and the note below names
    /// why, in `OllamaFailure`'s own wording -- the same sentence a dictation failure would show,
    /// so there are not two vocabularies for one server being unreachable.
    private func refinerModelPicker(_ draft: ModeDraft) -> some View {
        let options = refinerModelOptions(currentValue: draft.mode.llm.model)
        return labelled("Refiner model", note: model.ollamaUnreachableNote) {
            Picker("", selection: text(\.llm.model)) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// The three context sources, as three toggles and not one control: they are independent, and
    /// spec §5 stores them that way. What they feed is `RefinementRequest.systemTurn`, assembled
    /// from whatever `Instructions` holds plus whichever of these is on -- which is why this sits
    /// right under that field rather than on the advanced screen where it used to live.
    ///
    /// **Shown and DISABLED under `api: .s1`, never hidden.** An `s1` mode's instructions are a
    /// control line the model copies into its answer rather than reads (`Mode/LLM/API/s1`), so
    /// there is nowhere for a selection, a clipboard or an app name to go -- `RefinementRequest`
    /// already refuses to fold them in for that api. Hiding the row would read as a missing
    /// feature; disabling it with a reason says what it is instead: a control that does nothing
    /// here, not a control that was never built.
    ///
    /// Each toggle carries its own one-line description (task 2, `ContextSource.description`):
    /// what is captured, when, and how the refiner sees it -- the answer to "does this actually do
    /// anything", read right where the toggle is rather than worked out by trial and error. The
    /// reason all three are disabled under s1 is shared too (`ContextSource.s1DisabledReason`), so
    /// the sentence in the view and the one a test in `MurmureCore` pins can never say two
    /// different things about the same api.
    private func contextGroup(_ draft: ModeDraft) -> some View {
        let disabledForS1 = draft.mode.llm.api == .s1
        return VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
            // The three labels come from `ContextSource.label` rather than being typed again here
            // -- this file used to spell the third one "Frontmost app", one word short of
            // `ContextSource.frontmostApp.label`'s "Frontmost application", which is also what the
            // system turn itself is headed with (review, lot 3a, item 7).
            toggle(ContextSource.selectedText.label, isOn: flag(\.context.selectedText),
                   disabled: disabledForS1, note: ContextSource.selectedText.description)
            toggle(ContextSource.clipboard.label, isOn: flag(\.context.clipboard),
                   disabled: disabledForS1, note: ContextSource.clipboard.description)
            toggle(ContextSource.frontmostApp.label, isOn: flag(\.context.appContext),
                   disabled: disabledForS1, note: ContextSource.frontmostApp.description)
            if disabledForS1 {
                Text(ContextSource.s1DisabledReason)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The footer

    /// `+ New mode` and the folder button.
    ///
    /// The doc corpus puts `+ Create mode` in the **page header**, on the right, and grey rather
    /// than blue — the accent is reserved for state, never for buttons. It is here instead because
    /// the header is one row shared by all six sections and `MainWindowView` owns it; moving this
    /// button up there is one line in that file whenever it is wanted.
    ///
    /// "Reveal modes folder" is design notes §6's closing sentence: Application Support is more
    /// correct than their `~/Documents` "but it does hide them", and these files are meant to be
    /// opened in a text editor.
    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.isPickingPreset = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New mode")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color(role: .primaryText))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(
                        cornerRadius: WindowLayout.chipCornerRadius, style: .continuous
                    )
                    .fill(Color(role: .cardBackground))
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $model.isPickingPreset) { presetPicker }

            Spacer(minLength: 8)

            // The words come off `RevealTarget` rather than being written again here: the Advanced
            // pane offers the same button, and two labels for one action are how the two
            // implementations that used to be behind it went unnoticed. Title case is that type's
            // own argument -- one casing rule per surface, as `HistoryClearing` already set.
            Button(RevealTarget.modes.buttonTitle) { model.revealModesFolder() }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(role: .hairline))
                .frame(height: WindowLayout.hairlineWidth)
        }
    }

    /// What ships, plus Custom. Derived from `ModePreset.all`, which is itself derived from
    /// `Mode.builtIns` — so the picker cannot offer a mode the app does not have.
    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ModePreset.all) { preset in
                Button {
                    model.create(from: preset)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(role: .primaryText))
                        // The summary is the point of the picker: the names alone say nothing
                        // about which of them sends what is said to a language model.
                        Text(preset.summary)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color(role: .secondaryText))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    // MARK: - Field building blocks

    private func field(
        _ label: String, text binding: Binding<String>, placeholder: String,
        note: String? = nil, lines: ClosedRange<Int>? = nil
    ) -> some View {
        labelled(label, note: note) {
            Group {
                if let lines {
                    TextField(placeholder, text: binding, axis: .vertical)
                        .lineLimit(lines)
                } else {
                    TextField(placeholder, text: binding)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(Color(role: .primaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .paneBackground))
            )
        }
    }

    private func toggle(
        _ label: String, isOn: Binding<Bool>, disabled: Bool = false, note: String? = nil
    ) -> some View {
        labelled(label, note: note) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(disabled)
        }
    }

    /// A label column, the control, and — under the control — the message for whichever field this
    /// is, when there is one. **Under the input that caused it**, which is the whole reason
    /// `ModeField` exists: a banner at the top of the editor would name a JSON path and leave the
    /// reader mapping it back to a box on screen.
    private func labelled(
        _ label: String, note: String?, @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
                .frame(width: ModesLayout.fieldLabelWidth, alignment: .leading)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
                control()
                if let message = message(for: label) {
                    messageText(message)
                } else if let note {
                    Text(note)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func messageText(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(Color(role: .primaryText))
    }

    private func problemRow(_ problem: String, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(problem).lineLimit(3)
            Spacer(minLength: 8)
            if let dismiss {
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(Color(role: .secondaryText))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// `ModeStore.loadAll()` guarantees a `Voice` entry, so this is very nearly unreachable — it
    /// takes a modes folder that cannot be listed at all. The line above the list says which.
    private var emptyList: some View {
        Text("No modes could be read.")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .padding(24)
    }

    // MARK: - Bindings into the draft

    /// The label is what ties a control to its field, so the mapping lives in one place rather
    /// than being passed alongside every call.
    private func message(for label: String) -> String? {
        guard let field = Self.fields[label] else { return nil }
        return model.draft?.message(for: field)
    }

    private static let fields: [String: ModeField] = [
        "Key": .key,
        "Name": .name,
        "Speech model": .sttModel,
        "Language": .sttLanguage,
        "Endpoint": .llmEndpoint,
        "Refiner model": .llmModel,
        "Instructions": .instructions,
    ]

    private func text(_ keyPath: WritableKeyPath<Mode, String>) -> Binding<String> {
        Binding(
            get: { model.draft?.mode[keyPath: keyPath] ?? "" },
            set: { model.draft?.mode[keyPath: keyPath] = $0 })
    }

    private func flag(_ keyPath: WritableKeyPath<Mode, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.draft?.mode[keyPath: keyPath] ?? false },
            set: { model.draft?.mode[keyPath: keyPath] = $0 })
    }

    private var api: Binding<Mode.LLM.API> {
        Binding(
            get: { model.draft?.mode.llm.api ?? .chat },
            set: { model.draft?.mode.llm.api = $0 })
    }

    /// `autoActivate` is a list in the file and one line in the editor. The two conversions are in
    /// `MurmureCore` and tested there — an empty entry written into the file is a claim on no
    /// application that whoever opens the JSON has to work out is inert.
    private var autoActivateText: Binding<String> {
        Binding(
            get: { Mode.autoActivateText(model.draft?.mode.autoActivate ?? []) },
            set: { model.draft?.mode.autoActivate = Mode.autoActivateList(from: $0) })
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(role: .hairline))
            .frame(height: WindowLayout.hairlineWidth)
    }
}
