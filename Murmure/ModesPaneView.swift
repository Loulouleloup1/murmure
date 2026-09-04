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
        .onAppear { model.reload() }
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
                // Derived, never stored (D14): a microphone for a mode that only transcribes,
                // sparkles for one that sends what is said to a language model.
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

    @ViewBuilder
    private var editor: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
                hairline
                field("Name", text: text(\.name), placeholder: "Voice")
                field("Language", text: text(\.stt.language), placeholder: "fr")
                field("Speech model", text: text(\.stt.model), placeholder: "large-v3-turbo")

                // The one switch that changes what the mode *is*, which is why it is here and not
                // on the advanced screen: it decides whether what Louis says reaches a language
                // model at all, and it is what the row's second badge is drawn from.
                toggle("Refine the transcript", isOn: flag(\.llm.enabled))

                if draft.mode.llm.enabled {
                    field("Refiner model", text: text(\.llm.model),
                          placeholder: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M")
                    // The note is the fix for Louis opening `Prompt`, reading
                    // `"[Context: general]"` and concluding there was no prompt at all: under
                    // `api: .s1` this field is a control line the model copies rather than reads,
                    // and that has to be readable right here, not only in `apiPicker`'s note on
                    // the other screen.
                    field("Instructions", text: text(\.instructions),
                          placeholder: draft.mode.llm.api == .s1
                              ? "[Context: general]" : "Clean up the transcript.",
                          note: draft.mode.llm.api == .s1
                              ? "A control line for the s1 model (bracketed fields only, e.g. "
                                  + "\u{201C}[Context: general]\u{201D}) -- the model copies this "
                                  + "into its answer instead of following it."
                              : "The written prompt sent to the refiner model as its system turn.",
                          lines: 2...6)
                    contextGroup(draft)
                }

                advancedButton(draft)
                actions(draft)
            }
            .padding(.horizontal, ModesLayout.rowPadding.horizontal)
            .padding(.bottom, ModesLayout.rowPadding.vertical + 4)
        }
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
                        apiPicker(draft)
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
    /// Shown only when the refiner is on, because with it off the field decides nothing. A
    /// segmented picker rather than a toggle: these are two dialects, not on and off, and a third
    /// one is a case in `Mode.LLM.API` rather than a redesign here.
    @ViewBuilder
    private func apiPicker(_ draft: ModeDraft) -> some View {
        if draft.mode.llm.enabled {
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
    private func contextGroup(_ draft: ModeDraft) -> some View {
        let disabledForS1 = draft.mode.llm.api == .s1
        return VStack(alignment: .leading, spacing: ModesLayout.fieldSpacing) {
            toggle("Selected text", isOn: flag(\.context.selectedText), disabled: disabledForS1)
            toggle("Clipboard", isOn: flag(\.context.clipboard), disabled: disabledForS1)
            toggle("Frontmost app", isOn: flag(\.context.appContext), disabled: disabledForS1)
            if disabledForS1 {
                Text("Not available on s1 -- its instructions are a control line the model copies "
                    + "into its answer rather than reads, so there is nowhere for this context to "
                    + "go. Switch \u{201C}Refiner API\u{201D} to chat on Advanced to use it.")
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

    private func toggle(_ label: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        labelled(label, note: nil) {
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
