import Foundation

/// A `UserDefaults` that keeps everything in memory and never reaches `cfprefsd`.
///
/// **This exists because the suite-per-test pattern cannot be made to work, and that was
/// measured rather than assumed.** Every suite that needed an isolated domain used
/// `UserDefaults(suiteName:)` and then, in `tearDown`, emptied it, called `synchronize()` as a
/// barrier, removed the suite and deleted `~/Library/Preferences/<suite>.plist` by path. A class
/// `tearDown` swept whatever was left. That is careful code and it still loses: `cfprefsd` owns
/// the domain, writes asynchronously, and flushes an empty plist back to disk **after** the test
/// process has deleted it. Measured on 2026-09-03: **31 leftover files**, all 42 bytes, all
/// `{}` — the data really was gone, the litter was not. Counting them immediately after a run
/// shows zero, which is how the cleanup came to look correct for so long; the count has to be
/// taken minutes later.
///
/// There is no ordering that wins, because the loser is not the test process — it is the daemon.
/// So the domain is removed from the picture entirely: nothing is registered, nothing is cached,
/// nothing is flushed, and there is no file to delete. A test using this needs no `tearDown` at
/// all.
///
/// **What this costs, stated plainly.** These tests no longer exercise a real `plist` round trip.
/// That is an acceptable trade here and not a silent one: every value the three settings types
/// store is a `String`, a `Bool` or an array of `Double`, all of them plist-native, so the
/// encoding was never the risk — the risk was two `AppSettings` values disagreeing about a stored
/// answer, and a shared instance of this class still proves exactly that.
///
/// **Isolation is the whole safety property, and it is asserted rather than trusted**
/// (`EphemeralDefaultsTests`). `super.init(suiteName: nil)` gives the standard search list, so an
/// accessor left unoverridden would fall through to `com.louiscourcier.Murmure` — the preferences
/// of the app Louis is running. Every accessor the production code and the tests actually use is
/// overridden below, writes can therefore never reach it, and a test walks each one to keep that
/// true.
final class EphemeralDefaults: UserDefaults {
    /// A reference so two instances can share one store — see ``reopened()``.
    private final class Store {
        var values: [String: Any] = [:]
    }

    private let store: Store

    /// `suiteName: nil` is the designated initialiser and the only one available; the search list
    /// it sets up is never consulted, because every override below answers from `store`.
    init() {
        store = Store()
        super.init(suiteName: nil)!
    }

    private init(sharing store: Store) {
        self.store = store
        super.init(suiteName: nil)!
    }

    /// A second `UserDefaults` object reading the same store.
    ///
    /// **This is what the suites' "remembered across launches" cases were really demonstrating.**
    /// They used to reopen the domain with a second `UserDefaults(suiteName:)` and read through
    /// it, which proves the answer lives in the defaults rather than being cached in the
    /// `ModePreference` / `WindowRestoration` / `AppSettings` value that wrote it. That property
    /// survives here intact.
    ///
    /// What does NOT survive is the process boundary: this models a second reader, not a relaunch,
    /// so nothing here exercises `plist` encoding. Stated rather than glossed — the trade is
    /// acceptable because every value these types store is a `String`, a `Bool` or an array of
    /// `Double`, all plist-native, so the encoding was never the thing that could go wrong.
    func reopened() -> EphemeralDefaults {
        EphemeralDefaults(sharing: store)
    }

    // MARK: - The primitives

    override func object(forKey key: String) -> Any? { store.values[key] }

    /// A nil value removes, which is `UserDefaults`' own behaviour and is relied on by the
    /// setters that clear by assigning nil.
    override func set(_ value: Any?, forKey key: String) {
        guard let value else { return removeObject(forKey: key) }
        store.values[key] = value
    }

    override func removeObject(forKey key: String) { store.values.removeValue(forKey: key) }

    // MARK: - The typed accessors

    /// Overridden **individually and not left to `object(forKey:)`**. Whether `UserDefaults`
    /// implements these in terms of the primitive is an undocumented detail of Foundation, and
    /// betting on it here would mean a miss reads the real application's preferences rather than
    /// this dictionary. Each one returns the same default the real class does for an absent key,
    /// which is what `AppSettings.bool(_:default:)` distinguishes from a stored `false`.
    override func string(forKey key: String) -> String? { store.values[key] as? String }

    override func bool(forKey key: String) -> Bool { store.values[key] as? Bool ?? false }

    override func array(forKey key: String) -> [Any]? { store.values[key] as? [Any] }

    override func integer(forKey key: String) -> Int { store.values[key] as? Int ?? 0 }

    override func double(forKey key: String) -> Double { store.values[key] as? Double ?? 0 }

    override func data(forKey key: String) -> Data? { store.values[key] as? Data }
}
