import MurmureCore
import SwiftUI

/// "Draft a mode with help": a conversation with a local Ollama model that ends, when it goes
/// well, with a fenced JSON block Murmure can turn straight into a `ModeDraft` -- opened in the
/// ordinary editor for the person to review, describe further, and save themselves. Nothing here
/// is saved by the model; "Use this draft" only hands a `Mode` value to the same editor a
/// hand-made mode goes through.
///
/// **No colour is written in this file.** Same rule as `ModesPaneView`, `InspectSheetView` (Q-NB6).
struct ModeDraftSheetView: View {
    @ObservedObject var paneModel: ModeDraftPaneModel
    let onCancel: () -> Void
    let onUseDraft: (Mode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if paneModel.chatCapableModels.isEmpty {
                noModelsNotice
            } else {
                modelPicker
            }
            conversationLog
            notices
            inputRow
            Divider()
            footer
        }
        .padding(20)
        .frame(width: WindowLayout.draftSheetWidth)
        .frame(
            minHeight: WindowLayout.draftSheetHeight.minimum,
            maxHeight: WindowLayout.draftSheetHeight.maximum)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Draft a mode with help")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
        }
    }

    // MARK: - Model picker

    private var modelPicker: some View {
        HStack(spacing: 8) {
            Text("Model")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            Picker("", selection: Binding(
                get: { paneModel.conversation.model },
                set: { paneModel.selectModel($0) }
            )) {
                ForEach(paneModel.chatCapableModels, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Spacer()
        }
    }

    private var noModelsNotice: some View {
        caption(
            "No chat-capable model is installed. Install one from the Models pane (gemma4:12b-it-qat, "
                + "for instance), then reopen this sheet.")
    }

    // MARK: - Conversation

    private var conversationLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ModesLayout.draftBubbleSpacing) {
                    ForEach(paneModel.conversation.turns) { turn in
                        bubble(role: turn.role, text: turn.content).id(turn.id)
                    }
                    if paneModel.isSending {
                        bubble(
                            role: .assistant,
                            text: paneModel.streamingReply.isEmpty ? "…" : paneModel.streamingReply
                        )
                        .id("streaming")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: paneModel.conversation.turns.count) { _, _ in
                withAnimation {
                    proxy.scrollTo(paneModel.conversation.turns.last?.id, anchor: .bottom)
                }
            }
        }
    }

    private func bubble(role: ModeDraftingConversation.Turn.Role, text: String) -> some View {
        HStack {
            if role == .user { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(segments(of: text).enumerated()), id: \.offset) { _, segment in
                    Text(segment.text)
                        .font(
                            segment.isCode
                                ? .system(size: 11, design: .monospaced)
                                : .system(size: 12, design: .rounded))
                        .foregroundStyle(Color(role: .primaryText))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: role == .user ? .selection : .cardBackground))
            )
            .frame(
                maxWidth: WindowLayout.draftSheetWidth * ModesLayout.draftBubbleMaxWidthFraction,
                alignment: .leading)
            if role == .assistant { Spacer(minLength: 24) }
        }
    }

    /// Splits one message into prose and fenced-code segments, purely for the monospaced rendering
    /// the JSON block deserves -- cosmetic only, never consulted to decide whether a draft is valid
    /// (`ModeDraftExtraction`, in `MurmureCore`, owns that entirely).
    private struct Segment {
        let text: String
        let isCode: Bool
    }

    private func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        var isCode = false
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !current.isEmpty {
                    result.append(Segment(text: current.joined(separator: "\n"), isCode: isCode))
                }
                current = []
                isCode.toggle()
                continue
            }
            current.append(line)
        }
        if !current.isEmpty {
            result.append(Segment(text: current.joined(separator: "\n"), isCode: isCode))
        }
        return result
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let note = paneModel.networkNote {
            caption(note)
        }
        if let problem = paneModel.problem {
            caption(problem)
        }
        if let candidate = paneModel.candidate {
            if !candidate.sttModelInstalled {
                caption(
                    "\"\(candidate.mode.stt.model)\" is not installed -- this mode would fall back "
                        + "to the shipped speech model until it is pulled.")
            }
            if !candidate.llmModelInstalled {
                caption(
                    "\"\(candidate.mode.llm.model)\" is not installed -- the refiner would fail "
                        + "until it is pulled.")
            }
        }
        if paneModel.conversation.truncatedTurnCount > 0 {
            caption(
                "\(paneModel.conversation.truncatedTurnCount) earlier turn(s) dropped to fit the "
                    + "model's context window.")
        }
        if paneModel.replyWasTruncated {
            caption(
                "The reply was cut off before the end -- ask for a shorter mode, or continue the "
                    + "conversation.")
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Describe the mode you want…", text: $paneModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                        .fill(Color(role: .paneBackground))
                )
                .disabled(paneModel.chatCapableModels.isEmpty)
                .onSubmit { Task { await paneModel.send() } }
            Button("Send") { Task { await paneModel.send() } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
                .disabled(
                    paneModel.isSending || paneModel.chatCapableModels.isEmpty
                        || paneModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if paneModel.isSending {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Use this draft") {
                if let mode = paneModel.candidate?.mode {
                    onUseDraft(mode)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(role: paneModel.candidate == nil ? .secondaryText : .primaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                    .fill(Color(role: .cardBackground))
            )
            .disabled(paneModel.candidate == nil)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .fixedSize(horizontal: false, vertical: true)
    }
}
