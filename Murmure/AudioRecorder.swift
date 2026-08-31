import AVFoundation
import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "audio")

/// Taps the default input device and streams buffers into a `WavWriter`.
///
/// Threading: `AVAudioEngine` delivers tap buffers on its own audio thread while `start()` and
/// `stop()` run on the main thread. Everything shared between the two lives in `TapSink`, behind
/// a lock — including the writer itself, so it can never be released while a buffer is being
/// written (`WavWriter` has no `close()`; finalisation happens when it is deallocated).
///
/// The recording keeps the hardware format (48 kHz float on this Mac). WhisperKit resamples to
/// 16 kHz mono when it loads the file, so no conversion happens here.
final class AudioRecorder {
    enum Failure: LocalizedError {
        case alreadyRecording
        case noInputDevice
        case microphoneAccessDenied
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "A recording is already in progress."
            case .noInputDevice: "No audio input device is available."
            case .microphoneAccessDenied:
                "Microphone access is denied. Grant it in System Settings > Privacy & Security."
            case .writeFailed(let error):
                "Could not write the recording: \(error.localizedDescription)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var sink: TapSink?

    /// Why the last `stop()` returned `nil`. Read after `stop()`; reset by the next `start()`.
    private(set) var lastFailure: Failure?

    func start() throws {
        guard sink == nil else { throw Failure.alreadyRecording }
        // Denied access does not fail the engine: it delivers a stream of zeros, which would be
        // certified as a valid (silent) recording. Fail loudly instead (spec §9).
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw Failure.microphoneAccessDenied
        case .notDetermined:
            // The system prompt is raised by the engine itself on first input access; this only
            // makes sure it is raised even if that ever changes. The first recording may be
            // silent until the user answers.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default: break
        }
        lastFailure = nil

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // `installTap` raises an uncatchable exception on a zero-channel format, which is what an
        // unplugged input device yields.
        guard format.channelCount > 0, format.sampleRate > 0 else { throw Failure.noInputDevice }

        let directory = try Storage.appSupportDirectory(subfolder: "recordings")
        let sink = TapSink(writer: try WavWriter(directory: directory, format: format))
        // The block captures the sink, never `self`: the engine retains the block, so capturing
        // `self` would be a cycle, and the sink must outlive the recorder if AVFoundation ever
        // calls back after `removeTap`.
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            sink.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = sink.finish()
            // Nothing was ever written to the path `WavWriter` reserved.
            try? FileManager.default.removeItem(at: sink.url)
            throw error
        }
        self.sink = sink
        logger.info("""
            recording started -- \(format.sampleRate, privacy: .public) Hz, \
            \(format.channelCount, privacy: .public) ch, \
            \(sink.url.lastPathComponent, privacy: .public)
            """)
    }

    /// Returns the finished file, or `nil` if there was no recording or a buffer failed to be
    /// written — in which case the file on disk is short and `lastFailure` says why.
    func stop() -> URL? {
        guard let sink else { return nil }
        self.sink = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // `removeTap` is not documented to wait for a callback already running. `finish()` takes
        // the sink's lock, which the tap block holds for the whole of `append`, so the writer is
        // released — and its file closed — only once no buffer is in flight.
        if let error = sink.finish() {
            lastFailure = .writeFailed(error)
            logger.error("recording failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        logger.info("recording stopped -- \(sink.url.lastPathComponent, privacy: .public)")
        return sink.url
    }
}

/// The state the audio thread and the main thread share: the writer, and the first write error.
///
/// `os_unfair_lock` rather than `NSLock` because it donates priority to the lock holder, so the
/// audio thread never waits behind a lower-priority main thread. It is held across the write,
/// which is I/O — but that I/O is the point of a progressive writer and already happens on this
/// thread; the lock only ever contends with `finish()`, once per recording.
private final class TapSink {
    let url: URL

    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var writer: WavWriter?
    private var failure: Error?

    init(writer: WavWriter) {
        self.writer = writer
        url = writer.url
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Audio thread. Records the first failure and stops writing; no logging, no allocation and
    /// no unbounded wait happen here beyond the write itself.
    func append(_ buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let writer, failure == nil else { return }
        do {
            try writer.append(buffer)
        } catch {
            failure = error
            // Hand the error off the audio thread so a two-minute dictation reports the problem
            // when it happens, not only when `stop()` is called. Runs once per recording.
            DispatchQueue.main.async {
                logger.error("write failed mid-recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Main thread. Releases the writer under the lock, then reports the first write error.
    func finish() -> Error? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        writer = nil
        return failure
    }
}
