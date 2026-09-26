import MurmureCore
import SwiftUI

/// Transcripts: a grid of tiles, and one transcript open as continuous text (criterion 16).
///
/// **One pane, two states**, rather than the list-plus-detail `HistoryPaneView` draws. A tile is
/// 200 to 340 points wide by construction (`TranscriptsLayout`), so the grid is what wants the
/// width -- a third column of a squeezed detail pane would leave both halves unreadable. Clicking
/// a tile is therefore the way in, and the way out is the header's own section title.
///
/// **No colour is written in this file.** Every one goes through `Color(role:)`, the condition
/// attached to shipping the window dark-only (Q-NB6) -- `HistoryPaneView`'s rule, one surface
/// over.
///
/// **Every measurement comes from the core.** The number of columns, the width of a tile, the
/// spacing and the padding are `TranscriptsLayout`'s (frozen by the lot-9 contract and tested
/// there), the reading measure is `HistoryLayout.transcriptMeasure` -- the same column the
/// History transcript is set in, because it is the same kind of text -- and the tile's radius is
/// `WindowLayout.rowCornerRadius`. Nothing here decides a number.
///
/// **The two actions of a tile are iterated from `TranscriptTile.actions` and switched on with no
/// `default`** (`actions(_:)`), which is the same guarantee `WindowSection`'s three switches make
/// one layer down: a third action would not compile into this view until somebody drew it. That
/// is the only mechanism that can hold criterion 17 here, because `Murmure/` has no test bundle.
struct TranscriptsPaneView: View {
    @ObservedObject var model: TranscriptsPaneModel

    /// The paragraph the pointer is over, so its timestamp can be revealed (criterion 16). UI
    /// state and nothing more: what the timestamp SAYS is `TranscriptsPaneModel.instant`.
    @State private var hovered: Int?
    /// The tile whose delete is being confirmed, and whether the dialog is up. The confirmation
    /// is what makes an irreversible delete safe -- the library deletes both files and neither
    /// comes back.
    @State private var tileToDelete: TranscriptTile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = model.openDocument {
                reading(document)
            } else {
                grid
            }
            if let problem = model.problem { problemBar(problem) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(role: .paneBackground))
        // The folder is re-walked on every appearance: a transcript written by an acquisition
        // while the window was on another section has to be there when this one comes back.
        .onAppear { model.reload() }
        .confirmationDialog(
            "Delete this transcript?", isPresented: confirmingDelete, presenting: tileToDelete
        ) { tuile in
            Button("Delete", role: .destructive) { model.delete(tuile) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // Says what it destroys: both files (the `.json` and the `.md`), and nothing brings
            // them back.
            Text("The transcript will be removed. This cannot be undone.")
        }
    }

    private var confirmingDelete: Binding<Bool> {
        Binding(
            get: { tileToDelete != nil },
            set: { if !$0 { tileToDelete = nil } })
    }

    // MARK: - The grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            // The pane's own width is what decides the grid: `TranscriptsLayout` is given the
            // room the padding leaves and answers the column count and the tile width. A
            // `GeometryReader` is the only way to read it before drawing.
            GeometryReader { geometry in
                let disponible = max(
                    0, geometry.size.width - 2 * TranscriptsLayout.contentPadding)
                let colonnes = TranscriptsLayout.columns(inWidth: disponible)
                let largeur = TranscriptsLayout.tileWidth(
                    inWidth: disponible, columns: colonnes)
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .fixed(largeur), spacing: TranscriptsLayout.tileSpacing),
                            count: colonnes),
                        alignment: .leading,
                        spacing: TranscriptsLayout.tileSpacing
                    ) {
                        ForEach(model.tiles) { tuile in
                            tile(tuile)
                        }
                    }
                    .padding(TranscriptsLayout.contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The panel's header: the R3 affordance and the one sentence an empty or half-readable
    /// library needs.
    ///
    /// The button is **the panel's**, above the grid, and never a tile's: criterion 17 is open and
    /// delete, so the third thing this pane can do with the library lives here, where it belongs
    /// to the folder rather than to any one transcript.
    ///
    /// Disabled rather than hidden when the folder does not exist yet (a first launch that has
    /// never written a transcript): a button that comes and goes is a button Louis has to look
    /// for, which is the argument `HistoryPaneView` makes for its audio actions. Nothing is
    /// created to make it work -- opening the window must not build a folder in Application
    /// Support.
    private var panelHeader: some View {
        HStack(spacing: 10) {
            Button {
                model.revealFolder()
            } label: {
                // The label is read off `MenuText`, never written here: a word typed into a view
                // is a word `MenuTextTests`' language rule cannot see, and this one is frozen.
                Label(MenuText.revealTranscriptsFolder, systemImage: "folder")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(role: .secondaryText))
            .disabled(!model.canReveal)

            // A transcript on disk that the grid cannot show is the one thing that would
            // otherwise be a silent hole (criterion 14). The sentence is built by the model.
            if let note = model.unreadableNote {
                Text(note)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(role: .secondaryText))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: WindowLayout.headerHeight,
               maxHeight: WindowLayout.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(role: .hairline))
                .frame(height: WindowLayout.hairlineWidth)
        }
    }

    /// One tile, **iterated from the actions it offers**, and the `switch` has no `default` — see
    /// the type's own note. Adding a third action to `TranscriptTile.Action` stops this
    /// compiling, which is criterion 17's only possible guard in a target with no test bundle.
    ///
    /// The two are drawn in one `ZStack` so the card keeps its shape: the body of the card is the
    /// `open` action, and `delete` is the glyph in its top-right corner — the arrangement every
    /// grid of thumbnails uses, and the one that keeps the two actions from looking like one.
    @ViewBuilder
    private func tile(_ tuile: TranscriptTile) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(tuile.actions, id: \.self) { action in
                switch action {
                case .open: openCard(tuile)
                case .delete: deleteButton(tuile)
                }
            }
        }
    }

    /// What a tile shows (criterion 16), and the click that opens it.
    ///
    /// `contentShape` makes the whole card the target, the gaps between its lines included, so a
    /// click near an edge is still a click on the tile.
    private func openCard(_ tuile: TranscriptTile) -> some View {
        Button {
            model.open(tuile)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(tuile.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(tuile.source)
                    Text("·")
                    Text(tuile.date)
                    Spacer(minLength: 6)
                    Text(tuile.duration)
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
                // A document written before its first unit has no text, and an empty line here
                // would be a placeholder nobody decided -- `TranscriptTile`'s rule 7. The line
                // goes, and the card just gets shorter.
                if !tuile.summary.isEmpty {
                    Text(tuile.summary)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color(role: .secondaryText))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WindowLayout.rowCornerRadius, style: .continuous)
                    .fill(Color(role: .cardBackground))
            )
            .contentShape(
                RoundedRectangle(cornerRadius: WindowLayout.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Delete, with its confirmation. The glyph rather than a word: criterion 17's two actions are
    /// the tile's whole vocabulary, and the card's own body is already the first of them.
    private func deleteButton(_ tuile: TranscriptTile) -> some View {
        Button {
            tileToDelete = tuile
        } label: {
            Label("Delete", systemImage: "trash")
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(role: .secondaryText))
                .padding(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - The reading pane

    /// The continuous text (criterion 16): the paragraphs the Markdown rule produces, in order,
    /// set in the window's reading measure -- and each one's timestamp revealed on hover, with
    /// the link to that instant.
    ///
    /// The paragraphs come from `TranscriptsPaneModel.paragraphs(of:)`, which re-reads
    /// `TranscriptMarkdown`'s frozen render rather than inventing a second fusion rule.
    private func reading(_ document: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            readingHeader(document)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(TranscriptsPaneModel.paragraphs(of: document)) { paragraph in
                        paragraphView(paragraph, document: document)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
    }

    /// The way out, the title, and the same line of provenance a tile carries -- read off the tile
    /// derivation itself, so the header and the grid cannot end up disagreeing about the source,
    /// the day or the duration of one document.
    private func readingHeader(_ document: TranscriptDocument) -> some View {
        let tuile = TranscriptTile.tile(for: document, calendar: .current)
        return VStack(alignment: .leading, spacing: 6) {
            // The label is the section's own frozen title (`WindowSection.transcripts.title`), not
            // a word written here: going back is going back to the Transcripts section, and that
            // word already exists and is already checked.
            Button {
                model.closeReading()
            } label: {
                Label(WindowSection.transcripts.title, systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(role: .secondaryText))
            Text(document.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(tuile.source)
                Text("·")
                Text(tuile.date)
                Text("·")
                Text(tuile.duration)
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(role: .hairline))
                .frame(height: WindowLayout.hairlineWidth)
        }
    }

    /// One paragraph, with the timestamp gutter.
    ///
    /// **The gutter is always reserved, even when it is empty**: an instant that appeared by
    /// pushing the text aside would make the whole document jump under the pointer, one line at a
    /// time. Its width is `TranscriptsLayout.instantGutterWidth`.
    ///
    /// The instant is a **link and not a player**: an embedded player is out of scope, so the
    /// timestamp hands the address to the system's default handler
    /// (`TranscriptsPaneModel.link(to:in:)`).
    private func paragraphView(
        _ paragraph: TranscriptsPaneModel.Paragraph, document: TranscriptDocument
    ) -> some View {
        let lien = TranscriptsPaneModel.link(to: paragraph.start, in: document)
        let instant = TranscriptsPaneModel.instant(paragraph.start)
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if hovered == paragraph.id {
                    if let lien {
                        Link(destination: lien) {
                            Label(instant, systemImage: "play.circle")
                        }
                    } else {
                        Text(instant)
                    }
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(role: .secondaryText))
            .frame(width: TranscriptsLayout.instantGutterWidth, alignment: .trailing)
            .padding(.top, 3)

            Text(paragraph.text)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
                // The same line spacing as the History transcript: this is the one text in the
                // window that is read rather than glanced at.
                .lineSpacing(HistoryLayout.transcriptLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: HistoryLayout.transcriptMeasure, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // `onHover` on the row and not on the text: the pointer is over the paragraph when it is
        // anywhere on that line of the page, gutter included.
        .onHover { dedans in
            if dedans {
                hovered = paragraph.id
            } else if hovered == paragraph.id {
                hovered = nil
            }
        }
    }

    // MARK: - The problem bar

    /// The Finder refused. Shown and dismissable, the shape `HistoryPaneView` gives its own
    /// failures -- a refusal held in a property nothing draws is a refusal that did not happen as
    /// far as Louis is concerned.
    private func problemBar(_ problem: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(problem).lineLimit(3)
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissProblem() }
                .buttonStyle(.plain)
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(Color(role: .secondaryText))
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }
}
