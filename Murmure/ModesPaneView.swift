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
        // The monitor `startRecordingModeHotkey()` installs is local to this window; the pane
        // leaving the screen -- another section picked, the window closed -- must stop it, the
        // same rule `GeneralPaneView`'s own `.onDisappear` follows for the toggle's recorder.
        // `ModesPaneModel.deinit` is the same removal for the case this never fires.
        .onDisappear { model.stopRecordingModeHotkey() }
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
        // A third loss, the same shape as the one above: switching a mode's refiner kind resets
        // `instructions` to the new kind's own default, and that is implicit exactly when what is
        // on screen is not what the draft was opened with (`ModesPaneModel.switchKind(_:)`'s own
        // guard). Same alert shape, same confirm/cancel pair.
        .alert(
            model.kindSwitchPrompt?.title ?? "",
            isPresented: Binding(
                get: { model.kindSwitchPrompt != nil },
                set: { if !$0 { model.cancelKindSwitch() } }),
            presenting: model.kindSwitchPrompt
        ) { prompt in
            Button(prompt.confirmTitle, role: .destructive) { model.confirmKindSwitch() }
            Button(prompt.cancelTitle, role: .cancel) { model.cancelKindSwitch() }
        } message: { prompt in
            Text(prompt.message)
        }
        // The drafting sheet's own model is held on `ModesPaneModel` (`draftingModel`) rather than
        // built inside this closure -- a closure rebuilding it on every state change would throw
        // away the conversation as it was typed. `isPresented` only mirrors whether that model
        // currently exists.
        .sheet(isPresented: Binding(
            get: { model.draftingModel != nil },
            set: { if !$0 { model.closeDraftingModeWithHelp() } }
        )) {
            if let draftingModel = model.draftingModel {
                ModeDraftSheetView(
                    paneModel: draftingModel,
                    onCancel: { model.closeDraftingModeWithHelp() },
                    onUseDraft: { model.useDraftedMode($0) })
            }
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

    /// Two cards (task 6), beginner-facing first: **Identity** — what a mode is called and what
    /// it hears — then **Refiner** — the technical half, hidden entirely for `Voice`, which has
    /// none. Splitting the one long field list this way is what makes the editor legible to
    /// someone who has never opened it: the first card alone is a complete, usable mode.
    ///
    /// **`advancedButton` is drawn here, for every mode, not inside `refinerCard` (fix round 1,
    /// MAJOR-1).** The advanced screen is not refiner-only -- it also holds Key, Endpoint and
    /// Auto-activate (`advanced`) -- so a mode with no Refiner card, `Voice`, still needs its own
    /// door to it, and `draft.messageElsewhere(from: .basic)` still needs somewhere on the basic
    /// screen to say a Key or Endpoint problem is over there.
    @ViewBuilder
    private var editor: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: ModesLayout.cardSpacing) {
                hairline
                identityCard(draft)
                if !draft.mode.isProtected {
                    refinerCard(draft)
                }
                advancedButton(draft)
                actions(draft)
            }
            .padding(.horizontal, ModesLayout.rowPadding.horizontal)
            .padding(.bottom, ModesLayout.rowPadding.vertical + 4)
        }
    }

    /// What a beginner needs and nothing else: name, icon, language, shortcut, speech model.
    ///
    /// **`Voice` is read-only here.** Its name and icon are fixed (``Mode/isProtected``), so the
    /// row shows the name as plain text beside a lock rather than an editable field that would
    /// refuse every keystroke; the caption says why rather than leaving the reader to discover it
    /// by trying. Everything below that row -- language, shortcut, speech model -- stays editable:
    /// `isProtected` only guards `name` and `symbol` (`Mode.editorValidationError`).
    private func identityCard(_ draft: ModeDraft) -> some View {
        HomeCard(title: "Identity") {
            VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
                if draft.mode.isProtected {
                    protectedNameRow(draft)
                } else {
                    field("Name", text: text(\.name), placeholder: "Voice")
                    iconPicker(draft)
                }
                languagePicker(draft)
                shortcutRow(draft)
                speechModelPicker(draft)
            }
        }
    }

    /// `Voice`'s own Name row: its glyph and name as static text, a lock, and the caption that
    /// says why nothing here can be typed into. Stands in for both the Name field and the icon
    /// grid at once -- there is nothing to pick when there is nothing to change.
    private func protectedNameRow(_ draft: ModeDraft) -> some View {
        labelled("Name", note: "Voice is the built-in dictation mode") {
            HStack(spacing: 8) {
                Image(systemName: draft.mode.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
                Text(draft.mode.name)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
            }
        }
    }

    /// The technical half: the refiner's own kind and model, its instructions, and what those two
    /// plus Context actually send. Hidden entirely for `Voice` (there is no refiner to configure)
    /// -- the call site (`editor`) is what decides that, so this function can assume
    /// `draft.mode.isProtected == false` throughout.
    ///
    /// **Does not draw `advancedButton` any more (fix round 1, MAJOR-1).** That button is not
    /// refiner-only -- see `editor`'s own note -- so it moved back up to be drawn for every mode,
    /// `Voice` included, rather than only for the modes that have a Refiner card at all.
    private func refinerCard(_ draft: ModeDraft) -> some View {
        HomeCard(title: "Refiner") {
            VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
                if draft.mode.llm.enabled {
                    kindPicker(draft)
                    refinerModelPicker(draft)
                    // The note is the fix for Louis opening `Prompt`, reading
                    // `"[Context: general]"` and concluding there was no prompt at all: under
                    // `api: .s1` this field is a control line the model copies rather than
                    // reads, and that has to be readable right here.
                    field("Instructions", text: text(\.instructions),
                          placeholder: draft.mode.llm.api == .s1
                              ? "[Context: general]" : "Clean up the transcript.",
                          note: draft.mode.llm.api == .s1
                              ? "A control line for the s1 model (bracketed fields only, e.g. "
                                  + "\u{201C}[Context: general]\u{201D}) -- the model copies "
                                  + "this into its answer instead of following it."
                              : "The written prompt sent to the refiner model as its system "
                                  + "turn.",
                          lines: 2...6)
                    contextGroup(draft)
                    DisclosureGroup("What the refiner receives") {
                        previewBlock(draft)
                    }
                } else {
                    refinerOffNotice()
                }
            }
        }
    }

    /// A loaded mode other than `Voice` can still have `llm.enabled == false` -- files predating
    /// spec §3's "a mode without a refiner IS Voice" rule, or one somebody switched off by hand --
    /// and removing the old toggle (task 6) took away the one control that turned it back on.
    /// This notice is that control's replacement: it says what the mode does today and offers the
    /// one press that fixes it, rather than leaving Louis to find `llm.enabled` in the JSON.
    ///
    /// `switchKind(draft.mode.llm.api)` after setting the flag: turning the refiner on with no
    /// installed model and no instructions would save a mode `Mode.validationError` refuses the
    /// moment Save is pressed, so the button lands the draft on that api's own recommended model
    /// and default instructions in the same motion -- the identical reset a kind switch already
    /// gives when nothing was typed yet (``ModesPaneModel/switchKind(_:)``).
    private func refinerOffNotice() -> some View {
        VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
            messageText("This mode has no refiner, so it behaves exactly like Voice.")
            Button("Turn the refiner on") {
                model.draft?.mode.llm.enabled = true
                model.switchKind(model.draft?.mode.llm.api ?? .chat)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// "What the refiner receives" (task 1): a read-only, monospaced, scrollable rendering of the
    /// exact request `RefinementRequest` would send for this draft, built from
    /// `RefinementPreview.render(mode:)` -- the same assembler `RefinementRequest.systemTurn`
    /// itself calls, so this can never show a system turn a real dictation would not actually
    /// send. Rebuilt on every edit: `RefinementPreview` is a pure function of `draft.mode`, so
    /// there is nothing to cache and nothing that can go stale while the field is being typed in.
    ///
    /// **No heading of its own (task 6).** It used to draw "What the refiner receives" itself;
    /// now it is always shown wrapped in a `DisclosureGroup` carrying that exact title
    /// (`refinerCard`), and a second copy here would repeat the label the disclosure's own
    /// chevron already names.
    private func previewBlock(_ draft: ModeDraft) -> some View {
        let preview = RefinementPreview.render(mode: draft.mode)
        return VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
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

    /// The Icon field (task 4, single-list task 6): a grid of `ModeSymbol.library`'s eleven
    /// tiles, the same tile the sidebar draws for a section (`MainWindowView.row(_:)`) -- one
    /// rounded square, one glyph, coloured by whether it is the one in use.
    ///
    /// **One list, not the library plus a separate "Default" tile (task 6, spec §5).** The tile
    /// equal to this mode's own stage default (``ModeSymbol/isStageDefault(_:for:)``, `mic.fill`
    /// for a transcribe-only mode, `sparkles` for a refining one) carries a small "Default"
    /// caption under it, and tapping IT clears `symbol` back to nil rather than setting it to its
    /// own name -- so the grid still has exactly one way back to "nothing chosen", it is just the
    /// tile that already reads as the default rather than a thirteenth tile ahead of it.
    private func iconPicker(_ draft: ModeDraft) -> some View {
        let columns = Array(
            repeating: GridItem(.fixed(WindowLayout.sidebarTileSize), spacing: ModesLayout.iconGridSpacing),
            count: ModesLayout.iconGridColumns)
        let stage: ModeStage = draft.mode.llm.enabled ? .refinement : .transcription
        return labelled("Icon", note: nil) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: ModesLayout.iconGridSpacing) {
                ForEach(ModeSymbol.library, id: \.self) { symbol in
                    iconTile(symbol, for: stage, draft: draft)
                }
            }
        }
    }

    /// One tile of the grid. Selected uses the accent (`WindowRole.materialTile`), the same role
    /// `MainWindowView` gives a *material* sidebar section -- unselected is the neutral machinery
    /// tile: not a dimmer accent, because the split has to read as a kind (chosen vs not), not as
    /// an emphasis (`WindowPalette.token(for:)`'s own reasoning for the same two roles).
    ///
    /// **The stage-default tile is selected on two conditions, every other tile on one.** `symbol
    /// == nil` reads as "this mode has never picked one, so its glyph is whatever the stage
    /// derives" -- which is this exact tile -- so it has to show selected then too, not only when
    /// `symbol` happens to equal its own name explicitly. Tapping it stores `nil`, never its own
    /// name, so the grid keeps exactly one way back to "nothing chosen" without a thirteenth tile.
    private func iconTile(_ symbol: String, for stage: ModeStage, draft: ModeDraft) -> some View {
        let isDefault = ModeSymbol.isStageDefault(symbol, for: stage)
        let isSelected = isDefault
            ? (draft.mode.symbol == nil || draft.mode.symbol == symbol)
            : draft.mode.symbol == symbol
        let palette: (tile: WindowRole, glyph: WindowRole) = isSelected
            ? (.materialTile, .materialGlyph)
            : (.machineryTile, .machineryGlyph)
        return VStack(spacing: 2) {
            Button {
                model.draft?.mode.symbol = isDefault ? nil : symbol
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
            .help(isDefault ? "Default" : symbol)
            if isDefault {
                // `.fixedSize()` (fix round 1, MINOR): the grid column is
                // `WindowLayout.sidebarTileSize` (22 pt) wide, narrower than "Default" at
                // `.caption2` -- without it the caption would be proposed that 22 pt width and
                // wrap to two lines, changing the row height of only this one column.
                // `.fixedSize()` measures the text at its own natural width instead, so it stays
                // one line even where that overflows the column.
                Text("Default")
                    .font(.caption2)
                    .foregroundStyle(Color(role: .secondaryText))
                    .fixedSize()
            }
        }
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

    /// The Shortcut field (backlog §7's own last sentence): this mode's own hotkey, recorded
    /// exactly the way General records the toggle -- same `HotkeyRecordingSession`, same
    /// release/restore discipline around every live binding while the local monitor is up
    /// (`ModesPaneModel.startRecordingModeHotkey()`'s own note explains why that discipline has to
    /// be identical, not merely similar). Between Language and Speech model per task 3's field
    /// order.
    ///
    /// A chip row (or "None"), Record/Cancel, and Clear -- absent while there is nothing to clear.
    /// Below that, in order: the live conflict or refusal sentence `HotkeyAssignments.resolve`
    /// would produce for this draft right now (`ModesPaneModel.modeHotkeyProblem`, the existing
    /// warning styling `messageText` already uses elsewhere in this file), then the idle/recording
    /// note (plain secondary text, `labelled`'s own slot) -- the same two-tier split General draws,
    /// just assembled by hand here because "Shortcut" is not a `ModeField` `labelled` already
    /// knows how to look a message up for.
    private func shortcutRow(_ draft: ModeDraft) -> some View {
        labelled("Shortcut", note: model.modeHotkeyNote) {
            VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
                HStack(spacing: 8) {
                    if draft.mode.hotkey == nil {
                        Text("None")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Color(role: .secondaryText))
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(model.modeHotkeyKeycaps.enumerated()), id: \.offset) { _, cap in
                                keycap(cap)
                            }
                        }
                    }
                    Button(model.isRecordingModeHotkey ? "Cancel" : "Record") {
                        if model.isRecordingModeHotkey {
                            model.stopRecordingModeHotkey()
                        } else {
                            model.startRecordingModeHotkey()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if draft.mode.hotkey != nil {
                        Button("Clear") { model.clearModeHotkey() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                if let problem = model.modeHotkeyProblem {
                    messageText(problem)
                }
            }
        }
    }

    /// 18 × 18 pt for a glyph, and as wide as its text plus a little for a word key — the same
    /// measurement `GeneralPaneView.keycap(_:)` draws the toggle's own chips at (design notes §2).
    /// Duplicated rather than shared: that view is owned by another lot currently under review, so
    /// a common helper cannot be introduced there from here.
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
    ///
    /// **Also absent for `Voice` (task 6, `model.canDeleteDraft`).** `Voice` is a built-in too, so
    /// without this guard it would draw the same `Reset…` button every other built-in gets --
    /// which is not what protects it: `Mode.isProtected` is a stronger rule than "this mode ships
    /// with the app", and this row has to draw that stronger rule, not the weaker one `removal`
    /// alone would give it.
    private func actions(_ draft: ModeDraft) -> some View {
        HStack(spacing: 8) {
            if model.canDeleteDraft,
               let key = draft.previousKey, let mode = model.modes.first(where: { $0.key == key }) {
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
    /// which is why the call site (`refinerCard`'s own `if draft.mode.llm.enabled`) is what
    /// decides whether this is drawn at all. No second guard here: a duplicate `if` around the
    /// whole body only ever agrees with the one the caller already checked (review, lot 3a, item
    /// 9).
    ///
    /// A segmented picker rather than a toggle: these are two dialects, not on and off, and a
    /// third one is a case in `Mode.LLM.API` rather than a redesign here.
    ///
    /// **Bound through `model.switchKind(_:)`, not straight into the draft (task 6).** A kind
    /// switch resets `llm.model` and `instructions` to that kind's own defaults
    /// (`Mode.switching(to:)`) -- writing `api` directly here would change the wire protocol and
    /// leave the model and instructions of the OTHER kind sitting under it, which is exactly the
    /// mismatch `Mode.validationError` exists to catch at Save. `switchKind` is also what raises
    /// `model.kindSwitchPrompt` when instructions were actually edited, so going around it here
    /// would silently drop that confirmation.
    ///
    /// **The setter guards against a same-value set; `switchKind` itself does not (fix round 1,
    /// MAJOR-2).** `switching(to:)` overwrites `llm.model` and `instructions` unconditionally, so
    /// a Picker re-sending its already-selected segment -- possible on macOS's
    /// `NSSegmentedControl`-backed control -- would silently replace a hand-written prompt with
    /// nothing having actually changed. The guard belongs here rather than in `switchKind` because
    /// "Turn the refiner on" (`refinerOffNotice`) relies on `switchKind` resetting unconditionally
    /// even when `api` has not changed value.
    ///
    /// **The getter reads `model.draft` live, not the captured `draft` (fix round 1, NIT).** Every
    /// sibling binding in this file (`text(_:)`, `flag(_:)`) reads the model's own published value
    /// rather than the parameter passed in when the enclosing view was built, so this one now
    /// matches them rather than being the one exception that could go stale.
    private func kindPicker(_ draft: ModeDraft) -> some View {
        labelled("Refiner kind", note: nil) {
            Picker("", selection: Binding(
                get: { model.draft?.mode.llm.api ?? draft.mode.llm.api },
                set: { newValue in
                    guard newValue != model.draft?.mode.llm.api else { return }
                    model.switchKind(newValue)
                })
            ) {
                Text(Mode.LLM.API.s1.title).tag(Mode.LLM.API.s1)
                Text(Mode.LLM.API.chat.title).tag(Mode.LLM.API.chat)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
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

    /// Same reasoning as ``speechModelOptions(currentValue:)``, over `model.refinerChoices(for:)`
    /// instead of the speech-model store -- with one more distinction that store never needs:
    /// **unreachable is not the same fact as "not installed".** When `model.ollamaUnreachableNote`
    /// is set, Ollama was never actually asked, so the fallback item names the stored value plain,
    /// with no "(not installed)" suffix -- the same line `ModelInventory`'s own `.undetermined` (a
    /// probe that could not be run) draws against `.absent` (a probe that ran and said no).
    ///
    /// **Limited to the current kind (task 6).** `refinerChoices(for:)` already filters
    /// `ollamaModels` to what `api` can drive (`Mode.LLM.API.accepts(modelName:)`) -- offering
    /// every installed model regardless of kind would let this picker pick a name `Mode
    /// .validationError` never checks against `api` at all, so a mismatched pair would only ever
    /// surface as a bad refinement at dictation time.
    ///
    /// **"(not installed)" only when it is true (fix round 1, MINOR).** A model that Ollama does
    /// list but that `api` cannot drive -- a `.chat` mode still naming an S1 build, or the
    /// reverse -- is not what "not installed" says: it sits in `~/.ollama` and is simply the wrong
    /// dialect for the kind currently picked. `model.ollamaModels` (the whole listing, unfiltered
    /// by kind) is what tells the two apart; `refinerChoices(for:)` alone cannot, since a name it
    /// excludes for being the wrong kind and a name genuinely absent from Ollama both fail its
    /// membership test identically.
    private func refinerModelOptions(for api: Mode.LLM.API, currentValue: String) -> [PickerOption] {
        var options = model.refinerChoices(for: api).map { PickerOption(value: $0.name, label: $0.name) }
        if !options.contains(where: { $0.value == currentValue }) {
            let label: String
            if currentValue.isEmpty {
                label = "(none)"
            } else if model.ollamaUnreachableNote != nil {
                label = currentValue
            } else if model.ollamaModels.contains(where: {
                OllamaProbe.tagged($0.name) == OllamaProbe.tagged(currentValue)
            }) {
                label = "\(currentValue) (not usable with this kind)"
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
    /// (`ModesPaneModel.ollamaModels`), limited to the current kind
    /// (`ModesPaneModel.refinerChoices(for:)`). When Ollama could not be reached at all, the
    /// picker still holds the mode's stored value (`refinerModelOptions`'s fallback) and the note
    /// below names why, in `OllamaFailure`'s own wording -- the same sentence a dictation failure
    /// would show, so there are not two vocabularies for one server being unreachable.
    ///
    /// **Each row carries its own fit badge (task 6, spec §6).** `model.fit(forRefiner:)` is nil
    /// for the one fallback row that is not actually one of `ollamaModels` -- the mode's stored
    /// value when it is not installed -- so that row alone draws no badge, which is correct: there
    /// is no size to classify for a model Ollama never reported.
    private func refinerModelPicker(_ draft: ModeDraft) -> some View {
        let options = refinerModelOptions(for: draft.mode.llm.api, currentValue: draft.mode.llm.model)
        return labelled("Refiner model", note: model.ollamaUnreachableNote) {
            Picker("", selection: text(\.llm.model)) {
                ForEach(options) { option in
                    refinerModelRow(option).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// One row of the Refiner model picker: the name, and -- when `model.fit(forRefiner:)` has an
    /// answer -- a small badge naming how this model sits against this Mac's own memory.
    private func refinerModelRow(_ option: PickerOption) -> some View {
        HStack(spacing: 6) {
            Text(option.label)
            if let fit = model.fit(forRefiner: option.value) {
                Spacer(minLength: 8)
                Label(fit.label, systemImage: fit.symbolName)
                    .font(.caption2)
                    .foregroundStyle(Color(role: .secondaryText))
            }
        }
    }

    /// The three context sources, as three toggles and not one control: they are independent, and
    /// spec §5 stores them that way. What they feed is `RefinementRequest.systemTurn`, assembled
    /// from whatever `Instructions` holds plus whichever of these is on -- which is why this sits
    /// right under that field rather than on the advanced screen where it used to live.
    ///
    /// **A compact row, not a stacked field (task 6).** Three independent switches used to cost
    /// three full `labelled` rows -- a label column and a description each -- which is more room
    /// than three yes/no questions need once the whole editor is two cards instead of one long
    /// list. Each toggle keeps its label (`ContextSource.label`) beside its switch and its
    /// description (`ContextSource.description`) as a `.help` tooltip rather than a printed line --
    /// still one hover away, not gone.
    ///
    /// **Shown and DISABLED under `api: .s1`, never hidden.** An `s1` mode's instructions are a
    /// control line the model copies into its answer rather than reads (`Mode/LLM/API/s1`), so
    /// there is nowhere for a selection, a clipboard or an app name to go -- `RefinementRequest`
    /// already refuses to fold them in for that api. Hiding the row would read as a missing
    /// feature; disabling it with a reason says what it is instead: a control that does nothing
    /// here, not a control that was never built. The reason itself is shared with a test in
    /// `MurmureCore` (`ContextSource.s1DisabledReason`), so the sentence in the view and the one
    /// that test pins can never say two different things about the same api.
    private func contextGroup(_ draft: ModeDraft) -> some View {
        let disabledForS1 = draft.mode.llm.api == .s1
        return VStack(alignment: .leading, spacing: ModesLayout.messageSpacing) {
            HStack(spacing: 16) {
                // The three labels come from `ContextSource.label` rather than being typed again
                // here -- this file used to spell the third one "Frontmost app", one word short of
                // `ContextSource.frontmostApp.label`'s "Frontmost application", which is also what
                // the system turn itself is headed with (review, lot 3a, item 7).
                compactContextToggle(.selectedText, isOn: flag(\.context.selectedText), disabled: disabledForS1)
                compactContextToggle(.clipboard, isOn: flag(\.context.clipboard), disabled: disabledForS1)
                compactContextToggle(.frontmostApp, isOn: flag(\.context.appContext), disabled: disabledForS1)
            }
            if disabledForS1 {
                Text(ContextSource.s1DisabledReason)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One switch of the compact Context row: its own label beside it, its description as a
    /// hover tooltip.
    private func compactContextToggle(
        _ source: ContextSource, isOn: Binding<Bool>, disabled: Bool
    ) -> some View {
        Toggle(source.label, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color(role: .primaryText))
            .disabled(disabled)
            .help(source.description)
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

            // A conversation with a local model that ends, when it goes well, with a fenced JSON
            // block Murmure turns into the SAME `ModeDraft` a preset does -- reviewed and saved in
            // the ordinary editor, never written by the model itself
            // (`ModesPaneModel.useDraftedMode`).
            Button {
                model.beginDraftingModeWithHelp()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Draft with help")
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
