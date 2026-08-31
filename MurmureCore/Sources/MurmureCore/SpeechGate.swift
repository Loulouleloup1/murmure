import Foundation

/// Decides whether a recording is worth transcribing at all.
///
/// This exists because Whisper fabricates text on near-silence, non-deterministically: the same
/// 3.1 s of room tone returned `¿Qué es lo que se llama?`, then nothing, then `¿Qué es la vida?`
/// across three runs of identical options. Nothing about the model's *output* distinguishes those
/// from a real dictation, so the only safe place to act is before it runs. Superwhisper -- the app
/// this clones -- ships `vad-v1.onnx`/`vad-v2.onnx` for the same reason; an energy gate is the
/// no-new-dependency version of that, and WhisperKit already ships the energy VAD that measures
/// the two numbers this type judges.
///
/// The measurement lives in the app target, which is the only one that links WhisperKit; the
/// decision lives here so the thresholds -- the only thing standing between a fabricated sentence
/// and Louis's editor -- are covered by tests. Nothing about the split is a shim: the app measures
/// seconds of voiced audio and seconds of audio, and this type judges those two numbers.
///
/// The thresholds are measured, not chosen. Over Louis's 1 482 real dictations
/// (`~/Documents/superwhisper/recordings/*/output.wav`, transcript in the sibling `meta.json`),
/// scoring each file by how many 100 ms frames have RMS above 0.005:
///
/// - the 1 437 files with a real transcript: **minimum 0.5 s** of voiced audio, median 21.3 s;
/// - the 40 files whose transcript is empty or a single character: 33 of them under 0.4 s;
/// - the room-tone recording that produced the hallucination above: **0.2 s**.
///
/// So 0.3 s sits between the quietest real dictation ever recorded (0.5 s, a 40 % margin) and the
/// hallucinating file (0.2 s), and rejects **0 of 1 437** real dictations. The bias is deliberate:
/// letting some room tone through costs a wrong paste that Whisper usually declines to produce,
/// while rejecting a real dictation loses something Louis actually said.
///
/// The 0.005 frame threshold is likewise from the corpus: raising it to WhisperKit's default 0.02
/// would false-reject 2.7 % of real dictations (39 of 1 437) because Louis's quiet recordings peak
/// below it, for only 7 more silent files rejected.
public enum SpeechGate {
    public enum Verdict {
        case speech
        /// Carries why, for the log only -- the caller returns "" either way.
        case silence(String)
    }

    /// Frame length in seconds, WhisperKit's `EnergyVAD` default. A voiced frame is 100 ms.
    /// Part of the calibrated rule, not a caller's choice: the corpus was scored at this
    /// resolution, so measuring at another one would measure something else.
    public static let frameLength: Float = 0.1

    /// RMS above which a 100 ms frame counts as voiced. See the type's note for the calibration.
    public static let energyThreshold: Float = 0.005

    /// Total voiced time a recording needs before it is worth transcribing.
    public static let minimumVoicedDuration: TimeInterval = 0.3

    /// Minimum length of the recording itself. The shortest real dictation in the 1 482-file
    /// corpus is 1.34 s, so 0.5 s is 2.7x under anything Louis has ever said; it is here to make
    /// a brushed hotkey (a 0-frame file, or tens of milliseconds of audio) cost nothing at all.
    public static let minimumDuration: TimeInterval = 0.5

    /// Judges a recording from its two measurements: how many seconds of it are voiced, and how
    /// many seconds long it is. Both comparisons are `>=`, so a recording sitting exactly on a
    /// threshold is accepted -- the gate errs towards transcribing.
    public static func verdict(
        voicedSeconds: TimeInterval,
        totalSeconds: TimeInterval
    ) -> Verdict {
        guard totalSeconds >= minimumDuration else {
            return .silence(String(
                format: "%.2fs long, under the %.1fs minimum",
                totalSeconds, minimumDuration
            ))
        }
        guard voicedSeconds >= minimumVoicedDuration else {
            return .silence(String(
                format: "%.1fs of voice in %.1fs, under the %.1fs minimum",
                voicedSeconds, totalSeconds, minimumVoicedDuration
            ))
        }
        return .speech
    }

    /// A silence run longer than this is not decoded at all. See `framesWorthDecoding`.
    ///
    /// 30 s, from the corpus and from Whisper's own shape, and NOT a round number picked for
    /// comfort. The longest silence inside any of Louis's 1 437 real dictations is **26.6 s**
    /// (p99 = 9.7 s), so at 30 s the removal touches **0 of 1 437** of them -- the same property
    /// the accept/reject thresholds were chosen for. It is also exactly the model's window: a
    /// gap shorter than this is always decoded together with the speech around it, which is the
    /// condition under which the model does not fabricate.
    ///
    /// A shorter rule was measured and rejected rather than reasoned about. At 5 s the removal
    /// touched 59 real dictations (4.1 %), and on the eight worst it changed the transcript --
    /// against a within-arm control of 1.000, three runs each -- with similarity to Superwhisper's
    /// own transcript falling from 0.529 to 0.463 on average. The cause is that the 0.005 RMS
    /// frame threshold is calibrated to answer "is there ANY speech here", not "is this stretch
    /// worth keeping": Louis's quietest dictations sit under it for seconds at a time, so a 5 s
    /// rule deletes real, quiet words. Trading a measured regression on 4 % of ordinary
    /// dictations for a fix to a pathological one would have been a bad bargain.
    public static let maximumSilenceRun: TimeInterval = 30

    /// How much of a removed silence run is kept at each of its edges: enough that a word
    /// starting too quietly to register as voiced is not clipped off, and enough that the pause
    /// itself still reads as a pause.
    ///
    /// 1.5 s rather than 0.5 s because the difference is audible in the output, deterministically
    /// over three runs each. On a file of two utterances 45 s apart, 0.5 s of padding splices them
    /// into one wrong sentence -- `Bonjour, ceci est un test DE verification finale du journal.` --
    /// while 1.5 s keeps them as the two separate utterances the untrimmed file produces. Removing
    /// silence must not remove the sentence boundary the silence was carrying.
    public static let silencePadding: TimeInterval = 1.5

    /// The frames worth handing to the model, given which frames are voiced.
    ///
    /// This exists because the accept/reject verdict above is a WHOLE-FILE decision and a long
    /// recording defeats it without being wrong: 660 s of silence followed by 3.1 s of real
    /// speech is accepted -- correctly, there is speech in it -- and the model, which sees the
    /// file as 22 windows of 30 s, answers the 22 silent windows with a confident `"Thank you."`
    /// each before transcribing the real tail. That fabricated preamble gets pasted.
    ///
    /// Nothing in WhisperKit 1.1.0 stops it, and this was measured rather than assumed: on those
    /// silent windows the model reports `noSpeechProb = 0.000` and `avgLogProb = -0.160`, so
    /// `noSpeechThreshold` and `logProbThreshold` never fire, and each window's compression ratio
    /// is 0.86 because the repetition is ACROSS windows, not inside one, so
    /// `compressionRatioThreshold` cannot see it either. `ChunkingStrategy.vad` makes it worse
    /// (29 fabrications instead of 22): it chooses chunk boundaries at silence, it never drops
    /// silence. The only thing that works is not decoding the silence.
    ///
    /// The rule is deliberately conservative: only a silence run LONGER than
    /// `maximumSilenceRun` is removed, and `silencePadding` of it survives at each edge. A
    /// dictation with ordinary thinking pauses therefore comes through untouched, byte for byte,
    /// which is what keeps this from quietly rewriting the normal case.
    public static func framesWorthDecoding(voiced: [Bool]) -> [Range<Int>] {
        let maximumRun = Int((maximumSilenceRun / Double(frameLength)).rounded())
        let padding = Int((silencePadding / Double(frameLength)).rounded())

        var kept: [Range<Int>] = []
        var keepFrom = 0
        var runStart = 0

        func closeRun(endingAt runEnd: Int) {
            guard runEnd - runStart > maximumRun else { return }
            kept.append(keepFrom..<(runStart + padding))
            keepFrom = runEnd - padding
        }

        for (index, isVoiced) in voiced.enumerated() where isVoiced {
            closeRun(endingAt: index)
            runStart = index + 1
        }
        closeRun(endingAt: voiced.count)

        kept.append(keepFrom..<voiced.count)
        return kept.filter { !$0.isEmpty }
    }
}
