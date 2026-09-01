import Foundation

/// The last few bar heights, oldest first — the waveform's history.
///
/// A ring of a **fixed** number of slots, full from the moment it is created. That is not an
/// optimisation, it is the shape of the interface: a surface draws one bar per slot it can fit, so
/// a history that filled up over the first second would draw a row that grew as it filled, and the
/// waveform would spread out across the card for the first frames of every dictation. Lot 3
/// forbids exactly that — the amplitude moves bar heights, never the extent of the drawing.
///
/// It is therefore prefilled with the meter's floor: a new dictation opens on a flat line of
/// bars, which is what the waveform shows for silence anyway.
public struct LevelHistory: Equatable {
    /// How many levels are kept: **the most bars any surface can draw, plus the look-back the read
    /// head needs behind them** — `WaveformLayout.maximumBars + WaveformLayout.scrollHeadroom`.
    ///
    /// The second term arrived with `WaveformScroll` and is not decoration: the head is parked a
    /// margin behind the newest level so it never reads one that has not landed, and the oldest bar
    /// of a full row reads a whole row further back than that. Without the headroom those bars fall
    /// off the end of the ring and clamp — a few bars at the left of the card holding still and
    /// jumping by two, which is the staircase this all exists to remove. `WaveformLayout` owns both
    /// numbers and the cap that keeps the margin inside the headroom.
    ///
    /// It used to be six, and six was a *display* choice: the only surface then was a 32 pt notch
    /// wing, and six bars at the fixed pitch came to exactly 32 pt. Once the notch grew into a
    /// 400 pt card that number stopped meaning anything about either surface — it made the card
    /// draw a small clump of bars in the middle of an empty row. The count a surface draws is now
    /// its own, from its own width (`WaveformLayout.barCount(inWidth:)`), and what is kept here is
    /// simply enough for the widest of them; a narrower surface takes the newest slice it can show.
    ///
    /// Nothing asserted about six changes with it, because nothing ever asserted six: the tests
    /// below pin that the ring is full from creation, drops the oldest and reads out oldest-first,
    /// and they do it at capacities of their own.
    public static let defaultCapacity = WaveformLayout.maximumBars + WaveformLayout.scrollHeadroom

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
