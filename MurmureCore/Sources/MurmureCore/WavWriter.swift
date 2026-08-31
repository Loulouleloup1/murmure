import AVFoundation
import Foundation

/// Writes PCM buffers to a .wav file as they arrive, so a crash never loses audio.
///
/// `AVAudioFile` only finalises the RIFF/`data` chunk sizes in the WAV header when the
/// underlying file is closed -- a file read back while the writer is still open (or after
/// a crash) reports zero frames even though the PCM samples are already on disk. To honour
/// "a crash never loses audio" (spec §4) the two 4-byte size fields are patched after every
/// append, so the file is a valid, readable WAV after every append. Between `write(from:)`
/// and the patch the header lags the samples by one buffer.
///
/// The patched bytes are not `fsync`ed: they survive a crash of this process (they are in the
/// page cache and immediately visible to any reader, including after the process dies) but not
/// a power loss or kernel panic, which may lose the tail of the recording.
public final class WavWriter {
    public let url: URL
    private let file: AVAudioFile
    private let headerHandle: FileHandle
    private let dataSizeOffset: UInt64
    private let bytesPerFrame: UInt64

    public convenience init(directory: URL, format: AVAudioFormat) throws {
        try self.init(directory: directory, format: format, now: Date())
    }

    /// Injectable clock so tests can force an exact same-instant collision.
    init(directory: URL, format: AVAudioFormat, now: Date) throws {
        url = try Self.reserveURL(directory: directory, now: now)
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        // The on-disk format is always interleaved, so `mBytesPerFrame` covers every channel.
        bytesPerFrame = UInt64(file.fileFormat.streamDescription.pointee.mBytesPerFrame)
        headerHandle = try FileHandle(forUpdating: url)
        dataSizeOffset = try Self.locateDataChunkSizeOffset(handle: headerHandle)
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
        try patchHeader()
    }

    /// Sizes are derived from the frames this writer wrote, not from the file's length on disk,
    /// so a tail nobody wrote -- a future AVFoundation preallocation, or bytes appended by
    /// anything else -- is never certified as audio. It is not a defence against two writers
    /// sharing one file: AVFoundation then counts the resulting hole in `length` itself
    /// (measured), which is why `reserveURL` rules that case out instead.
    private func patchHeader() throws {
        let dataByteCount = UInt64(file.length) * bytesPerFrame
        let riffSize = dataSizeOffset + 4 + dataByteCount - 8
        try headerHandle.seek(toOffset: 4)
        try headerHandle.write(contentsOf: Self.littleEndianUInt32(riffSize))
        try headerHandle.seek(toOffset: dataSizeOffset)
        try headerHandle.write(contentsOf: Self.littleEndianUInt32(dataByteCount))
    }

    /// Claims a free path atomically, so no two writers can ever share a file.
    ///
    /// The millisecond-resolution timestamp keeps names sortable and readable, but it is not
    /// enough on its own: two writers created back to back land in the same millisecond
    /// (measured), which is exactly the stop-then-immediately-restart case. `O_EXCL` makes the
    /// claim atomic -- an already-claimed path is skipped, never opened and never truncated by
    /// `AVAudioFile(forWriting:)` -- and a taken name falls through to a `-2`, `-3`, ... suffix.
    private static func reserveURL(directory: URL, now: Date) throws -> URL {
        let stamp = timestamp(now)
        for attempt in 1...100 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let candidate = directory.appendingPathComponent("rec-\(stamp)\(suffix).wav")
            let descriptor = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor >= 0 {
                close(descriptor)
                return candidate
            }
            guard errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// A WAV size field is 32-bit; throw rather than trap once a recording exceeds 4 GiB.
    private static func littleEndianUInt32(_ value: UInt64) throws -> Data {
        guard let narrowed = UInt32(exactly: value) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return withUnsafeBytes(of: narrowed.littleEndian) { Data($0) }
    }

    /// Walks the RIFF chunk list rather than searching for the bytes `data`, which a filler
    /// chunk's payload could otherwise contain. Internal so the walk can be tested directly.
    static func locateDataChunkSizeOffset(handle: FileHandle) throws -> UInt64 {
        try handle.seek(toOffset: 0)
        guard let riff = try handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4) == Data("RIFF".utf8), riff.suffix(4) == Data("WAVE".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var offset: UInt64 = 12
        while true {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if header.prefix(4) == Data("data".utf8) {
                return offset + 4
            }
            let bytes = [UInt8](header)
            let size = UInt64(bytes[4]) | UInt64(bytes[5]) << 8
                | UInt64(bytes[6]) << 16 | UInt64(bytes[7]) << 24
            // Chunks are word-aligned: an odd size is followed by one pad byte.
            offset += 8 + size + (size % 2)
        }
    }
}
