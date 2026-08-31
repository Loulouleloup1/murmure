import AVFoundation
import XCTest
@testable import MurmureCore

final class WavWriterTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A ramp so that every frame carries a distinct value: a writer emitting zeros, or one
    /// splicing in a sparse hole, cannot pass.
    private func makeRamp(format: AVAudioFormat, frames: AVAudioFrameCount, from start: Int)
        -> AVAudioPCMBuffer
    {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] =
                    Float(start + frame) * 1e-4 + Float(channel)
            }
        }
        return buffer
    }

    /// The RIFF and `data` size fields as they are on disk right now, the offset the `data`
    /// payload starts at, and the file's physical length.
    private func headerSizes(of url: URL) throws
        -> (riff: UInt32, data: UInt32, payloadStart: Int, onDisk: Int)
    {
        let bytes = try Data(contentsOf: url)
        func uint32(at offset: Int) -> UInt32 {
            let b = [UInt8](bytes[offset..<offset + 4])
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = bytes[offset..<offset + 4]
            let size = uint32(at: offset + 4)
            if id == Data("data".utf8) {
                return (uint32(at: 4), size, offset + 8, bytes.count)
            }
            offset += 8 + Int(size) + Int(size % 2)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// `read(into:)` stops at an internal boundary (4096-frame chunks here), so loop until the
    /// file's whole length has been consumed.
    private func readAllSamples(from url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let total = Int(file.length)
        var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
        while channels[0].count < total {
            try file.read(into: chunk)
            guard chunk.frameLength > 0 else { break }
            for channel in channels.indices {
                channels[channel].append(contentsOf: UnsafeBufferPointer(
                    start: chunk.floatChannelData![channel],
                    count: Int(chunk.frameLength)
                ))
            }
        }
        return channels
    }

    func testHeaderSizesCountOnlyTheFramesThisWriterWrote() throws {
        let dir = try makeTemporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try WavWriter(directory: dir, format: format)
        try writer.append(makeRamp(format: format, frames: 1_000, from: 0))

        // A tail this writer never wrote (stands in for a future AVFoundation preallocation).
        let handle = try FileHandle(forUpdating: writer.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 40_000))
        try handle.close()

        // A zero-frame append re-patches the header without adding any audio.
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        empty.frameLength = 0
        try writer.append(empty)

        let sizes = try headerSizes(of: writer.url)
        XCTAssertEqual(sizes.data, 1_000 * 4) // not the 44 000 bytes now on disk
        XCTAssertEqual(Int(sizes.riff), sizes.payloadStart + Int(sizes.data) - 8)
        XCTAssertEqual(try AVAudioFile(forReading: writer.url).length, 1_000)
    }

    func testTheDataChunkIsFoundByWalkingChunksNotBySearchingForTheBytes() throws {
        // A filler chunk whose payload happens to contain "data" -- a blind `range(of:)` would
        // return the payload's offset, not the real chunk's.
        var wav = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)
        let filler = Data("xxdata size here".utf8) // 16 bytes, contains "data" at index 2
        wav += Data("FLLR".utf8)
            + withUnsafeBytes(of: UInt32(filler.count).littleEndian) { Data($0) } + filler
        let dataChunkStart = wav.count
        wav += Data("data".utf8) + Data([0, 0, 0, 0])

        let dir = try makeTemporaryDirectory()
        let url = dir.appendingPathComponent("filler.wav")
        try wav.write(to: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let offset = try WavWriter.locateDataChunkSizeOffset(handle: handle)
        XCTAssertEqual(offset, UInt64(dataChunkStart + 4))
    }

    func testTwoSecondsOfSilenceProduceAReadableTwoSecondWav() throws {
        let dir = try makeTemporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try WavWriter(directory: dir, format: format)

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000 // 1 s of silence
        try writer.append(buffer)
        try writer.append(buffer)

        let readBack = try AVAudioFile(forReading: writer.url)
        XCTAssertEqual(readBack.length, 32_000)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 16_000, accuracy: 1)
    }

    func testSamplesAreReadableValueByValueWhileTheWriterIsStillOpen() throws {
        let dir = try makeTemporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try WavWriter(directory: dir, format: format)

        try writer.append(makeRamp(format: format, frames: 800, from: 0))
        try writer.append(makeRamp(format: format, frames: 800, from: 800))

        // Read back mid-stream: the writer is deliberately still open.
        let channels = try readAllSamples(from: writer.url)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].count, 1_600)
        for frame in 0..<1_600 {
            XCTAssertEqual(
                channels[0][frame], Float(frame) * 1e-4,
                "sample mismatch at frame \(frame)"
            )
        }

        let sizes = try headerSizes(of: writer.url)
        XCTAssertEqual(sizes.data, 1_600 * 4) // 4 bytes per mono float32 frame
        XCTAssertEqual(sizes.payloadStart + Int(sizes.data), sizes.onDisk) // byte-exact
        XCTAssertEqual(Int(sizes.riff), sizes.payloadStart + Int(sizes.data) - 8)
    }

    func testStereo48kHzIsWrittenWithByteExactSizesAndInterleavedChannels() throws {
        let dir = try makeTemporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let writer = try WavWriter(directory: dir, format: format)

        try writer.append(makeRamp(format: format, frames: 1_200, from: 0))
        try writer.append(makeRamp(format: format, frames: 1_200, from: 1_200))

        let readBack = try AVAudioFile(forReading: writer.url)
        XCTAssertEqual(readBack.length, 2_400)
        XCTAssertEqual(readBack.fileFormat.channelCount, 2)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 48_000, accuracy: 1)

        let channels = try readAllSamples(from: writer.url)
        XCTAssertEqual(channels.count, 2)
        for frame in 0..<2_400 {
            XCTAssertEqual(channels[0][frame], Float(frame) * 1e-4, "left at \(frame)")
            XCTAssertEqual(channels[1][frame], Float(frame) * 1e-4 + 1, "right at \(frame)")
        }

        let sizes = try headerSizes(of: writer.url)
        XCTAssertEqual(sizes.data, 2_400 * 8) // 8 bytes per stereo float32 frame
        XCTAssertEqual(sizes.payloadStart + Int(sizes.data), sizes.onDisk) // byte-exact
        XCTAssertEqual(Int(sizes.riff), sizes.payloadStart + Int(sizes.data) - 8)
    }

    func testTwoWritersCreatedBackToBackDoNotShareAFileOrTruncateEachOther() throws {
        let dir = try makeTemporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

        let first = try WavWriter(directory: dir, format: format)
        let second = try WavWriter(directory: dir, format: format)
        XCTAssertNotEqual(first.url, second.url)

        // Interleave the appends the way a stop-then-immediate-restart would.
        try first.append(makeRamp(format: format, frames: 16_000, from: 0))
        try second.append(makeRamp(format: format, frames: 800, from: 0))
        try first.append(makeRamp(format: format, frames: 800, from: 16_000))

        let firstBack = try readAllSamples(from: first.url)
        let secondBack = try readAllSamples(from: second.url)
        XCTAssertEqual(firstBack[0].count, 16_800)
        XCTAssertEqual(secondBack[0].count, 800)
        for frame in 0..<16_800 {
            XCTAssertEqual(firstBack[0][frame], Float(frame) * 1e-4, "first writer at \(frame)")
        }
        for frame in 0..<800 {
            XCTAssertEqual(secondBack[0][frame], Float(frame) * 1e-4, "second writer at \(frame)")
        }
        XCTAssertEqual(try headerSizes(of: first.url).data, 16_800 * 4)
        XCTAssertEqual(try headerSizes(of: second.url).data, 800 * 4)
    }

    func testTheSameInstantNeverTruncatesTheRecordingAlreadyInProgress() throws {
        let dir = try makeTemporaryDirectory()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        // Force the residual case the timestamp alone cannot rule out: the very same instant.
        let instant = Date()
        let first = try WavWriter(directory: dir, format: format, now: instant)
        try first.append(makeRamp(format: format, frames: 800, from: 0))
        let second = try WavWriter(directory: dir, format: format, now: instant)
        try second.append(makeRamp(format: format, frames: 400, from: 0))

        XCTAssertNotEqual(first.url, second.url)
        // The recording already in progress must be untouched, not truncated.
        XCTAssertEqual(try headerSizes(of: first.url).data, 800 * 4)
        XCTAssertEqual(try readAllSamples(from: first.url)[0].count, 800)
        XCTAssertEqual(try readAllSamples(from: second.url)[0].count, 400)
    }
}
