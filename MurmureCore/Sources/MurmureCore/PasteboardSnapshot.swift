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
///   named in ``droppedTypes`` rather than lost silently. Whether that costs the item a few of
///   its types or the item itself, ``RestoreOutcome/restoredPartially(lostItems:capturedItems:lostTypes:)``
///   says so rather than reporting a success.
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

    /// The outcome of a restore, because "did not restore" has several very different meanings.
    public enum RestoreOutcome: Equatable, Sendable {
        /// The pasteboard holds again everything it held before, at every level: every item, and
        /// on every item every type. Nothing was lost.
        case restored
        /// Something the user had copied is not coming back. Loss happens at two levels and both
        /// are reported here, because "the item is back" is no comfort to someone whose styled
        /// text came back as bare characters:
        /// - `lostItems` of the `capturedItems` items had NO representation whose bytes could be
        ///   read at capture time -- an unfulfilled promise with no eager representation behind
        ///   it -- so there was nothing to rebuild them from and they no longer exist.
        /// - `lostTypes` names every type, across all items, whose bytes could not be read. An
        ///   item that comes back amputated of some of its types contributes `lostItems: 0` and a
        ///   non-empty `lostTypes`.
        ///
        /// A non-zero `lostItems == capturedItems` means the whole pasteboard is gone: everything
        /// the user had copied was promise-only and is now unrecoverable. That case reads exactly
        /// like ``writeFailed`` to the user and the caller should treat it as loudly.
        case restoredPartially(
            lostItems: Int, capturedItems: Int, lostTypes: [NSPasteboard.PasteboardType]
        )
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

    // ========================================================================
    // Borrowing
    // ========================================================================

    /// A pasteboard that has been snapshotted, cleared and written to, held by the caller for as
    /// long as it needs the clipboard, and handed back with ``handBack()``.
    ///
    /// Deliberately opaque: it exists so that the sequence "capture, check nobody copied, clear,
    /// write" cannot be interleaved with anything, which is what a caller assembling those steps
    /// itself could always do wrong. Not `Sendable` -- it holds the `NSPasteboard`.
    public struct Borrowed {
        private let snapshot: PasteboardSnapshot
        private let pasteboard: NSPasteboard
        /// What `clearContents()` returned, i.e. the generation the hand-back is checked against.
        private let generation: Int

        fileprivate init(snapshot: PasteboardSnapshot, pasteboard: NSPasteboard, generation: Int) {
            self.snapshot = snapshot
            self.pasteboard = pasteboard
            self.generation = generation
        }

        /// The types the clipboard would not hand over, for the caller to log or show.
        ///
        /// Exposed here rather than left for the caller to read off a snapshot ON PURPOSE: the
        /// only safe moment to log them is AFTER the borrow. Logging them between the capture and
        /// the `clearContents()` -- which is where that warning used to live -- widens the very
        /// window ``PasteboardSnapshot/borrow(_:writing:)`` exists to close.
        public var droppedTypes: [NSPasteboard.PasteboardType] { snapshot.droppedTypes }

        /// Puts the user's clipboard back, unless someone copied in the meantime, in which case
        /// their newer contents win and are left alone.
        ///
        /// NOT `@discardableResult`: the returned outcome is the only account of what happened to
        /// the user's data, and a hand-back that quietly reports nothing is the failure mechanism
        /// with no consumer that this whole type exists to avoid.
        public func handBack() -> RestoreOutcome {
            snapshot.restore(to: pasteboard, ifChangeCountIs: generation)
        }
    }

    /// What ``PasteboardSnapshot/borrow(_:writing:)`` came back with.
    public enum Borrowing {
        /// The write landed and the pasteboard now holds it. ``Borrowed/handBack()`` gives the
        /// user their clipboard back.
        case borrowed(Borrowed)
        /// The pasteboard refused the write -- on a pasteboard that means a third party took
        /// ownership between our clear and our write, so their copy is on it and intact. The
        /// hand-back has already been performed here rather than left to the caller's error
        /// path, and `handedBack` says how it went (normally
        /// ``RestoreOutcome/declinedPasteboardChanged``: their copy is newer and wins).
        case writeRefused(handedBack: RestoreOutcome, droppedTypes: [NSPasteboard.PasteboardType])
    }

    /// How many snapshots ``borrow(_:writing:)`` will take when a third party keeps copying while
    /// it captures. Bounded, not "until it settles": a clipboard manager copying in a loop must
    /// not otherwise be able to hold a dictation hostage, and termination has to come from the
    /// bound rather than from an assumption about someone else's behaviour.
    ///
    /// Exhausting the bound is not free -- we then proceed with a snapshot we have not verified,
    /// which reopens the full window below for that one dictation. That is the trade: one lost
    /// clipboard in a case that needs two copies landing inside consecutive captures, against a
    /// dictation that never completes.
    private static let captureAttempts = 2

    /// Borrows `pasteboard`: snapshots it, clears it, hands it to `write`, and returns the handle
    /// that gives it back.
    ///
    /// The whole sequence -- read the counter, capture, verify nobody copied, clear, write --
    /// lives here rather than at the call site ON PURPOSE, and the difference is not stylistic.
    /// It used to live in the caller, and between its `capture()` and its `clearContents()` a
    /// third party's fresh copy was erased by our clear and then overwritten by the hand-back's
    /// pre-dictation contents, while the outcome still read `.restored`. A `capture` that merely
    /// also returned the generation it observed would make that mistake *detectable*, not
    /// *impossible*: the caller could still compare at the wrong moment, or slip a statement in
    /// between the comparison and the clear. Here there is nothing to slip into.
    public static func borrow(
        _ pasteboard: NSPasteboard = .general, writing write: (NSPasteboard) -> Bool
    ) -> Borrowing {
        var snapshot: PasteboardSnapshot
        var attempt = 0
        repeat {
            let beforeCapture = pasteboard.changeCount
            snapshot = capture(from: pasteboard)
            attempt += 1
            // A mismatch is always a third party and never us: `capture()` only reads, so it
            // cannot bump the counter, not even when it makes another process materialise a
            // promise (asserted by a test, because it is a premise about AppKit, not about us).
            // So: re-capture, never abandon. Abandoning would punish the user for an event that
            // is not theirs, and keeping the stale snapshot is worse still -- the clear below has
            // by then destroyed the copy the stale snapshot would be written over.
            if pasteboard.changeCount == beforeCapture { break }
        } while attempt < captureAttempts

        // RESIDUAL RACE, stated rather than closed. The gap that loses data is capture() ->
        // clearContents(): a third party copying in it has its copy erased by our clear and then
        // overwritten by the hand-back's pre-dictation contents, while the outcome still reads
        // `.restored` -- nothing anywhere says their copy existed. Hence the guard above.
        // What that gap costs, measured on this machine on a private `NSPasteboard(name:)`:
        //   capture(), trivial clipboard, FIRST call in the process .  0.6-1.3 ms
        //   capture(), trivial clipboard, warm ......................  10-20 us
        //   capture(), rich eager clipboard (5 types, 1 MB png) .....  97 us
        //   capture(), one 1 MB lazy representation to resolve ......  3.1 ms
        // Two of those lines matter and they are both the ordinary case here. Lazy
        // representations are what Word, Pages, Excel and Figma publish, and resolving one is a
        // round trip to another process. And the FIRST call is not a benchmarking artefact to be
        // amortised away: Murmure is an `LSUIElement` that dictates in bursts, so the cold path is
        // the path a dictation actually takes -- the warm 10-20 us figure describes a loop nobody
        // runs. Milliseconds are reachable by a clipboard manager polling `changeCount` (Maccy,
        // Paste, Raycast) or by a scripted `pbcopy`, which is why this is guarded rather than
        // written off as "too short to hit".
        // What remains after the guard is the read of `changeCount` and `clearContents()` itself:
        // two adjacent statements, under 1 us + 24-90 us, almost entirely the IPC to the
        // pasteboard server. No client-side guard removes it -- a third party whose clear the
        // server orders just before ours is still overwritten unseen, because `clearContents()`
        // returns the generation AFTER theirs and our own guard therefore passes. `NSPasteboard`
        // exposes no atomic clear-and-write. So the guard buys one to two orders of magnitude on
        // the cold trivial path, two to three on a rich one, and genuinely nothing warm on a
        // trivial clipboard, where the window it closes is already the smaller of the two.
        // The other gap, clearContents() -> the write, is not a loss at all: the counter is
        // already theirs, our write is refused (`setString` returns false), their copy stands, the
        // hand-back declines and the caller is told. Measured cross-process.
        let generation = pasteboard.clearContents()
        guard write(pasteboard) else {
            return .writeRefused(
                handedBack: snapshot.restore(to: pasteboard, ifChangeCountIs: generation),
                droppedTypes: snapshot.droppedTypes
            )
        }
        return .borrowed(
            Borrowed(snapshot: snapshot, pasteboard: pasteboard, generation: generation)
        )
    }

    // ========================================================================
    // Restoring
    // ========================================================================

    /// Restores unconditionally. Use ``restore(to:ifChangeCountIs:)`` after writing to the
    /// pasteboard yourself, so a copy the user made in the meantime is not clobbered.
    public func restore(to pasteboard: NSPasteboard = .general) -> RestoreOutcome {
        restore(to: pasteboard, ifChangeCountIs: pasteboard.changeCount)
    }

    /// Restores only if the pasteboard's generation counter still matches `expected`.
    ///
    /// `changeCount` is bumped by `clearContents()`, which every copy performs before writing
    /// (a cross-process write without it is refused), so a mismatch means someone -- the user
    /// pressing ⌘C, another app -- replaced the contents after `expected` was taken. Their
    /// data is newer than ours and wins.
    public func restore(
        to pasteboard: NSPasteboard = .general, ifChangeCountIs expected: Int
    ) -> RestoreOutcome {
        guard pasteboard.changeCount == expected else { return .declinedPasteboardChanged }
        pasteboard.clearContents()

        // An item every one of whose types was unreadable at capture time (an unfulfilled
        // promise with no eager representation behind it) has nothing to rebuild from: an empty
        // `NSPasteboardItem` carries no data and would only add a blank item. It is dropped --
        // and that is real data loss, so it is COUNTED and reported. Returning `.restored` here
        // told the caller the clipboard was safe while the user's item had just been destroyed.
        let restorable = items.filter { !$0.isEmpty }
        let lost = items.count - restorable.count
        // Types that could not be read are the same loss one level down: an item that comes back
        // stripped of its RTF is not a restored item, and `.restored` must not say it is.
        let successOutcome: RestoreOutcome =
            lost == 0 && droppedTypes.isEmpty
                ? .restored
                : .restoredPartially(
                    lostItems: lost, capturedItems: items.count, lostTypes: droppedTypes
                )
        // Nothing to write back: either the pasteboard was genuinely empty (`.restored`) or every
        // item was unrestorable, in which case the pasteboard is now empty and must say so.
        guard !restorable.isEmpty else { return successOutcome }

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
        return pasteboard.writeObjects(rebuilt) && !writeFailed ? successOutcome : .writeFailed
    }
}
