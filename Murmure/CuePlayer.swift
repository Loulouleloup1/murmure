import AVFoundation
import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "cue")

/// Plays the two feedback cues, as fast as CoreAudio can be made to play anything.
///
/// # Why an engine and not `NSSound`
///
/// The point of the start cue is that Louis knows the microphone is live WITHOUT looking, and
/// starts speaking on it. So the cost of the call matters twice over: once as the delay before he
/// hears it, and once as time the main actor spends not drawing the notch. Measured on this Mac,
/// eight fires each, time for the call to return:
///
/// - `NSSound(named:).play()`                                   median **21.8 ms**, max 28.8 ms
/// - `AVAudioPlayer.play()`, after `prepareToPlay()`            median **9.2 ms**,  max 27.6 ms
/// - `scheduleBuffer` on a player node of an already-running engine
///                                                              median **0.06 ms**, max 0.11 ms
///
/// The two former numbers are not just latency: they are the main thread BLOCKED, at the exact
/// instant `NotchController` is being asked to put a window on screen. The engine route pays that
/// cost once, at launch (`engine.start()` measured at 14.3 ms), and never again.
///
/// The remaining delay is the output device's own, and no API can undo it: the default output on
/// this Mac reports 60 frames of device latency + 48 of safety offset + 512 of buffer + 690 of
/// stream latency = 1 310 frames = **27.3 ms** at 48 kHz. So hearing the cue costs about 27 ms
/// after the recording goes live, of which Murmure's own share is under a tenth of a millisecond.
///
/// # Why the engine is left running
///
/// A stopped engine costs 14.3 ms to restart, which would land on the first cue of every burst of
/// dictation -- the one that matters most. It also lets the speaker amplifier power down between
/// dictations, so the cue would arrive behind the amp's own wake-up click.
///
/// The price is paid and it is priced: an engine rendering silence measured **0.064 s of CPU over
/// 20 s, 0.32 % of one core** against a 0.000 s control, continuously, for as long as Murmure is
/// running. That is the cost of never making Louis wonder whether the first press of the morning
/// worked, in an app that already keeps a multi-gigabyte CoreML model resident after the first
/// dictation.
///
/// # The output device
///
/// Nothing here sets a volume. The cue files are authored quiet (peak -13 dBFS, the quiet half of
/// what Apple ships in `/System/Library/Sounds`) and the system volume and output device decide
/// the rest -- which is what Louis expects when he plugs headphones in.
///
/// Plugging them in is also the one thing that can break an engine. **Documented, not measured**:
/// Apple states that the engine stops itself when the hardware configuration changes and posts
/// `AVAudioEngineConfigurationChange`, leaving the graph's connections to be remade. Reproducing
/// it needs the default output device to actually change under a running Murmure, which is not
/// something a build-time harness may do to the machine it is running on, so this is the one claim
/// in this file taken on the documentation's word rather than off a measurement.
///
/// The guard below is written anyway, because the two sides are not symmetric: observing a
/// notification that never fires costs nothing, while not observing one that does costs a cue that
/// stops firing for the rest of the session, on the day Louis put headphones on, with nothing said
/// anywhere. `engine.isRunning` is re-checked in `play(_:)` for the same reason.
///
/// Only ever touched from the main actor: `DictationController` builds it and drives it from
/// inside its `Task { @MainActor in ... }`, and the notification below is delivered on the main
/// queue for the same reason.
final class CuePlayer: CuePlaying {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// Decoded at init and kept. Nothing is read from disk at press time -- that is the whole
    /// point of the numbers in the note above.
    private var buffers: [FeedbackCue: AVAudioPCMBuffer] = [:]
    private var observer: (any NSObjectProtocol)?

    /// Where a cue that could not be loaded is reported.
    ///
    /// Required, with no default, for the reason `PasteInserter.onClipboardOutcome` is: a missing
    /// or unreadable cue file makes Murmure silently lose the one signal this whole file exists to
    /// provide, and a `return` in a `guard` is not a report. The build that ships it would pass
    /// every test.
    private let report: (String) -> Void

    init(report: @escaping (String) -> Void) {
        self.report = report

        engine.attach(node)
        var format: AVAudioFormat?
        for cue in FeedbackCue.allCases {
            guard let url = Bundle.main.url(forResource: Self.resourceName(for: cue),
                                            withExtension: "wav") else {
                report("cue \(Self.resourceName(for: cue)).wav is missing from the app bundle")
                continue
            }
            do {
                let file = try AVAudioFile(forReading: url)
                // The node is connected with ONE format, so a second cue in another one would
                // crash the whole app the first time it fired -- `scheduleBuffer` traps on the
                // mismatch, and an Objective-C exception cannot be caught here. Both files come out
                // of `scripts/generate_cues.py` at 48 kHz mono, so this can only fire on a cue
                // added by hand; dropping it costs one sound, where letting it through costs
                // Murmure. Measured by hitting the trap in a harness, not reasoned about.
                guard format == nil || file.processingFormat == format else {
                    report("""
                        cue \(url.lastPathComponent) is \(file.processingFormat), not \
                        \(format!) like the others -- skipped
                        """)
                    continue
                }
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                ) else {
                    report("cue \(url.lastPathComponent) could not be buffered")
                    continue
                }
                try file.read(into: buffer)
                buffers[cue] = buffer
                format = file.processingFormat
            } catch {
                report("""
                    cue \(url.lastPathComponent) could not be read: \
                    \(error.localizedDescription)
                    """)
            }
        }

        // Nothing to play and therefore nothing to connect: an engine wired to no buffers would
        // hold the output device open for the life of the app in exchange for silence.
        guard let format else { return }
        connectAndStart(format: format)

        // `.main` rather than a background queue, so the restart happens on the actor everything
        // else here runs on.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            logger.info("output configuration changed -- rebuilding the cue engine")
            connectAndStart(format: format)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The cue file's basename in the bundle.
    ///
    /// A `switch` rather than a raw value on `FeedbackCue`, so `MurmureCore` -- which knows
    /// nothing about app bundles -- does not end up owning a filename. It is exhaustive, so a cue
    /// added there fails to compile here until it has a sound, rather than shipping mute.
    private static func resourceName(for cue: FeedbackCue) -> String {
        switch cue {
        case .recordingStarted: "cue-recording-started"
        case .textInserted: "cue-text-inserted"
        }
    }

    /// Wire the player node to the mixer and get the graph running. Called at init and again
    /// every time AVFoundation tears the graph down under us.
    ///
    /// Connecting with the CUE's format, not the mixer's: the files are mono and the output device
    /// is stereo, and `AVAudioPlayerNode.scheduleBuffer` raises an uncatchable Objective-C
    /// exception -- `_outputFormat.channelCount == buffer.format.channelCount` -- when the two
    /// disagree. Measured by hitting it: a `format: nil` connection resolved to the device's
    /// 2-channel format and killed the harness on the first fire. The mixer does the conversion.
    private func connectAndStart(format: AVAudioFormat) {
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            node.play()
        } catch {
            report("the cue engine could not start: \(error.localizedDescription)")
        }
    }

    /// Queue a cue. Returns in well under a millisecond; the sound follows about 27 ms later,
    /// which is the output device's latency and not ours.
    ///
    /// `.interrupts` because the two cues are 90 ms and 40 ms apart in a pipeline that takes
    /// seconds, so an overlap means something has gone wrong and the newer cue is the true one.
    func play(_ cue: FeedbackCue) {
        guard let buffer = buffers[cue] else { return }
        // A graph that is not running swallows the buffer in silence. This is the second half of
        // the configuration-change guard above: it covers a start that failed at launch too.
        guard engine.isRunning else { return }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
}
