import MurmureCore
import SwiftUI

/// What "Inspect" found, and the one Install button that acts on it.
///
/// A sheet rather than growing `ModelsPaneView` downward: what a repository can answer with --
/// dozens of speech variants, several GGUF quantisations, or a GGUF-conversion search -- is a
/// list nobody wants sitting permanently under the table, and it belongs to one repository at a
/// time, not to the pane itself.
///
/// **No decision is written here.** Which candidates exist, which role is unambiguous, and
/// whether Install may be pressed are `ModelsPaneModel`/`ModelClassifier` -- tested in
/// `MurmureCore` where that is possible, read here without a second opinion on it.
struct InspectSheetView: View {
    @ObservedObject var model: ModelsPaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.vertical, 4)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: WindowLayout.inspectSheetWidth)
        .frame(minHeight: WindowLayout.inspectSheetHeight.minimum, maxHeight: WindowLayout.inspectSheetHeight.maximum)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Cancel") { model.dismissInspection() }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .rounded))
        }
    }

    private var title: String {
        switch model.inspection {
        case .huggingFace(let repository, _): repository
        case .ollamaName(let name): name
        case .failure, .none: "Add a model"
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch model.inspection {
        case .huggingFace(_, let classification):
            classificationContent(classification)
        case .ollamaName(let name):
            // The radio still shows here, disabled, for the same reason `roleRadio`'s own doc
            // comment gives for `.speechOnly`/`.refinerOnly`: Louis sees what Murmure decided
            // rather than have it happen silently, even though an Ollama name has only one role
            // it could ever be.
            roleRadio(allowSpeech: false, allowRefiner: true)
            caption("Not a Hugging Face repository -- read as an Ollama model name and pulled as \"\(name)\".")
        case .failure(let detail):
            caption(detail)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func classificationContent(_ classification: HuggingFaceClassification) -> some View {
        switch classification {
        case .speechOnly(let speech):
            roleRadio(allowSpeech: true, allowRefiner: false)
            candidateList(speech: speech)
        case .refinerOnly(let refiner):
            roleRadio(allowSpeech: false, allowRefiner: true)
            candidateList(refiner: refiner)
        case .both(let speech, let refiner):
            roleRadio(allowSpeech: true, allowRefiner: true)
            if model.selectedRole == .refiner {
                candidateList(refiner: refiner)
            } else {
                candidateList(speech: speech)
            }
        case .notRunnable(let reason, let hasSafetensors):
            caption(reason)
            if hasSafetensors {
                suggestionsSection
            }
        }
    }

    /// **Always visible, even when only one role has candidates** -- so Louis can see what
    /// Murmure decided rather than have it happen silently. Disabled in that case: there is
    /// nothing on the other side of the switch to install.
    private func roleRadio(allowSpeech: Bool, allowRefiner: Bool) -> some View {
        Picker("Install as", selection: Binding(
            get: { model.selectedRole ?? (allowSpeech ? .speech : .refiner) },
            set: { model.selectRole($0) }
        )) {
            Text("Speech model").tag(ModelRole.speech)
            Text("Refiner model").tag(ModelRole.refiner)
        }
        .pickerStyle(.segmented)
        .disabled(!(allowSpeech && allowRefiner))
        .labelsHidden()
    }

    // MARK: - Candidates

    private func candidateList(speech candidates: [SpeechCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(candidates, id: \.variant) { candidate in
                candidateRow(
                    id: candidate.variant, title: candidate.variant, subtitle: nil, bytes: candidate.bytes)
            }
        }
    }

    private func candidateList(refiner candidates: [RefinerCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(candidates, id: \.filename) { candidate in
                candidateRow(
                    id: candidate.filename, title: candidate.tag, subtitle: candidate.filename,
                    bytes: candidate.bytes)
            }
        }
    }

    private func candidateRow(id: String, title: String, subtitle: String?, bytes: Int64?) -> some View {
        let selected = model.selectedCandidateID == id
        return HStack(spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(Color(role: selected ? .primaryText : .secondaryText))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(bytes.map(ModelSize.readable) ?? "--")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                .fill(selected ? Color(role: .cardBackground) : Color.clear)
        )
        .onTapGesture { model.selectedCandidateID = id }
    }

    // MARK: - Not runnable

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isSearchingSuggestions {
                caption("Looking for a GGUF conversion on Hugging Face...")
            } else if model.ggufSuggestions.isEmpty {
                caption("No GGUF conversion found on Hugging Face.")
            } else {
                caption("Possible GGUF conversions:")
                ForEach(model.ggufSuggestions, id: \.self) { suggestion in
                    HStack {
                        Text(suggestion)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Color(role: .primaryText))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Inspect this instead") { Task { await model.inspectSuggestion(suggestion) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.installError {
                caption(error)
            }
            if let status = model.refinerInstallStatus {
                caption(status)
            }
            Spacer(minLength: 0)
            if isInstalling {
                // Indeterminate only, for a refiner pull and a speech download alike: a real
                // percentage would need a received-byte count from `WhisperKit.download`'s own
                // progress callback, which the engine does not surface -- it uses that callback only
                // to reset a stall-watchdog timer, never to report bytes. Do not fake a bar with no
                // real number behind it.
                ProgressView()
                    .controlSize(.small)
            } else if case .huggingFace(_, .notRunnable) = model.inspection {
                EmptyView()
            } else if model.inspection != nil {
                Button("Install") { Task { await model.installSelection() } }
                    .buttonStyle(.plain)
                    .disabled(!model.canInstallSelection)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                            .fill(Color(role: .cardBackground))
                    )
            }
        }
    }

    private var isInstalling: Bool { model.installingVariant != nil || model.isInstallingRefiner }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
