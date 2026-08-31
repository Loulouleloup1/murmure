import Foundation

/// A global hotkey: Carbon virtual key code + Carbon modifier mask.
///
/// The raw values are Carbon's, not AppKit's: `keyCode` is a `kVK_*` virtual key code and
/// `carbonModifiers` is an `optionKey` / `cmdKey` / `shiftKey` / `controlKey` mask, which is
/// what `RegisterEventHotKey` expects. They are stored as plain numbers so this type stays
/// free of the Carbon import and can be persisted in settings verbatim (spec §5).
public struct KeyCombo: Codable, Equatable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Option+Space -- Murmure's default dictation toggle.
    public static let defaultToggle = KeyCombo(keyCode: 49, carbonModifiers: 2048)
}
