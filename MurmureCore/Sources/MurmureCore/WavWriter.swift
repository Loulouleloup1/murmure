import AVFoundation
import Foundation

/// Writes PCM buffers to a .wav file as they arrive, so a crash never loses audio.
///
/// `AVAudioFile` only finalises the RIFF/`data` chunk sizes in the WAV header when the
/// underlying file is closed -- a file read back while the writer is still open (or after
/// a crash) reports zero frames even though the PCM samples are already on disk. To honour
/// "a crash never loses audio" (spec §4) the two 4-byte size fields are patched after every
/// append, so the file is a valid, readable WAV at all times.
public final class WavWriter {
    public let url: URL
    private let file: AVAudioFile
    private let headerHandle: FileHandle
    private let dataSizeOffset: UInt64

    public init(directory: URL, format: AVAudioFormat) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("rec-\(stamp).wav")
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        headerHandle = try FileHandle(forUpdating: url)
        dataSizeOffset = try Self.locateDataChunkSizeOffset(handle: headerHandle)
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
        try patchHeader()
    }

    private func patchHeader() throws {
        let fileSize = try headerHandle.seekToEnd()
        let dataByteCount = fileSize - dataSizeOffset - 4
        try headerHandle.seek(toOffset: 4)
        try headerHandle.write(contentsOf: Self.littleEndianUInt32(UInt32(fileSize - 8)))
        try headerHandle.seek(toOffset: dataSizeOffset)
        try headerHandle.write(contentsOf: Self.littleEndianUInt32(UInt32(dataByteCount)))
    }

    private static func littleEndianUInt32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func locateDataChunkSizeOffset(handle: FileHandle) throws -> UInt64 {
        try handle.seek(toOffset: 0)
        guard let header = try handle.readToEnd(), let range = header.range(of: Data("data".utf8)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UInt64(range.upperBound)
    }
}
