import AppKit
import MurmureCore
import SwiftUI

/// The window: a sidebar of six sections, and a pane that is empty in this task.
///
/// This is the frame, not the contents. T5 fills History, T6 Vocabulary, T7 Modes, T8 the three
/// machinery sections and T9 every empty and broken state — so what is worth getting right here is
/// what all five of them will copy: where the colours come from, where the measurements come from,
/// and what a section header is.
struct MainWindowView: View {
    @ObservedObject var controller: WindowController
    /// History's own state, built once in `MurmureApp` because it owns a database connection and
    /// a search query that must survive the window being closed and reopened.
    @ObservedObject var history: HistoryPaneModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // Q-NB6, in one line and one place: dark only, as lot 3 shipped. The notch got away with
        // it because black on a black cutout is theme-free; a window does not, so this is a real
        // deferral rather than a solved problem. Light mode is a second table in `WindowPalette`
        // and the removal of this modifier -- which is exactly why no call site below writes a
        // colour of its own.
        .preferredColorScheme(.dark)
        // The sidebar's selection, drawn in Murmure's accent rather than the system's. Without
        // this the selected row is whatever blue Louis has set in System Settings, which would be
        // a second accent in a window whose whole point is that it has one (D4).
        .tint(Color(role: .selection))
        .background(WindowAccessor { controller.adopt($0) })
    }

    // MARK: - The sidebar

    /// Two lists with a gap between them, and that gap is the entire grouping device (§2.2): no
    /// divider rules, no headings. A `Section` with no header draws exactly that.
    ///
    /// It only comes out in §2.2's order because the two halves are contiguous runs of
    /// `WindowSection.allCases`, which `WindowSectionTests` pins.
    private var sidebar: some View {
        List(selection: selection) {
            Section { rows(in: .material) }
            Section { rows(in: .machinery) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(role: .sidebarBackground))
        .navigationSplitViewColumnWidth(
            min: WindowLayout.sidebarWidth.minimum,
            ideal: WindowLayout.sidebarWidth.ideal,
            max: WindowLayout.sidebarWidth.maximum)
    }

    /// A `List`'s selection is optional because a list can have nothing selected. This window
    /// cannot: there is no "no section" state, and clicking the empty space below the rows must
    /// not empty the pane. A nil write is therefore dropped rather than stored.
    private var selection: Binding<WindowSection?> {
        Binding(
            get: { controller.section },
            set: { if let chosen = $0 { controller.section = chosen } })
    }

    private func rows(in group: WindowSectionGroup) -> some View {
        ForEach(WindowSection.sections(in: group), id: \.self) { section in
            row(section).tag(section)
        }
    }

    private func row(_ section: WindowSection) -> some View {
        let palette = WindowPalette.tile(for: section.group)
        let isSelected = controller.section == section
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: WindowLayout.chipCornerRadius, style: .continuous)
                .fill(Color(role: palette.tile))
                .frame(
                    width: WindowLayout.sidebarTileSize, height: WindowLayout.sidebarTileSize)
                .overlay {
                    Image(systemName: section.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(role: palette.glyph))
                }
            // Two type sizes and a muted/bright contrast, no display size anywhere (design notes
            // §2) -- the same rule `NotchCardView` already follows. Rounded, for the same reason it
            // does: it is the family the rest of Murmure is drawn in.
            Text(section.title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(role: isSelected ? .primaryText : .secondaryText))
        }
        .padding(.vertical, 2)
    }

    // MARK: - The pane and its header

    private var detail: some View {
        VStack(spacing: 0) {
            header
            pane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(role: .paneBackground))
    }

    /// §2.3: a contextual toolbar, not a titlebar, and **no page title** — the installed app
    /// deleted heading prose entirely (design notes §1.4) and each pane opens straight onto its
    /// content. The left of the row is empty in this task; History and Models put their search
    /// field there.
    ///
    /// On the right, the deliberate departure. The installed app pins the *microphone selector*
    /// into every non-list header, which the notes call "a good call: the one setting you might
    /// need mid-session never requires navigation". Murmure's equivalent is not the microphone —
    /// it is **the active mode**, because that is the setting that decides whether what he is about
    /// to say goes through an LLM. `AppState.activeMode` already exists for exactly that reason,
    /// and the menu already carries the same line.
    ///
    /// The glyph is derived rather than stored, which is D14 one lot early: a microphone for a
    /// transcribe-only mode, sparkles for a refining one.
    private var header: some View {
        HStack(spacing: 6) {
            // For a LIST section the header *is* the search field (design notes §1.4), which is
            // why History has no other place to put one and no page title above it. Models gets
            // the same slot in T8.
            if controller.section == .history {
                HistorySearchField(text: $history.searchField)
            }
            Spacer(minLength: 0)
            Image(systemName: appState.activeMode.llm.enabled ? "sparkles" : "mic.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(appState.activeMode.name)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .foregroundStyle(Color(role: .secondaryText))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: WindowLayout.headerHeight,
               maxHeight: WindowLayout.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(role: .hairline))
                .frame(height: WindowLayout.hairlineWidth)
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch controller.section {
        case .history: HistoryPaneView(model: history)
        case .vocabulary: pasteProbePane
        // Empty on purpose. This task builds the frame; the contents are T5 through T9, and an
        // invented placeholder in each of five panes is five things to delete.
        default: Color.clear
        }
    }

    // MARK: - The temporary field, and why it exists

    @State private var pasteProbe = ""

    /// **TEMPORARY — delete in T6.** This is the only text field in the window, and it is here
    /// solely so that T1's third eye-gate can be run at all: whether ⌘V works in a text field in
    /// an accessory app on macOS 26 is a fact about our own app that cannot be settled without
    /// launching it (plan §8), and it is what Q-B1 and D2 exist to answer.
    ///
    /// It sits in Vocabulary because that is where T6 puts the real input row, so deleting this is
    /// a deletion and not a hole. Nothing reads `pasteProbe`; it is a place for the paste to land.
    private var pasteProbePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Temporary — T1's ⌘V gate. Paste here, then delete this pane in T6.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(role: .secondaryText))
            TextField("⌘V", text: $pasteProbe)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .rounded))
                .frame(maxWidth: 420)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The one honest way to get hold of the `NSWindow` SwiftUI built.
///
/// Matching on `NSApp.windows` by identifier or by title was the alternative and it is guesswork:
/// what SwiftUI writes into `NSWindow.identifier` for a `Window(id:)` scene is undocumented and has
/// no compile error when it changes. A view that is *inside* the window can simply ask which
/// window it is in.
///
/// `view.window` is nil while `makeNSView` runs — the view has not been added to a hierarchy yet —
/// so the question is asked one turn later, and again on every update, because `adopt(_:)` is
/// idempotent per window.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in
            if let window = view.window { onWindow(window) }
        }
    }
}
