import MurmureCore
import SwiftUI

/// Vocabulary: one input row, then a flat alphabetical two-column list (design notes §1.2).
///
/// **No colour is written in this file.** Every one goes through `Color(role:)`, the same rule
/// `HistoryPaneView` follows and for the same reason (Q-NB6).
struct VocabularyPaneView: View {
    @ObservedObject var model: VocabularyPaneModel

    @State private var termField = ""
    @State private var replacementField = ""
    /// Which row the pointer is over. One at a time: the delete affordance is hover-only (design
    /// notes §1.2), so only the row underneath the pointer may show it.
    @State private var hoveredTerm: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if let problem = model.problem {
                problemRow(problem)
            }
            if !droppedEntries.isEmpty {
                capNotice
            }
            list
        }
        .onAppear { model.reload() }
    }

    /// Entries a cap left out of the recogniser's prompt -- NOT the entries merged by
    /// de-duplication, which `VocabularyPrompt.plan(for:)` already excludes because those are the
    /// same word twice, not a loss.
    private var droppedEntries: [VocabularyEntry] {
        VocabularyPrompt.plan(for: model.entries).dropped
    }

    // MARK: - The input row

    /// A term alone, or a term and its replacement -- Return in either field commits both
    /// (design notes §1.2, as settled for this task). Committing an empty term does nothing.
    private var inputRow: some View {
        HStack(spacing: 8) {
            field("New word", text: $termField)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(role: .secondaryText))
            field("Replacement (optional)", text: $replacementField)
        }
        .padding(16)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
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
            .onSubmit { commit() }
    }

    private func commit() {
        guard !termField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.add(term: termField, replacement: replacementField)
        termField = ""
        replacementField = ""
    }

    /// Information, not a warning (the cap is deliberate and measured, not a failure): named,
    /// because a user who can see which of their words is not reaching the recogniser can act on
    /// it, and a sentence about a threshold only leaves them counting rows.
    private var capNotice: some View {
        Text(capNoticeText)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    /// Up to three names, then a count of the rest -- long enough to act on, short enough to stay
    /// one line. A dropped entry is not useless: it still finds and replaces once the transcript
    /// comes back, it has just stopped biasing what gets heard in the first place.
    private var capNoticeText: String {
        let names = droppedEntries.map { "\u{201C}\($0.term)\u{201D}" }
        let shown = names.prefix(3).joined(separator: ", ")
        let remainder = names.count - min(names.count, 3)
        let subject = remainder > 0 ? "\(shown), and \(remainder) more" : shown
        return names.count == 1
            ? "\(subject) no longer guides the recogniser -- it still corrects the text "
                + "afterwards, just not what gets heard."
            : "\(subject) no longer guide the recogniser -- they still correct the text "
                + "afterwards, just not what gets heard."
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

    // MARK: - The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.entries, id: \.term) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .background(Color(role: .paneBackground))
        .overlay { if model.entries.isEmpty { emptyList } }
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

    /// T9 owns the full empty-state treatment (plan §6); this is the sentence it needs until then,
    /// the same provisional shape `HistoryPaneView.emptyList` uses.
    private var emptyList: some View {
        Text("No vocabulary yet.")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .padding(24)
    }
}
