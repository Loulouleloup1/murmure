import MurmureCore
import SwiftUI

/// Vocabulary: one composer at the top switching between the two groups it can add to -- "Words
/// to recognise" (a term alone, biasing the recogniser) and "Corrections" (a term and its
/// replacement, correcting a known mis-hearing both in the prompt and in the transcript
/// afterwards) -- and, below it, both groups' own lists, always visible together.
/// `VocabularyGroup` (`MurmureCore`) is the one place that decides the split, the heading (with
/// its count and subtitle) and the empty-state wording; `VocabularyPromptPlan.budgetLine` decides
/// what the cap has done to the vocabulary; `VocabularyEntry.isWordAddable`/`isCorrectionAddable`
/// decide whether the composer's current text would commit anything. This view only draws what it
/// is handed.
///
/// Redesigned per owner feedback: the old Add button was "too small and discreet" beside a
/// bare-glyph row -- this pane now leads with one composer card holding a segmented picker (which
/// group is being added to), the fields, and a wide, filled, coloured Add button (`WindowLayout
/// .vocabularyAddButtonFraction`, about 30 % of the row) so the primary action reads as one rather
/// than being rediscovered per group. The two lists below are unchanged in what they show, drawn
/// as chips (words) and rows (corrections) inside their own `HomeCard`-style cards.
///
/// **No colour is written in this file.** Every one goes through `Color(role:)`, the same rule
/// `HistoryPaneView` follows and for the same reason (Q-NB6).
struct VocabularyPaneView: View {
    @ObservedObject var model: VocabularyPaneModel

    /// Which group the composer is currently adding to. Switching does not clear whatever text is
    /// already typed in either group's own fields -- a user who nudges the segmented control by
    /// accident should not lose what they were typing.
    @State private var composing: VocabularyGroup = .wordsToRecognise
    @State private var wordField = ""
    @State private var correctionTermField = ""
    @State private var correctionReplacementField = ""
    /// Focus stays in the first field after a commit (brief's own ask), rather than wherever
    /// `onSubmit` happened to leave it -- typing several words in a row should never require a
    /// reclick.
    @FocusState private var focusedField: ComposerField?
    /// Which chip or row the pointer is over. One at a time: the delete affordance is hover-only,
    /// so only the entry underneath the pointer may show it.
    @State private var hoveredTerm: String?

    private enum ComposerField: Hashable {
        case word
        case correctionTerm
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleRow
                if let banner = model.banner {
                    problemCard(banner, symbol: "exclamationmark.triangle")
                }
                if let notice = promptPlan.noticeText {
                    problemCard(notice, symbol: "exclamationmark.triangle", dismissable: false)
                }
                composer
                group(.wordsToRecognise)
                group(.corrections)
            }
            .frame(maxWidth: HomeLayout.contentMaxWidth)
            .padding(HomeLayout.panePadding)
            .frame(maxWidth: .infinity)
        }
        .background(Color(role: .paneBackground))
        .onAppear { model.reload() }
    }

    /// What a cap left out of the recogniser's prompt, across BOTH groups: `VocabularyPrompt`
    /// caps the combined ordered list, not either group on its own, so the notice is shown once,
    /// spanning both, rather than nested under one of the two headings.
    private var promptPlan: VocabularyPromptPlan {
        VocabularyPrompt.plan(for: model.entries)
    }

    /// How many of the WHOLE vocabulary's entries (both groups) reach the recogniser, and how
    /// many a cap left out -- a standing readout so a user learns the cap exists before ever
    /// hitting it, not just once it bites (that is `noticeText`, drawn separately above).
    private var budgetLine: String? {
        promptPlan.budgetLine(totalEntries: model.entries.count)
    }

    // MARK: - Title row

    /// "Vocabulary", same style as the Home title, with the budget line as a small pill on the
    /// trailing edge when there is one to show.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Vocabulary").font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            Spacer()
            if let budgetLine {
                Text(budgetLine)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(role: .cardBackground))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(role: .hairline), lineWidth: 1)))
            }
        }
    }

    /// A full-width card for the cap notice or the save-problem banner -- same voice, same
    /// placement, the only difference being whether a Dismiss button applies (a cap notice is not
    /// something to dismiss; it stays true until the cap stops biting).
    private func problemCard(_ text: String, symbol: String, dismissable: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color(role: .secondaryText))
            Text(text).font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            Spacer(minLength: 8)
            if dismissable {
                Button("Dismiss") { model.dismissProblem() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
            }
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
                .overlay(RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(role: .hairline), lineWidth: 1)))
    }

    // MARK: - Composer card

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $composing) {
                ForEach(VocabularyGroup.allCases, id: \.self) { kind in
                    Text(kind.composerTitle).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(composerHelperText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            composerFieldRow
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
                .overlay(RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(role: .hairline), lineWidth: 1)))
    }

    private var composerHelperText: String {
        switch composing {
        case .wordsToRecognise:
            "Whisper will be biased towards hearing this spelling."
        case .corrections:
            "Every time Whisper writes the left form, Murmure inserts the right one."
        }
    }

    /// The fields (70 % of the row) beside the Add button (30 %, `WindowLayout
    /// .vocabularyAddButtonFraction`). A `GeometryReader` sized to just this row, not the whole
    /// pane, is the simplest way to turn that fraction into an actual width without fighting
    /// `layoutPriority` over how the fields' own internal `HStack` wants to grow.
    private var composerFieldRow: some View {
        GeometryReader { proxy in
            let buttonWidth = proxy.size.width * WindowLayout.vocabularyAddButtonFraction
            HStack(spacing: 12) {
                composerFields
                    .frame(maxWidth: .infinity)
                addButton
                    .frame(width: buttonWidth)
            }
        }
        .frame(height: WindowLayout.vocabularyFieldHeight)
    }

    @ViewBuilder
    private var composerFields: some View {
        switch composing {
        case .wordsToRecognise:
            composerField("e.g. WeeFin", text: $wordField, focus: .word) { commitWord() }
        case .corrections:
            HStack(spacing: 12) {
                composerField("Mis-heard as", text: $correctionTermField, focus: .correctionTerm) {
                    commitCorrection()
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
                composerField("Should be", text: $correctionReplacementField, focus: nil) {
                    commitCorrection()
                }
            }
        }
    }

    private func composerField(
        _ placeholder: String, text: Binding<String>, focus: ComposerField?,
        onSubmit: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(Color(role: .primaryText))
            .padding(.horizontal, 10)
            .frame(height: WindowLayout.vocabularyFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .cardBackground))
                    .overlay(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                        .strokeBorder(Color(role: .hairline), lineWidth: 1)))
            .onSubmit(onSubmit)
            .modifier(FocusBinding(focus: focus, focusedField: $focusedField))
    }

    /// The composer's one Add button -- wide, filled, and coloured (owner feedback), rather than
    /// the previous pane's bare `.bordered` glyph beside each field. Enabled by the same
    /// `VocabularyEntry` rule Enter already commits by, so the button and Enter can never disagree
    /// about whether there is anything to add.
    private var addButton: some View {
        let disabled = !isComposerAddable
        return Button {
            commit()
        } label: {
            Label("Add", systemImage: "plus")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .materialGlyph))
                .frame(maxWidth: .infinity)
                .frame(height: WindowLayout.vocabularyFieldHeight)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                .fill(Color(role: .accent))
                .opacity(disabled ? 0.35 : 1))
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }

    private var isComposerAddable: Bool {
        switch composing {
        case .wordsToRecognise: VocabularyEntry.isWordAddable(wordField)
        case .corrections:
            VocabularyEntry.isCorrectionAddable(
                term: correctionTermField, replacement: correctionReplacementField)
        }
    }

    private func commit() {
        switch composing {
        case .wordsToRecognise: commitWord()
        case .corrections: commitCorrection()
        }
    }

    /// Committing an empty word does nothing -- the composer's placeholder text is not a value.
    /// The same `isWordAddable` rule the Add button is disabled by, so pressing Enter and clicking
    /// the button next to it can never disagree about whether there was anything to commit.
    private func commitWord() {
        guard VocabularyEntry.isWordAddable(wordField) else { return }
        model.add(term: wordField, replacement: "")
        wordField = ""
        focusedField = .word
    }

    /// Return in either field commits both -- a correction with an empty replacement would just be
    /// a bare word, so an empty "Should be" is refused here rather than silently downgrading the
    /// group the user typed into. The same `isCorrectionAddable` rule the Add button reads.
    private func commitCorrection() {
        guard
            VocabularyEntry.isCorrectionAddable(
                term: correctionTermField, replacement: correctionReplacementField)
        else { return }
        model.add(term: correctionTermField, replacement: correctionReplacementField)
        correctionTermField = ""
        correctionReplacementField = ""
        focusedField = .correctionTerm
    }

    // MARK: - One group: header + list, in a card

    private func group(_ kind: VocabularyGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(kind)
            list(for: kind)
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
                .overlay(RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(role: .hairline), lineWidth: 1)))
    }

    private func header(_ kind: VocabularyGroup) -> some View {
        VStack(alignment: .leading, spacing: WindowLayout.vocabularyHeaderSpacing) {
            Text(kind.headingWithCount(model.entries(in: kind).count))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            Text(kind.subtitle)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
        }
    }

    @ViewBuilder
    private func list(for kind: VocabularyGroup) -> some View {
        let groupEntries = model.entries(in: kind)
        if let message = model.emptyListMessage(for: kind) {
            emptyList(message)
        } else {
            switch kind {
            case .wordsToRecognise:
                FlowLayout(spacing: 8) {
                    ForEach(groupEntries, id: \.term) { entry in
                        chip(entry)
                    }
                }
            case .corrections:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groupEntries.enumerated()), id: \.element.term) { index, entry in
                        if index > 0 {
                            Rectangle().fill(Color(role: .hairline)).frame(height: 1)
                        }
                        correctionRow(entry)
                    }
                }
            }
        }
    }

    /// A word chip -- the term alone, with a hover-only delete glyph.
    private func chip(_ entry: VocabularyEntry) -> some View {
        let isHovered = hoveredTerm == entry.term
        return HStack(spacing: 6) {
            Text(entry.term)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            if isHovered {
                Button {
                    model.delete(entry)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(role: .secondaryText))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(role: .cardBackground))
                .overlay(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(Color(role: .hairline), lineWidth: 1)))
        .onHover { hovering in hoveredTerm = hovering ? entry.term : nil }
    }

    /// A correction row -- `term  →  replacement`, the arrow in secondary colour, with a
    /// hairline between rows (added by the caller) and a hover-only delete glyph, right-aligned.
    private func correctionRow(_ entry: VocabularyEntry) -> some View {
        let isHovered = hoveredTerm == entry.term
        return HStack(spacing: 10) {
            Text(entry.term)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(role: .secondaryText))
            Text(entry.replacement ?? "")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            Spacer(minLength: 8)
            if isHovered {
                Button {
                    model.delete(entry)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(role: .secondaryText))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .onHover { hovering in hoveredTerm = hovering ? entry.term : nil }
    }

    /// A group's empty list is two different events -- no file yet (or nothing of this group's
    /// kind), or a file that will not parse -- and **which sentence that is is not decided here.**
    /// It is `VocabularyEmptyState`, in `MurmureCore`, where the parse failure can be produced by
    /// writing a real broken file.
    private func emptyList(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(role: .hairline), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

/// Binds `$focusedField` to a `TextField` only when the field asks for it (`focus != nil`) --
/// the "Should be" field of a correction row is never a focus target on commit (`commitCorrection`
/// only ever restores focus to "Mis-heard as"), so it takes no `.focused` modifier at all rather
/// than one bound to a case it can never be assigned.
private struct FocusBinding<Field: Hashable>: ViewModifier {
    let focus: Field?
    var focusedField: FocusState<Field?>.Binding

    func body(content: Content) -> some View {
        if let focus {
            content.focused(focusedField, equals: focus)
        } else {
            content
        }
    }
}

/// A simple left-to-right, top-to-bottom wrapping flow of same-height chips (design notes' own
/// "wrapping flow" for the word chips). Handles an empty subview list (draws nothing) and a
/// proposal with a nil width (falls back to each subview's own ideal size, same as `HStack`)
/// -- the two edge cases the brief calls out.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x - bounds.minX + size.width > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
