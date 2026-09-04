import MurmureCore
import SwiftUI

/// Vocabulary: two groups, each its own input row and its own alphabetical list -- "Words to
/// recognise" (a term alone, biasing the recogniser) and "Corrections" (a term and its
/// replacement, correcting a known mis-hearing both in the prompt and in the transcript
/// afterwards). Drawn apart on purpose: a single row with an arrow between two fields reads as
/// one operation ("turn A into B") for entries where there is no B, which is exactly the
/// affordance `VocabularyEntry`'s bare-term half was missing. `VocabularyGroup` (`MurmureCore`)
/// is the one place that decides the split, the heading and the empty-state wording; this view
/// only draws what it is handed.
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

    // MARK: - One group: heading, input row, list

    private func group(_ kind: VocabularyGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.heading)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
                .padding(.horizontal, 16)
            inputRow(for: kind)
                .padding(.horizontal, 16)
            list(for: kind)
        }
    }

    @ViewBuilder
    private func inputRow(for kind: VocabularyGroup) -> some View {
        switch kind {
        case .wordsToRecognise:
            field("New word", text: $wordField) { commitWord() }
        case .corrections:
            HStack(spacing: 8) {
                field("Mis-heard as", text: $correctionTermField) { commitCorrection() }
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(role: .secondaryText))
                field("Should be", text: $correctionReplacementField) { commitCorrection() }
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

    /// Committing an empty word does nothing -- the input row's placeholder text is not a value.
    private func commitWord() {
        guard !wordField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.add(term: wordField, replacement: "")
        wordField = ""
    }

    /// Return in either field commits both -- a correction with an empty replacement would just be
    /// a bare word, so an empty "Should be" is refused here rather than silently downgrading the
    /// group the user typed into.
    private func commitCorrection() {
        let trimmedTerm = correctionTermField.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = correctionReplacementField.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty, !trimmedReplacement.isEmpty else { return }
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
        return LazyVStack(alignment: .leading, spacing: 2) {
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

    /// Left column = the term; a replacement, when there is one, follows an arrow chip in a second
    /// column (design notes §1.2). No card, no divider -- the hover highlight below is the only
    /// surface a row ever draws.
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
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(
                            cornerRadius: WindowLayout.chipCornerRadius, style: .continuous
                        )
                        .fill(Color(role: .cardBackground))
                    )
                Text(replacement)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
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
                .fill(isHovered ? Color(role: .cardBackground) : Color.clear)
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
