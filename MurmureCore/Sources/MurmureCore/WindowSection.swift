import Foundation

/// The two halves of the sidebar, and the only grouping device the window has (plan §2.2).
///
/// Design notes §2 calls it "a genuinely useful, cheap device for Murmure, whose settings surface
/// will be smaller": **no divider rules, no headings, one extra gap, and an icon-colour split
/// where coloured = the user's own material and neutral = the app's machinery.** Seven items, one
/// break. This enum is the split; `WindowPalette` is the colour it is drawn in.
public enum WindowSectionGroup: String, CaseIterable, Sendable {
    /// Home, History, Modes, Vocabulary. What Louis put there — his overview, his dictations, his
    /// modes, his words.
    case material
    /// Models, General, Advanced. What the app needs to run — a downloaded model, a hotkey, a
    /// paste behaviour. None of it is his content, and none of it is coloured.
    case machinery
}

/// The seven sections of the application window's sidebar, in the order they are drawn.
///
/// **Declaration order IS the sidebar order** (plan §2.2), which is why `allCases` is used
/// directly by the view rather than a hand-kept list beside it: a section inserted in the wrong
/// place moves in the window at the same moment it moves here, and a test pins the order it must
/// come out in. Spec §6's own order — `General · Modes · Models · Vocabulary · History · Advanced`
/// — is wrong twice (plan §4.1): it buries the only section with a daily reason to be opened, and
/// lists it as a peer of "Advanced" as though the archive of everything he has dictated were a
/// preference.
///
/// Every case answers all three questions — its title, its glyph and which half it belongs to —
/// through switches written **without a `default`**. That is the guarantee `NotchCard`'s own
/// `symbolName(for:)` makes for phases, and it is here for the same reason: a section added later
/// must fail to compile until someone has decided what it is called, what it looks like and
/// whether it is the user's material or the app's machinery. A `default` would hand it a blank
/// square and the wrong half, silently.
///
/// The raw value is what `WindowRestoration` files the selected section under, so **it is a
/// storage name and never renamed lightly** — the same rule `ModePreference.storageKey` carries.
/// A rename forgets which section the window was left on; unlike a mode key, that costs one click,
/// which is why the codec resolves an unknown name to History rather than refusing to open.
public enum WindowSection: String, CaseIterable, Sendable {
    /// First, and the section the window opens on when nothing usable is stored.
    case home
    /// The reason the window exists (plan D3). The other five are opened when something changes;
    /// this one is opened when a dictation has to be found again.
    case history
    case modes
    case vocabulary
    case models
    case general
    case advanced

    /// The section the window opens on when nothing usable is stored, and the section an
    /// unrecognised stored name resolves to.
    ///
    /// Not `.general`, which is what a settings window would default to: six of the seven sections
    /// are settings and Home is the overview.
    public static let fallback: WindowSection = .home

    /// The word in the sidebar.
    ///
    /// English. It was the language `MurmureCore` already spoke -- `StatusPanelText` says
    /// "Recording", "Transcribing", "Inserted 1 character" -- while the menu was French in places
    /// and English in others. Louis settled it on 2026-09-01: English throughout, and the mix has
    /// to disappear rather than move, which is why the menu's own words are now in `MenuText` with
    /// a test that walks all of them.
    public var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .modes: "Modes"
        case .vocabulary: "Vocabulary"
        case .models: "Models"
        case .general: "General"
        case .advanced: "Advanced"
        }
    }

    /// The SF Symbol on the row's tile.
    ///
    /// All seven are chosen from the set macOS 14 ships, and all seven differ: the glyph is what
    /// the row is found by once the window is a habit, and two sections wearing one symbol would
    /// make the tile decoration rather than an address.
    ///
    /// `modes` gets the wand rather than `sparkles`: `sparkles` is the notch's `refining` glyph
    /// (`NotchCard.symbolName(for:)`), and a settings section wearing the phase's own symbol would
    /// make the two mean each other.
    public var symbolName: String {
        switch self {
        case .home: "chart.bar.xaxis"
        case .history: "clock.arrow.circlepath"
        case .modes: "wand.and.stars"
        case .vocabulary: "character.book.closed"
        case .models: "cube.box"
        case .general: "gearshape"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// Whether the row is drawn as the user's own material or as the app's machinery.
    public var group: WindowSectionGroup {
        switch self {
        case .home, .history, .modes, .vocabulary: .material
        case .models, .general, .advanced: .machinery
        }
    }

    /// The sections of one half, in sidebar order.
    ///
    /// What the sidebar iterates. Two calls to this, one per group, is how the window draws "one
    /// extra gap and no heading": the gap is the space between two lists, so there is no rule to
    /// draw and no title to write. It only renders as §2.2 because the two halves are **contiguous
    /// runs of `allCases`** — material first, machinery second — which is a property of the
    /// declaration order above and is therefore pinned by a test rather than assumed here.
    public static func sections(in group: WindowSectionGroup) -> [WindowSection] {
        allCases.filter { $0.group == group }
    }
}
