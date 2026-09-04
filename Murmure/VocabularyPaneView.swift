import MurmureCore
import SwiftUI

/// Vocabulary: two groups, each its own input row and its own alphabetical list -- "Words to
/// recognise" (a term alone, biasing the recogniser) and "Corrections" (a term and its
/// replacement, correcting a known mis-hearing both in the prompt and in the transcript
/// afterwards). Drawn apart on purpose: a single row with an arrow between two fields reads as
/// one operation ("turn A into B") for entries where there is no B, which is exactly the
/// affordance `VocabularyEntry`'s bare-term half was missing. `VocabularyGroup` (`MurmureCore`)
/// is the one place that decides the split, the heading (with its count and subtitle) and the
/// empty-state wording; `VocabularyPromptPlan.budgetLine` decides what the cap has done to the
/// vocabulary; `VocabularyEntry.isWordAddable`/`isCorrectionAddable` decide whether an input row's
/// current text would commit anything. This view only draws what it is handed.
///
/// Each input row carries a visible Add button beside it now, not only Enter -- a not-very-savvy
/// user typing a word had no way to discover that Enter was how it got added (Louis's own report).
///
/// **No colour is written in this file.** Every one goes through `Color(role:)`, the same rule
/// `HistoryPaneView` follows and for the same reason (Q-NB6).
struct VocabularyPaneView: View {
    @ObservedObject var model: VocabularyPaneModel

    @State private var wordField = ""
    @State private var correctionTermField = ""
    @State private var correctionReplacementField = ""
    /// Which row the pointer is over. One at a time: the delete affordance is hover-only (design
    /// notes §1.2), so only the row underneath the pointer may show it.
    @State private var hoveredTerm: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner = model.banner {
                problemRow(banner)
            }
            if let notice = promptPlan.noticeText {
                capNotice(notice)
            }
            if let budgetLine {
                budgetLineRow(budgetLine)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: WindowLayout.vocabularyGroupSpacing) {
                    group(.wordsToRecognise)
                    group(.corrections)
                }
                .padding(.vertical, 4)
            }
            .background(Color(role: .paneBackground))
        }
        .onAppear { model.reload() }
    }

    /// What a cap left out of the recogniser's prompt, across BOTH groups: `VocabularyPrompt`
    /// caps the combined ordered list, not either group on its own, so the notice above is shown
    /// once, spanning both, rather than nested under one of the two headings.
    private var promptPlan: VocabularyPromptPlan {
        VocabularyPrompt.plan(for: model.entries)
    }

    // MARK: - One group: header, input row, list

    private func group(_ kind: VocabularyGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(kind)
                .padding(.horizontal, 16)
            inputRow(for: kind)
                .padding(.horizontal, 16)
            list(for: kind)
        }
    }

    /// The heading with its count, then what this group's list actually does -- both drawn from
    /// `VocabularyGroup` so the wording lives in one place and this file only draws it (design
    /// notes' own "a not-very-savvy user" concern: the group's purpose should not have to be
    /// discovered by trial and error). The budget line is NOT here: it counts the whole
    /// vocabulary, both groups combined, so it is drawn once at pane level (`budgetLineRow`
    /// above) rather than under either group's own heading -- a "Words to recognise · 12"
    /// followed by "All 16 terms reach the recogniser" would contradict itself.
    private func header(_ kind: VocabularyGroup) -> some View {
        VStack(alignment: .leading, spacing: WindowLayout.vocabularyHeaderSpacing) {
            Text(kind.headingWithCount(model.entries(in: kind).count))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            Text(kind.subtitle)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
        }
    }

    /// How many of the WHOLE vocabulary's entries (both groups) reach the recogniser, and how
    /// many a cap left out -- distinct from `capNotice` above, which only appears once a cap
    /// actually bites and names the entries it dropped. This one is a standing readout
    /// (`VocabularyPromptPlan.budgetLine`'s own header), so a not-very-savvy user learns the cap
    /// exists before ever hitting it.
    private var budgetLine: String? {
        promptPlan.budgetLine(totalEntries: model.entries.count)
    }

    /// Same styling as `capNotice`: information, not a warning, at the same spot in the same
    /// voice -- the pane's problem banner, cap notice and budget line are three lines of the same
    /// kind, stacked in that order.
    private func budgetLineRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func inputRow(for kind: VocabularyGroup) -> some View {
        switch kind {
        case .wordsToRecognise:
            HStack(spacing: 8) {
                field("New word", text: $wordField) { commitWord() }
                addButton(disabled: !VocabularyEntry.isWordAddable(wordField)) { commitWord() }
            }
        case .corrections:
            HStack(spacing: 8) {
                field("Mis-heard as", text: $correctionTermField) { commitCorrection() }
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
                field("Should be", text: $correctionReplacementField) { commitCorrection() }
                addButton(
                    disabled: !VocabularyEntry.isCorrectionAddable(
                        term: correctionTermField, replacement: correctionReplacementField)
                ) {
                    commitCorrection()
                }
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void)
        -> some View
    {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(Color(role: .primaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .cardBackground))
            )
            .onSubmit(onSubmit)
    }

    /// The one visible button either input row needs (Louis's own ask -- Enter alone gave a
    /// not-very-savvy user no way to discover that typing a word was not enough; discoverability
    /// was the whole point, hence a titled button rather than a bare glyph). `.bordered` at
    /// `.small`, the same style `GeneralPaneView`'s hotkey Record/Cancel button already uses --
    /// the one existing "visible button" style in the app, not a third one invented for this pane.
    /// Disabled exactly when `commitWord`/`commitCorrection` would do nothing, via the same
    /// `VocabularyEntry` rule those functions call, so the button and Enter never disagree about
    /// what counts as addable.
    private func addButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button("Add", action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(disabled)
    }

    /// Committing an empty word does nothing -- the input row's placeholder text is not a value.
    /// The same `isWordAddable` rule the Add button is disabled by, so pressing Enter and clicking
    /// the button next to it can never disagree about whether there was anything to commit.
    private func commitWord() {
        guard VocabularyEntry.isWordAddable(wordField) else { return }
        model.add(term: wordField, replacement: "")
        wordField = ""
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
    }

    /// Information, not a warning (the cap is deliberate and measured, not a failure): named,
    /// because a user who can see which of their words is not reaching the recogniser can act on
    /// it. Shown once, above both groups -- not scoped to either -- because a correction costs a
    /// slot in that same prompt exactly like a bare term (`VocabularyPrompt`'s own header).
    private func capNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    private func problemRow(_ problem: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(problem).lineLimit(3)
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissProblem() }
                .buttonStyle(.plain)
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(Color(role: .secondaryText))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - One group's list

    private func list(for kind: VocabularyGroup) -> some View {
        let groupEntries = model.entries(in: kind)
        // History's own gap (design notes §1.3), adopted along with History's always-on card --
        // a row that is now a full card needs the same room around it History's cards get, or
        // adjacent cards read as one fused block rather than a list of rows.
        return LazyVStack(alignment: .leading, spacing: HistoryLayout.rowSpacing) {
            ForEach(groupEntries, id: \.term) { entry in
                row(entry)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: groupEntries.isEmpty ? 60 : 0)
        .overlay {
            if let message = model.emptyListMessage(for: kind) {
                emptyList(message)
            }
        }
    }

    /// Left column = the term in primary text; a replacement, when there is one, follows the same
    /// plain arrow glyph the input row draws between its own two fields, in secondary text -- a
    /// second, quieter voice than the term, since the term is what is actually being matched.
    ///
    /// **The card is drawn at rest, not only on hover** -- History's convention (§1.3), adopted
    /// here, which is why the arrow carries no filled chip of its own any more: a `cardBackground`
    /// chip on a `cardBackground` row would vanish the moment the row's own always-on fill was
    /// added, exactly the contrast an unfilled glyph does not risk. This is a documented
    /// divergence from the installed Superwhisper app's own Vocabulary list (design notes §1.2:
    /// "no card, no dividers" and a hover-only fill) -- see the dated note there. The delete
    /// affordance stays hover-only, unaffected by the card becoming permanent.
    private func row(_ entry: VocabularyEntry) -> some View {
        let isHovered = hoveredTerm == entry.term
        return HStack(spacing: 10) {
            Text(entry.term)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
                .frame(width: 220, alignment: .leading)
            if let replacement = entry.replacement {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
                Text(replacement)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
            }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.rowCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
        )
        .onHover { hovering in hoveredTerm = hovering ? entry.term : nil }
    }

    /// A group's empty list is two different events -- no file yet (or nothing of this group's
    /// kind), or a file that will not parse -- and **which sentence that is is not decided here.**
    /// It is `VocabularyEmptyState`, in `MurmureCore`, where the parse failure can be produced by
    /// writing a real broken file.
    ///
    /// Centred and measured, like `HistoryPaneView`'s: both sentences run to two lines.
    private func emptyList(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
    }
}
