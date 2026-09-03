import Foundation

/// The mode picked by hand in the menu, remembered across launches -- rule 1 of spec §5, the one
/// `ModeSelection.resolve` lets nothing overrule.
///
/// `nil` is not "no answer", it is the answer "automatic": the remaining rules decide, which is
/// exactly what lot 2 shipped and what keeps `Voice` the default until a choice is made. Choosing
/// a mode and choosing to go back to automatic are therefore both real choices, and both persist.
///
/// `UserDefaults` is the whole store: this is which item is ticked in a menu, not the modes
/// themselves. Losing it costs one click, so it never justifies a file in the modes folder.
///
/// `defaults` is injected for the same reason `ModeStore`'s directory is: a test that reached
/// `.standard` would write into the real application's domain.
public struct ModePreference {
    /// Never renamed lightly -- the name IS the migration. A rename silently forgets the choice
    /// of everyone who had made one, and the app would look like it lost their mode.
    private static let storageKey = "selectedModeKey"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The chosen mode key, or nil for "automatic".
    ///
    /// An empty string reads back as nil rather than as a key: it can only come from a hand-run
    /// `defaults write`, and `ModeSelection` would report it as a mode that does not exist --
    /// a menu warning about a file nobody ever named.
    public var selectedKey: String? {
        get {
            guard let stored = defaults.string(forKey: Self.storageKey), !stored.isEmpty else {
                return nil
            }
            return stored
        }
        // `nonmutating` because the storage is the `UserDefaults` object, not this struct: the
        // menu holds a value type and still has to be able to write through it.
        nonmutating set {
            // Automatic is stored as the ABSENCE of an entry, not as "": a domain with nothing in
            // it and a domain holding an empty string then mean the same thing, so the two cannot
            // drift apart.
            guard let newValue else {
                defaults.removeObject(forKey: Self.storageKey)
                return
            }
            defaults.set(newValue, forKey: Self.storageKey)
        }
    }

    /// The selection after a mode's key was renamed: it follows the rename, and only when it named
    /// the key that moved.
    ///
    /// The key is the file name, so renaming it in the editor leaves a stored selection pointing
    /// at nothing. `ModeSelection.resolve` already survives that — it falls through to the
    /// remaining rules and reports `unknownManualSelection`, which `ModeSelectionTests` pins — so
    /// nothing breaks. What happens instead is worse to *watch*: Louis renames a key and the mode
    /// he had ticked silently becomes another one, with the explanation in a log.
    ///
    /// Here rather than in the editor because the condition is about this value and not about the
    /// rename: the caller would have to read the selection to decide, which is asking it to know
    /// what this type is for. Pure and static for the same reason `ModeSelection.resolve` is —
    /// the caller holds an in-memory copy of the selection as well as the stored one, and a
    /// function that wrote through `defaults` would update one of the two and leave the other
    /// saying yesterday's key.
    public static func selection(
        _ current: String?, following rename: (from: String, to: String)
    ) -> String? {
        current == rename.from ? rename.to : current
    }
}
