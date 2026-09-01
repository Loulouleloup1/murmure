import Foundation

/// Which text of a record the detail pane is showing (D11).
///
/// Two, not the doc corpus's `Voice / Segments / AI`: `Segments` needs WhisperKit's per-segment
/// timings, which nothing stores and the spec never asked for.
public enum HistoryLens: String, Equatable, Sendable, CaseIterable {
    /// What Whisper heard, after the vocabulary replacements (§5.2).
    case raw
    /// What the mode's refiner made of it, which is what was pasted.
    case refined

    /// The word on the switch.
    public var title: String {
        switch self {
        case .raw: "Raw"
        case .refined: "Refined"
        }
    }
}

/// One line of the metadata block under the transcript (D9).
public struct HistoryMetadataRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String

    /// The label. Unique by construction — every row below is emitted at most once — and that is
    /// what makes it usable as an identity in a `ForEach`.
    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// What the right-hand pane shows for one record: which lenses it offers, the text behind each,
/// and the rows of metadata under them.
///
/// D9's answer to the doc corpus's third pane. Their inspector's rows are largely things Murmure
/// does not have — cloud voice model, separate-speakers, system-audio, tier, app version — and
/// what survives is about six rows, which fits under the transcript rather than beside it.
public enum HistoryDetail {
    // MARK: - The lens

    /// The lenses this record offers, or none at all.
    ///
    /// **The trap this function exists for.** `OllamaChat.verdict(on:)` trims the model's answer
    /// while the transcript reaches storage byte for byte — lot 1 pins that deliberately, and its
    /// fixture is literally `"  bonjour   Murmure\n"`. So a dictation whose refinement changed
    /// nothing but the edges stores a `refinedText` that differs from its raw transcript **only
    /// in characters nobody can see**, and a naive rule offers a switch between two panes that
    /// look identical. Louis would click it, watch nothing happen, and conclude the switch is
    /// broken.
    ///
    /// The split, and it is the whole of T5's answer: **what is OFFERED is decided on the trimmed
    /// texts; what is STORED is compared exactly.** T4 was right not to trim in the archive — what
    /// is stored must stay exactly what was pasted, and D6's "`refinedText` is NULL when no
    /// refinement ran" is a different guarantee that still holds. This is the display rule, and it
    /// lives here.
    ///
    /// Only the edges are ignored. A refinement that collapsed a run of spaces *inside* the
    /// sentence did change the text, invisibly but really, and the lens is offered for it —
    /// `trimmingCharacters` is used rather than `StatusPanelText.oneLine` for exactly that reason.
    ///
    /// An empty list is the answer, not a disabled switch: D11 says a record whose mode had no
    /// refiner shows **no switch at all**, and a control that cannot be operated is a control that
    /// has to be explained.
    public static func lenses(for record: HistoryRecord) -> [HistoryLens] {
        guard let refined = record.refinedText, let raw = record.rawTranscript else { return [] }
        let differs =
            refined.trimmingCharacters(in: .whitespacesAndNewlines)
            != raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return differs ? [.raw, .refined] : []
    }

    /// The lens the pane opens on.
    ///
    /// The refined text whenever there is one, offered switch or not: it is what landed under
    /// Louis's cursor, so it is the text he is looking for when he opens a row.
    public static func defaultLens(for record: HistoryRecord) -> HistoryLens {
        record.refinedText == nil ? .raw : .refined
    }

    /// The text one lens shows. `nil` when the record has none of it — a `.raw` lens on a
    /// dictation that transcribed nothing, or either lens on a row whose text the 30-day purge
    /// has cleared.
    public static func text(_ lens: HistoryLens, of record: HistoryRecord) -> String? {
        switch lens {
        case .raw: record.rawTranscript
        case .refined: record.refinedText
        }
    }

    /// Whether "Process again" can do anything with this row (D12).
    ///
    /// Re-refine only, so what it needs is a raw transcript to re-refine. A row whose text the
    /// purge has cleared, or a `.nothingHeard`, has nothing to send — and the WAV would not save
    /// it, because re-transcribing is the variant D12 rules out precisely because the audio is
    /// gone after three days.
    public static func canProcessAgain(_ record: HistoryRecord) -> Bool {
        guard let raw = record.rawTranscript else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - The metadata block

    /// The rows under the transcript, in order.
    ///
    /// **A column that is NULL yields no row at all**, rather than a row with an empty value or a
    /// dash. That is D6 followed all the way to the surface: every optional in `HistoryRecord` is
    /// a column that is genuinely absent, and `Language model —` would say the opposite of the
    /// truth about a `Voice` dictation, which never had one.
    public static func metadata(for record: HistoryRecord, calendar: Calendar) -> [
        HistoryMetadataRow
    ] {
        var rows: [HistoryMetadataRow] = []

        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(HistoryMetadataRow(label: label, value: value))
        }

        // The mode by NAME, which is the denormalised column §5.2 argued for: a row that could
        // only say `modeKey = "prompt"` for a file that has since been renamed is a row that
        // cannot be read.
        add("Mode", record.modeName)
        add("Speech model", record.sttModel)
        add("Language model", record.llmModel)
        // The application, by whichever half of it there is. `targetAppName` is what Louis
        // recognises; the bundle identifier is the fallback for an application that had no
        // localised name, and is better than nothing because it still names the app.
        add("Application", record.targetAppName ?? record.targetBundleID)
        add("Started", HistoryRow.timestamp(for: record.startedAt, calendar: calendar))
        add("Duration", HistoryRow.duration(record.durationSeconds))
        add("Transcribed in", record.transcriptionSeconds.map(HistoryRow.elapsed))
        add("Refined in", record.refinementSeconds.map(HistoryRow.elapsed))
        // Only where it means something. On a failed or cancelled dictation the count is zero
        // because nothing was inserted, and "Inserted 0 characters" reads as a measurement of a
        // thing that did not happen -- the same distinction `StatusPanelText` draws between a
        // completion and `nothingHeard`.
        if record.outcome == .inserted {
            add("Inserted", record.insertedCharacters == 1
                ? "1 character" : "\(record.insertedCharacters) characters")
        }
        add("Failure", record.failureMessage.map(StatusPanelText.oneLine))

        return rows
    }
}
