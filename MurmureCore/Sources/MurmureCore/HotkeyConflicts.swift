import Foundation

/// Identifies one hotkey binding Murmure can register: the one global toggle, one mode's own
/// shortcut (`Mode.hotkey`, named by the mode's `key` -- its file name, stable across a rename of
/// `name` alone, `Mode.key`'s own doc comment), or Escape (`.cancel`).
///
/// Shared between the pure rules below and `HotkeyManager`'s registration table (`Murmure`, which
/// has no test bundle) so the two never need a translation layer between them: `HotkeyManager`
/// imports `MurmureCore` and keys its table on this type directly. `.cancel` never reaches
/// ``HotkeyAssignments/resolve(toggle:modes:)`` -- it is `EscapeCancelKey`'s own, entirely
/// separate `HotkeyManager` instance that registers under it, one binding for the life of that
/// object, never in the same table the toggle and the modes share.
public enum HotkeyBindingID: Hashable, Sendable {
    case toggle
    case mode(String)
    case cancel
}

/// One binding that lost a clash over the same `KeyCombo`, and the one sentence to show for it.
public struct HotkeyConflict: Equatable, Sendable {
    public let winner: HotkeyBindingID
    public let loser: HotkeyBindingID
    public let message: String

    public init(winner: HotkeyBindingID, loser: HotkeyBindingID, message: String) {
        self.winner = winner
        self.loser = loser
        self.message = message
    }
}

/// One mode hotkey that never entered the contest at all, because `HotkeyRecording` would have
/// refused it if it had ever been captured through the recorder -- see
/// ``HotkeyAssignments/resolve(toggle:modes:)``'s own note on why this check exists.
public struct HotkeyRefusal: Equatable, Sendable {
    public let id: HotkeyBindingID
    public let message: String

    public init(id: HotkeyBindingID, message: String) {
        self.id = id
        self.message = message
    }
}

/// One binding actually registered: which id, and the combo it won.
public struct HotkeyAssignment: Equatable, Sendable {
    public let id: HotkeyBindingID
    public let combo: KeyCombo

    public init(id: HotkeyBindingID, combo: KeyCombo) {
        self.id = id
        self.combo = combo
    }
}

/// Which hotkey binding gets registered when two or more want the same `KeyCombo`, and which
/// mode hotkeys never get to compete for one at all.
///
/// The toggle and every mode's own shortcut all live in the one Carbon/`NSEvent` namespace
/// `HotkeyManager` registers into (there is exactly one process-wide table of physical key
/// combinations), so two bindings picking the same combo is not a mode-file mistake the way a bad
/// regex is -- it is two VALID bindings that cannot both be pressed by the same key. Something has
/// to lose, deterministically, so the same two modes always resolve the same way rather than by
/// whichever loaded first.
public enum HotkeyAssignments {
    /// One mode's own shortcut, named enough to write a sentence about. `name` is what a user
    /// reads ("Prompt"); `key` is what `HotkeyBindingID.mode(_:)` and `HotkeyManager` register
    /// under (`Mode.key`). `hotkey` is `nil` for a mode that declares none -- carried all the way
    /// into ``resolve(toggle:modes:)`` rather than filtered by the caller, so a mode with no
    /// shortcut skipping the contest entirely is a rule this function is tested on, not one every
    /// caller has to remember to apply first.
    public struct ModeHotkey: Sendable {
        public let key: String
        public let name: String
        public let hotkey: KeyCombo?

        public init(key: String, name: String, hotkey: KeyCombo?) {
            self.key = key
            self.name = name
            self.hotkey = hotkey
        }
    }

    /// Every mode's own shortcut, with `draft` standing in for whichever one is being edited --
    /// what an editor calls before ``resolve(toggle:modes:)`` so a combo just typed, not yet
    /// saved, is checked against the same live table a real save would resolve.
    ///
    /// **Matches by `previousKey`, never by `name`.** `key` is the mode's file name and the one
    /// `HotkeyBindingID.mode(_:)` registers under (`ModeHotkey`'s own doc comment); `name` is a
    /// display string the editor lets you change on the very same draft this substitutes. Matching
    /// on `name` instead would silently miss a mode mid-rename -- its entry in `modes` still
    /// carries the OLD name, the draft already carries the new one -- and this function would then
    /// append a second, duplicate candidate for the same mode rather than replacing its one entry,
    /// which is exactly the case a caller reaches this for.
    ///
    /// `previousKey` is `nil` for a mode not yet on disk (`ModeDraft.previousKey`'s own doc
    /// comment) and non-nil but absent from `modes` for one whose key just changed in the same
    /// edit -- both fall through to the same append, because either way there is no existing entry
    /// left to replace.
    public static func substituting(
        _ draft: ModeHotkey, in modes: [ModeHotkey], previousKey: String?
    ) -> [ModeHotkey] {
        var result = modes
        if let previousKey, let index = result.firstIndex(where: { $0.key == previousKey }) {
            result[index] = draft
        } else {
            result.append(draft)
        }
        return result
    }

    /// The name a conflict sentence uses for the toggle -- it is not a mode, so it has no
    /// `Mode.name` of its own to borrow.
    private static let toggleName = "the dictation shortcut"

    /// Resolves every mode's own shortcut against the toggle and against each other.
    ///
    /// **A mode hotkey `HotkeyRecording` would refuse is excluded before it can contend for
    /// anything, and reported as a refusal, not a conflict.** The toggle can only ever be set by
    /// rebinding it through `HotkeyRecording.evaluate`/`HotkeyRecordingSession` (General's own
    /// recorder), so it is always already legal by construction. A mode's `hotkey` now has a
    /// recorder of its own too (`ModesPaneModel`'s Shortcut row, over the same
    /// `HotkeyRecordingSession`), so most of the time it is equally already legal -- but a
    /// hand-edited mode JSON file bypasses that recorder entirely, the same way it always could,
    /// and this check is what stands between a bare Escape written there and `HotkeyManager`
    /// taking it as a permanent global chord, fighting `CancelHotkey` for the same key on every
    /// single recording; `HotkeyRecording.wouldRefuse(_:)` is the same rule both Record buttons
    /// already enforce, asked here of a value that may never have gone through either one.
    ///
    /// **The toggle always wins a genuine clash.** It is the one shortcut every dictation depends
    /// on and the one Louis did not just set by editing a mode file, so a clash between it and a
    /// (legal) mode hotkey is resolved in favour of the binding that predates the mode picking a
    /// combo already spoken for.
    ///
    /// **Among modes alone, the one whose `key` sorts alphabetically LAST wins.** There is no
    /// principled reason to prefer one Louis-configured mode's shortcut over another's, so the
    /// tie-break only has to be a fixed, repeatable answer -- not a fair one -- and highest-key
    /// rather than lowest is arbitrary in exactly the same way and no more.
    public static func resolve(
        toggle: KeyCombo, modes: [ModeHotkey]
    ) -> (bindings: [HotkeyAssignment], conflicts: [HotkeyConflict], refusals: [HotkeyRefusal]) {
        struct Candidate { let id: HotkeyBindingID; let name: String; let combo: KeyCombo }

        var candidates = [Candidate(id: .toggle, name: toggleName, combo: toggle)]
        var refusals: [HotkeyRefusal] = []
        for mode in modes {
            // No shortcut declared -- nothing to resolve, and not a refusal: silence, the same as
            // any other mode nobody has ever tried to bind a key to.
            guard let hotkey = mode.hotkey else { continue }
            if let refusalMessage = HotkeyRecording.wouldRefuse(hotkey) {
                refusals.append(HotkeyRefusal(id: .mode(mode.key), message: "\(mode.name): \(refusalMessage)"))
                continue
            }
            candidates.append(Candidate(id: .mode(mode.key), name: mode.name, combo: hotkey))
        }

        // `KeyCombo` is `Equatable` but not `Hashable` -- nothing else needs it to be, and the
        // handful of bindings a real install ever has makes an O(n^2) grouping cheaper than
        // adding a conformance for this one caller.
        var groups: [[Candidate]] = []
        for candidate in candidates {
            if let index = groups.firstIndex(where: { $0[0].combo == candidate.combo }) {
                groups[index].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        var bindings: [HotkeyAssignment] = []
        var conflicts: [HotkeyConflict] = []
        for group in groups {
            guard group.count > 1 else {
                bindings.append(HotkeyAssignment(id: group[0].id, combo: group[0].combo))
                continue
            }
            let winner =
                group.first { $0.id == .toggle }
                ?? group.max { modeKey(of: $0.id) < modeKey(of: $1.id) }!
            bindings.append(HotkeyAssignment(id: winner.id, combo: winner.combo))

            let label = comboLabel(winner.combo)
            for loser in group where loser.id != winner.id {
                conflicts.append(HotkeyConflict(
                    winner: winner.id, loser: loser.id,
                    message: "\(loser.name) and \(winner.name) both use \(label) "
                        + "— only one can win; \(winner.name) keeps it."))
            }
        }
        return (bindings, conflicts, refusals)
    }

    /// The mode key a binding id names, or `""` for `.toggle` -- only ever asked of a group that
    /// has already had its one `.toggle` candidate (if any) taken by the `first { }` above, so a
    /// group `max(by:)` sees mode ids exclusively and this default is never actually compared.
    private static func modeKey(of id: HotkeyBindingID) -> String {
        if case .mode(let key) = id { return key }
        return ""
    }

    /// The combo as one string, e.g. "⌥P" -- `KeyCombo.keycaps`'s own chips, concatenated rather
    /// than drawn, because a conflict sentence is plain text and not a SwiftUI row.
    private static func comboLabel(_ combo: KeyCombo) -> String {
        combo.keycaps.map(\.label).joined()
    }
}
