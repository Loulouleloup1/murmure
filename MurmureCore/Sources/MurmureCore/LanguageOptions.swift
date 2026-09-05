import Foundation

/// One dictation language a mode can be set to: a code and the name shown for it, after
/// ``LanguageOptions/dedupe(_:)`` has collapsed the engine's own naming table to one row per code.
public struct LanguageOption: Equatable, Sendable {
    public let code: String
    public let name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// Collapses a name -> code table (WhisperKit's `Constants.languages`, read by the app target that
/// links WhisperKit -- `MurmureCore` does not, `Mode.swift`'s own doc comment) into one row per
/// code.
///
/// **Why this exists.** The table names more languages than it has codes for: dialect and spelling
/// variants share a code -- `"chinese"`/`"mandarin"` both map to `zh`, `"romanian"`/`"moldavian"`/
/// `"moldovan"` all map to `ro`, eleven such codes in WhisperKit 1.1.0's table (112 names, 100
/// distinct codes; pinned in `LanguageOptionsTests` against a literal snapshot of the real table
/// rather than a synthetic toy dictionary). Before this existed, `ModesPaneView`'s Language picker
/// built one `PickerOption` per NAME and tagged it by code -- so `ForEach` held twelve redundant
/// rows across those eleven shared codes, which is undefined behaviour for `ForEach` and,
/// observed, twelve redundant rows in the menu (review, lot 3a, item 3).
public enum LanguageOptions {
    /// One entry per distinct code, its display name taken from `Locale`, not the table's own raw
    /// name.
    ///
    /// **Why not the table's name.** WhisperKit's own table has no ordering that means anything --
    /// keeping whichever of a shared code's names sorts first alphabetically produced "Castilian"
    /// with no "Spanish" anywhere in the list, "Moldavian" with no "Romanian", plus names nobody
    /// picking a dictation language would recognise on sight: "Letzeburgesch", "Panjabi" (review,
    /// lot 3a leftovers, item 3). `Locale(identifier: "en").localizedString(forLanguageCode:)`
    /// gives the name English speakers actually use for a given ISO code, which is what a picker
    /// choosing a language should show.
    ///
    /// **Fixed to `en`, not `Locale.current`.** The list has to read the same regardless of which
    /// language macOS itself is set to -- a picker whose wording depends on system settings would
    /// be a second, silent variable in "why does this say something different on my machine" -- and
    /// `LanguageOptionsTests` pins literal names (`"es" -> "Spanish"`) that only hold for a fixed
    /// locale.
    ///
    /// **The fallback.** A code `Locale` itself does not resolve to a name (untested against the
    /// real WhisperKit table, which `Locale` resolves in full, but real regardless: an ISO code
    /// `Locale` has simply never heard of) falls back to the table's own first-alphabetical name
    /// for that code, so a code is never silently dropped for lack of a localized name -- the same
    /// tie-break the dedupe used everywhere before this fallback existed.
    ///
    /// The returned list is sorted by the resulting display name, not by the raw table name that
    /// produced it -- the two can differ, and it is the name actually shown that has to determine
    /// where an entry lands in the menu.
    public static func dedupe(_ languages: [String: String]) -> [LanguageOption] {
        let englishLocale = Locale(identifier: "en")
        var seenCodes = Set<String>()
        var options: [LanguageOption] = []
        for (rawName, code) in languages.sorted(by: { $0.key < $1.key })
        where !seenCodes.contains(code) {
            seenCodes.insert(code)
            let displayName = englishLocale.localizedString(forLanguageCode: code) ?? rawName
            options.append(LanguageOption(code: code, name: displayName))
        }
        return options.sorted { $0.name < $1.name }
    }
}
