import Foundation

/// The last few bar heights, oldest first — one wing's worth of waveform.
///
/// A ring of a **fixed** number of slots, full from the moment it is created. That is not an
/// optimisation, it is the shape of the interface: the wings draw one bar per slot, so a history
/// that filled up over the first half-second would draw a wing that grew with it, and the notch
/// would widen for the first six frames of every dictation. Lot 3 forbids exactly that — the
/// amplitude moves bar heights, never the width of the shape, because every phase after the
/// recording is read against a shape that is supposed never to have moved.
///
/// It is therefore prefilled with the meter's floor: a new dictation opens on a flat line of
/// bars, which is what the waveform shows for silence anyway.
public struct LevelHistory: Equatable {
    /// Bars per wing. Six of them, mirrored across the two wings, makes twelve — close to the
    /// ~9 centred bars measured on Superwhisper's Mini pill (design notes §3), which is the only
    /// reference that exists for a recording waveform.
    public static let defaultCapacity = 6

    public let capacity: Int
    /// The ring itself, always exactly `capacity` long. Written in place, never appended to.
    private var storage: [Float]
    /// The slot holding the oldest value, i.e. the next one to be overwritten.
    private var oldest: Int

    public init(
        capacity: Int = LevelHistory.defaultCapacity,
        filledWith value: Float = AudioLevelMeter.floorHeight
    ) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: value, count: self.capacity)
        oldest = 0
    }

    /// Records one bar height, dropping the oldest.
    ///
    /// Writes into the slot the oldest value occupies and moves on, so the count is invariant and
    /// nothing is ever allocated here: this runs once per audio block, and on a caller that must
    /// not allocate.
    public mutating func append(_ value: Float) {
        storage[oldest] = value
        oldest = (oldest + 1) % capacity
    }

    /// The heights, oldest first. The wing draws them in this order; the other wing reverses them.
    public var values: [Float] {
        Array(storage[oldest...] + storage[..<oldest])
    }
}
