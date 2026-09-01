import Foundation

/// How far the transcription model's download has got, as the interface will state it.
///
/// **The number WhisperKit hands out cannot be shown, and that is the whole reason this type
/// exists.** `WhisperKit.download` forwards the Hub's `Progress`, and that object is built as
/// `Progress(totalUnitCount: filenames.count)` with one 100-unit child per file
/// (`HubApi.snapshot`, `:658-660`): its `fractionCompleted` is the **mean of the per-file
/// fractions, unweighted by size**. Measured on the real repository -- the 24 files of
/// `openai_whisper-large-v3-v20240930_turbo` as they sit on Louis's disk -- two of them carry
/// 98.6 % of the bytes:
///
/// | file | bytes | share of the bar |
/// |---|---|---|
/// | `AudioEncoder.mlmodelc/weights/weight.bin` | 1 273 974 400 | 1/24 |
/// | `TextDecoder.mlmodelc/weights/weight.bin` | 343 933 748 | 1/24 |
/// | the other 22, with the Hub's sidecars | 20 559 040 | 22/24 |
///
/// So the raw fraction reaches **91.7 % in the first seconds** and then spends the entire rest of
/// the download crawling through 8.3 %. On a fresh Mac that is the defect this task exists to
/// remove, reproduced *inside* the progress bar: a number that says "nearly done" while the app
/// has minutes left is worse than no number, by exactly the argument `DecodeProgress` already
/// makes about drawing tokens over `sampleLength`.
///
/// What is counted here instead is **bytes on disk**, which the app measures directly (see
/// `WhisperKitEngine.downloadModel`). Bytes are what the wait is made of, they include the
/// `.incomplete` file currently being written, and they need nothing from WhisperKit's internals.
public struct ModelDownload: Equatable, Sendable {
    /// The size of a complete `argmaxinc/whisperkit-coreml` store for the dictation variant, in
    /// bytes.
    ///
    /// **Measured, not quoted.** The sum of every file under
    /// `Application Support/Murmure/models/models/argmaxinc/whisperkit-coreml` on a machine that
    /// has finished the download: 48 files -- the 24 model files plus the 24 `.metadata` sidecars
    /// the Hub writes beside them -- totalling 1 638 467 188 bytes, i.e. the 1.6 GB the README's
    /// model table already quotes.
    ///
    /// It is a constant because nothing tells us the total in advance: `WhisperKit.download`
    /// exposes a fraction of files and no size at all, and asking the Hub for one would be a
    /// second network round-trip before the first byte. It can therefore **drift**, and the two
    /// ways it can are both survivable: a model that grew makes the percentage saturate (see
    /// `ceilingWhileRunning`), a model that shrank makes it finish early. Neither can make the
    /// interface look stopped, because the sweep beside the bar is a function of the clock and not
    /// of this number.
    public static let transcriptionModelBytes: Int64 = 1_638_467_188

    /// The highest percentage a *running* download is allowed to claim.
    ///
    /// **100 % is a claim only the end of the download may make, and the end of the download is a
    /// change of phase rather than a number.** If `transcriptionModelBytes` is ever an
    /// underestimate -- the variant re-uploaded a little larger -- an uncapped percentage would
    /// read 100 % while bytes were still arriving, which is the "finished but still waiting"
    /// state that started this whole task. Capping one point short means the worst drift can do is
    /// hold the bar at 99 % for the tail, with the sweep still moving over it.
    public static let ceilingWhileRunning = 99

    /// What the store is expected to hold once the download is complete. Never assumed: a caller
    /// has to say, so a test can describe a small download without pretending it is 1.6 GB.
    public let expectedBytes: Int64

    /// 0…`ceilingWhileRunning`. **The value stored is the value shown**, which is what makes two
    /// readings that would render identically compare equal -- so a caller can skip the ones that
    /// would change nothing on screen without owning a second rule about when they do.
    public private(set) var percent: Int = 0

    /// The same number as the fraction of a row to fill, for the drawing.
    public var fraction: Double { Double(percent) / 100 }

    public init(expectedBytes: Int64) {
        self.expectedBytes = expectedBytes
    }

    /// Takes a byte count off the disk and keeps it only if it moves what Louis sees.
    ///
    /// **Monotonic**, for a reason the disk really does produce: the Hub downloads into a
    /// `.<etag>.incomplete` file and then *moves* it to its destination
    /// (`Downloader.download`, `HubApi.snapshot`). A measurement taken between the two counts
    /// neither, so a walk of the store can read lower than the walk before it. A percentage that
    /// went backwards under Louis's eyes would be the app telling him it had lost ground.
    ///
    /// **Quantised to whole percent**, because that is the granularity the sentence is written at
    /// and because every advance costs a hop onto the main actor, a route through `StatusRouter`
    /// -- which sends a synchronous Accessibility message into the front application -- and a
    /// redraw of both surfaces. A poll every second over a multi-minute download would otherwise
    /// buy a few hundred of those to change a digit that was already right.
    ///
    /// **A store that could not be walked reads 0 bytes and changes nothing**, which is a
    /// behaviour rather than a line: it falls out of the monotonic guard below, since 0 % is where
    /// this starts and nothing is ever an advance on the percentage already reached. A `guard
    /// receivedBytes > 0` above would say so more loudly and would be unreachable -- the same trade
    /// `DecodeProgress.observe` records for its own missing `max(raw, 0)`, resolved the same way:
    /// the behaviour is pinned by a test, not by the line that happens to provide it.
    public mutating func observe(receivedBytes: Int64) {
        guard expectedBytes > 0 else { return }
        let measured = 100 * min(receivedBytes, expectedBytes) / expectedBytes
        let next = min(Self.ceilingWhileRunning, Int(measured))
        guard next > percent else { return }
        percent = next
    }
}

/// What the app is doing when the first dictation of a session looks like it is doing nothing.
///
/// Two steps rather than one, because they are not the same wait and not the same evidence:
///
/// - **`downloading`** is a 1.6 GB transfer over somebody's Wi-Fi. It has a number, the number
///   moves, and it is the state a fresh Mac spends minutes in.
/// - **`loading`** is `WhisperKit.init` handing four `.mlmodelc` bundles to CoreML, which compiles
///   them for this machine's neural engine the first time it sees them -- **112 s, measured
///   cold**, and seconds afterwards. There is no byte counter to have: nothing is being
///   transferred, and CoreML reports no progress. What it gets instead is a word of its own and a
///   glyph of its own, which is the difference between a wait with a cause and a hang.
///
/// `loading` is deliberately NOT specific to a fresh machine. Every launch pays it on the first
/// dictation of the session, so the state is worth saying on Louis's own Mac too, where the model
/// has been on disk since August.
public enum ModelPreparation: Equatable, Sendable {
    case downloading(ModelDownload)
    case loading
}
