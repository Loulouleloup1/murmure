import AppKit

/// A restorable copy of everything a pasteboard was holding, so a paste-based insertion can
/// borrow the clipboard and hand it back.
///
/// The clipboard is the user's data, not ours: a naive `string(forType:)` / `setString`
/// round-trip preserves plain text and destroys everything else -- copy a file, dictate, and
/// the file is gone from the clipboard. So every ITEM is captured, and within each item every
/// TYPE, in the order the pasteboard reported them, with the bytes behind each.
///
/// What is faithfully preserved: the number and order of items, the types on each item and
/// their order, and the bytes of every representation the pasteboard can materialise --
/// plain text, RTF, HTML, file URLs, TIFF/PNG, and any private application type.
///
/// What is NOT, and cannot be:
/// - **Lazy representations whose provider declines.** `data(forType:)` asks the owning app
///   to materialise a promised type now; if it returns nil the representation is dropped and
///   named in ``droppedTypes`` rather than lost silently.
/// - **File promises** (`com.apple.pasteboard.promised-file-*`). The bytes we copy are the
///   promise's metadata, not the file; on restore the promise points at us and we cannot
///   fulfil it, so a promised drag-out would fail. Restoring the metadata is still strictly
///   better than dropping the item, because the other representations on the same item
///   (usually a real file URL or plain text) come back intact.
/// - **Ownership.** The restored pasteboard is owned by this process, not by the app that
///   originally copied. Anything the original owner would have supplied on demand after the
///   fact is already resolved to bytes by then.
public struct PasteboardSnapshot: Sendable {
    /// One representation of one item: a type and the bytes behind it.
    private struct Representation: Sendable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    /// The outcome of a restore, because "did not restore" has two very different meanings.
    public enum RestoreOutcome: Equatable, Sendable {
        /// The pasteboard now holds the captured contents again.
        case restored
        /// Someone else wrote to the pasteboard after we did, so the captured contents are
        /// stale and were NOT written -- overwriting a fresh copy would be the same data loss
        /// this type exists to prevent.
        case declinedPasteboardChanged
        /// The pasteboard rejected the write. The captured contents are gone from the
        /// pasteboard; the caller should say so loudly.
        case writeFailed
    }

    /// Items in pasteboard order; each item's representations in the order the item listed them.
    private let items: [[Representation]]

    /// Types present on the pasteboard whose bytes could not be read, and which a restore will
    /// therefore not bring back. Empty in every ordinary case; non-empty means the caller
    /// should log that the clipboard was preserved only in part.
    public let droppedTypes: [NSPasteboard.PasteboardType]

    private init(items: [[Representation]], droppedTypes: [NSPasteboard.PasteboardType]) {
        self.items = items
        self.droppedTypes = droppedTypes
    }

    public static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        var dropped: [NSPasteboard.PasteboardType] = []
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> Representation? in
                guard let data = item.data(forType: type) else {
                    dropped.append(type)
                    return nil
                }
                return Representation(type: type, data: data)
            }
        }
        return PasteboardSnapshot(items: items, droppedTypes: dropped)
    }

    /// Restores unconditionally. Use ``restore(to:ifChangeCountIs:)`` after writing to the
    /// pasteboard yourself, so a copy the user made in the meantime is not clobbered.
    @discardableResult
    public func restore(to pasteboard: NSPasteboard = .general) -> RestoreOutcome {
        restore(to: pasteboard, ifChangeCountIs: pasteboard.changeCount)
    }

    /// Restores only if the pasteboard's generation counter still matches `expected`.
    ///
    /// `changeCount` is bumped by `clearContents()`, which every copy performs before writing
    /// (a cross-process write without it is refused), so a mismatch means someone -- the user
    /// pressing ⌘C, another app -- replaced the contents after `expected` was taken. Their
    /// data is newer than ours and wins.
    @discardableResult
    public func restore(
        to pasteboard: NSPasteboard = .general, ifChangeCountIs expected: Int
    ) -> RestoreOutcome {
        guard pasteboard.changeCount == expected else { return .declinedPasteboardChanged }
        pasteboard.clearContents()

        let restorable = items.filter { !$0.isEmpty }
        guard !restorable.isEmpty else { return .restored }

        var writeFailed = false
        let rebuilt = restorable.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in representations {
                if !item.setData(representation.data, forType: representation.type) {
                    writeFailed = true
                }
            }
            return item
        }
        // A fresh `NSPasteboardItem` is required: an item obtained from a pasteboard belongs to
        // it and cannot be written to another one.
        return pasteboard.writeObjects(rebuilt) && !writeFailed ? .restored : .writeFailed
    }
}
