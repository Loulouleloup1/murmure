import XCTest
@testable import MurmureCore

/// A level is one block of audio, and the tap is not asked how long a block should be.
final class BlockCutterTests: XCTestCase {
    /// The device this Mac actually runs: 48 kHz, 43 ms blocks.
    private static let framesPerBlock = Int((48_000 * WaveformLayout.blockDuration).rounded())

    private func collect(
        _ cutter: inout BlockCutter, buffers: [[Float]]
    ) -> [Float] {
        var levels: [Float] = []
        for buffer in buffers {
            cutter.accept(buffer) { levels.append($0) }
        }
        return levels
    }

    func testABufferShorterThanABlockCompletesNothingAndIsNotThrownAway() {
        // The case the old rounding rule got wrong in the direction that matters: it promoted any
        // buffer, however short, to a whole level. A device handing back 512 frames would have run
        // the waveform four times too fast, silently.
        var cutter = BlockCutter(framesPerBlock: Self.framesPerBlock)
        let short = [Float](repeating: 0.5, count: 512)

        let firstThree = collect(&cutter, buffers: [short, short, short])

        XCTAssertEqual(firstThree, [], "512 frames is a quarter of a block, not a level")
        XCTAssertEqual(cutter.pendingFrames, 1_536, "and the frames are carried, not dropped")
    }

    func testTheFramesCarriedAcrossBuffersMakeExactlyOneLevelPerBlock() {
        // 4 096-frame buffers against 2 064-frame blocks: 1.9845 blocks each, so the count must
        // come out as the floor of the running total and never as two per buffer.
        var cutter = BlockCutter(framesPerBlock: Self.framesPerBlock)
        let buffer = [Float](repeating: 0.5, count: 4_096)

        var perBuffer: [Int] = []
        for _ in 0..<200 {
            perBuffer.append(cutter.accept(buffer) { _ in })
        }

        let total = perBuffer.reduce(0, +)
        XCTAssertEqual(total, 200 * 4_096 / Self.framesPerBlock)
        XCTAssertEqual(Set(perBuffer), [1, 2], "most buffers hold two blocks, some hold one")
        XCTAssertEqual(perBuffer.filter { $0 == 1 }.count, 4, "about one buffer in 65")
    }

    func testALevelIsTheRootMeanSquareOfTheWholeBlockAndNotAnAverageOfHalves() {
        // The reason the carry is a sum of squares. Half a block at 0 and half at 1 has an RMS of
        // 0.707; averaging the two halves' RMS values would give 0.5.
        var cutter = BlockCutter(framesPerBlock: 100)
        var levels: [Float] = []

        cutter.accept([Float](repeating: 0, count: 50)) { levels.append($0) }
        cutter.accept([Float](repeating: 1, count: 50)) { levels.append($0) }

        XCTAssertEqual(levels.count, 1)
        XCTAssertEqual(levels[0], (0.5 as Float).squareRoot(), accuracy: 1e-6)
    }

    func testItAgreesWithMeasuringTheWholeStreamInOneGo() {
        // Whatever the buffers are chopped into, the levels must be the levels of the stream.
        let stream = (0..<1_000).map { Float(sin(Double($0) * 0.05)) }
        var whole = BlockCutter(framesPerBlock: 100)
        var chopped = BlockCutter(framesPerBlock: 100)

        let fromWhole = collect(&whole, buffers: [stream])
        var offset = 0
        var buffers: [[Float]] = []
        for size in [7, 3, 199, 1, 64, 300, 11, 415] where offset < stream.count {
            let end = min(stream.count, offset + size)
            buffers.append(Array(stream[offset..<end]))
            offset = end
        }
        let fromChopped = collect(&chopped, buffers: buffers)

        XCTAssertEqual(fromWhole.count, 10)
        XCTAssertEqual(fromChopped.count, fromWhole.count)
        for (whole, chopped) in zip(fromWhole, fromChopped) {
            XCTAssertEqual(whole, chopped, accuracy: 1e-5)
        }
    }

    func testABlockNeverEndsUpZeroFramesLongHoweverBadTheSampleRate() {
        // `framesPerBlock` divides and terminates a loop; zero would do neither.
        for framesPerBlock in [0, -1, Int.min] {
            var cutter = BlockCutter(framesPerBlock: framesPerBlock)
            XCTAssertEqual(cutter.framesPerBlock, 1, "at \(framesPerBlock)")

            // A negative block size would make the slice length negative, and an
            // `UnsafeBufferPointer` of negative length is a read off the end of the tap buffer.
            var levels: [Float] = []
            cutter.accept([0.25, 0.25]) { levels.append($0) }
            XCTAssertEqual(levels, [0.25, 0.25], "at \(framesPerBlock)")
        }
    }

    func testAnEmptyBufferIsNotAnEventAtAll() {
        var cutter = BlockCutter(framesPerBlock: 10)
        var calls = 0
        XCTAssertEqual(cutter.accept([Float]()) { _ in calls += 1 }, 0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(cutter.pendingFrames, 0)
    }
}
