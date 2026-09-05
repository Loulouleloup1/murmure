import AppKit
import MurmureCore
import SwiftUI

/// The window: a sidebar of six sections, and the pane each of them opens.
///
/// This is the frame; the contents are the six pane views. What it was worth getting right here is
/// what all six copy: where the colours come from, where the measurements come from, and what a
/// section header is.
///
/// **Five of the six pane models are handed in rather than built here**, and the reason is the same
/// for all five: each needs something only `MurmureApp` has — the archive the controller opened,
/// the `AppSettings` a dictation actually reads, or the controller itself, which the modes editor
/// has to be able to tell that the folder changed. Vocabulary is the one exception and says why
/// below.
struct MainWindowView: View {
    @ObservedObject var controller: WindowController
    /// History's own state, built once in `MurmureApp` because it owns a database connection and
    /// a search query that must survive the window being closed and reopened.
    @ObservedObject var history: HistoryPaneModel
    /// The modes editor. Built in `MurmureApp` because its `didChangeModes` has to reach
    /// `DictationController` and `AppState`, neither of which a `@StateObject` initialiser in a
    /// view can see: a property initialiser cannot read `self`, so an editor built here could only
    /// have been given the no-op default — an editor that saves a renamed mode and leaves the menu
    /// offering the old list, with nothing anywhere to say so.
    @ObservedObject var modes: ModesPaneModel
    /// The models table. Built in `MurmureApp` for the same reason: the language half of the table
    /// is derived from the modes `AppState` holds, and it is read on every appearance rather than
    /// captured once.
    @ObservedObject var models: ModelsPaneModel
    /// General and Advanced, built in `MurmureApp` so the settings they write are the ones a
    /// dictation reads and the archive they clear is the one the controller opened.
    @ObservedObject var general: GeneralPaneModel
    @ObservedObject var advanced: AdvancedPaneModel
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
        // `alignment: .top`, not the default `.center`. `NavigationSplitView`'s detail column can
        // offer this composite more height than `header` + `pane` together ask for, and without a
        // top anchor here that leftover is split above and below -- header included -- instead of
        // landing entirely below whatever the pane draws. Models was the one pane this was
        // reported on (design notes, Louis, 2026-09-04): its rows are few, and moving the anchor
        // here rather than adding a frame to its own root keeps the rule in one place instead of
        // one every future pane has to remember.
        //
        // Four of the other five panes already claim the full column on their own by construction,
        // read directly off their bodies: an explicit `.frame(maxWidth: .infinity, maxHeight:
        // .infinity)` on `HistoryPaneView`'s own `detail`, and a bare `ScrollView` as the entire
        // body of `GeneralPaneView`, `AdvancedPaneView` and `VocabularyPaneView` (the last has a
        // `ScrollView` too, but as the last child of a `VStack` rather than the body itself) --
        // none of those has anything below its flexible element for `.top` to newly expose.
        // `ModesPaneView.list`, though, has the same shape as Models' own root: its `cards`
        // `ScrollView` is followed by a `footer`, not trailing the stack. Why that shape does not
        // show the same margin there is not established by reading the code -- it may, or may not,
        // and that is exactly what makes this comment reasoning rather than a settled fact.
        //
        // **None of this is verified by any automated test** -- `Murmure/` has no test bundle, and
        // confirming a `NavigationSplitView` detail column's actual layout means opening the
        // window, which an agent may not do. Settled by Louis's own eye-gate: open all six
        // sections and confirm Models now sits flush under the header and none of the other five
        // moved.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    /// The glyph is `Mode.symbolName` (D14): the mode's own `symbol` when it picked one from the
    /// Modes editor's Icon grid, derived from whether it refines otherwise -- the same computed
    /// property the Modes list row reads too, so the active mode cannot wear one glyph there and
    /// another here. (The menu-bar mode list draws no icon at all today, in a file a concurrent
    /// lot owns -- a follow-up, not something this header can keep in step with yet.)
    private var header: some View {
        HStack(spacing: 6) {
            // For a LIST section the header *is* the search field (design notes §1.4), which is
            // why History has no other place to put one and no page title above it. History is the
            // only one: Models shipped without a search field on the argument `ModelsPaneView`
            // makes — a search over three rows is a control that can only ever hide two of them.
            if controller.section == .history {
                HistorySearchField(text: $history.searchField)
            }
            Spacer(minLength: 0)
            Image(systemName: appState.activeMode.symbolName)
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

    /// **No `default`, and that absence is the point of this switch.**
    ///
    /// It had one, and four of the six sections fell into it: Modes, Models, General and Advanced
    /// were fully built and fully tested, and clicking any of them showed `Color.clear`. Nothing
    /// protested — not the compiler, which had been given a case that matched everything, and not
    /// the test bundle, which covers `MurmureCore` and never the wiring.
    ///
    /// So this switch is written the way `WindowSection`'s own three are, for the reason its
    /// doc comment gives about them: a seventh section must **fail to compile** here until someone
    /// has decided what it shows. That is the only mechanism in this file that can catch a pane
    /// nobody connected, because there is no test that can.
    @ViewBuilder
    private var pane: some View {
        switch controller.section {
        case .history: HistoryPaneView(model: history)
        case .modes: ModesPaneView(model: modes)
        case .vocabulary: VocabularyPaneView(model: vocabulary)
        case .models: ModelsPaneView(model: models)
        case .general: GeneralPaneView(model: general)
        case .advanced: AdvancedPaneView(model: advanced)
        }
    }

    // MARK: - Vocabulary

    /// Built here rather than in `MurmureApp`: unlike History it owns no long-lived connection, so
    /// there is nothing to lose by scoping it to the view that shows it.
    @StateObject private var vocabulary = VocabularyPaneModel(fileURL: Self.vocabularyFileURL())

    /// `Storage.directory()` creates `Application Support/Murmure` before the store's first save
    /// needs it there (§5.4) -- the same reason `HistoryStore`'s path is resolved through it rather
    /// than the pure, non-creating `Storage.url()`. A creation failure falls back to the uncreated
    /// path rather than losing the location entirely: the model's own `problem` still catches the
    /// write failing against it, which is where a failure this unlikely belongs.
    private static func vocabularyFileURL() -> URL {
        (try? Storage.directory()).map { $0.appendingPathComponent("vocabulary.json") }
            ?? Storage.url().appendingPathComponent("vocabulary.json")
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
