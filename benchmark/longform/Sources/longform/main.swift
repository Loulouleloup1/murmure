// Throwaway feasibility spike -- measures WhisperKit 1.1.0 on a 40-60 min French audio file
// using the owner's already-compiled turbo model. See ../../../spike-longform/spike-report.md
// (scratchpad) for the write-up. Not imported by Murmure; standalone CLI only.

import Darwin
import Foundation
import WhisperKit

// MARK: - CLI args

struct Args {
    var modelFolder: String
    var tokenizerFolder: String?
    var audioPath: String
    var chunking: String // "vad" | "none"
    var clipEnd: Int? // seconds
    var language: String
    var outJSON: String
}

func parseArgs() -> Args {
    var modelFolder: String?
    var tokenizerFolder: String?
    var audioPath: String?
    var chunking = "none"
    var clipEnd: Int?
    var language = "fr"
    var outJSON = "segments.json"

    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--model-folder": modelFolder = it.next()
        case "--tokenizer-folder": tokenizerFolder = it.next()
        case "--audio": audioPath = it.next()
        case "--chunking": chunking = it.next() ?? "none"
        case "--clip-end": clipEnd = it.next().flatMap { Int($0) }
        case "--language": language = it.next() ?? "fr"
        case "--out-json": outJSON = it.next() ?? "segments.json"
        default:
            FileHandle.standardError.write("Unknown argument: \(arg)\n".data(using: .utf8)!)
        }
    }
    guard let modelFolder, let audioPath else {
        FileHandle.standardError.write("""
            Usage: longform --model-folder <path> [--tokenizer-folder <path>] --audio <path> \
            [--chunking vad|none] [--clip-end seconds] [--language fr] [--out-json <path>]\n
            """.data(using: .utf8)!)
        exit(1)
    }
    return Args(
        modelFolder: modelFolder, tokenizerFolder: tokenizerFolder, audioPath: audioPath,
        chunking: chunking, clipEnd: clipEnd, language: language, outJSON: outJSON
    )
}

// MARK: - Peak RSS via mach_task_basic_info

func peakResidentSetSizeBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kerr == KERN_SUCCESS ? info.resident_size_max : 0
}

// MARK: - Repetition checks

/// Counts distinct 4-grams (whitespace-split) that appear more than 3 times within one segment.
func fourGramRepeatCount(in text: String) -> Int {
    let tokens = text.split(separator: " ").map(String.init)
    guard tokens.count >= 4 else { return 0 }
    var grams: [String: Int] = [:]
    for i in 0...(tokens.count - 4) {
        let gram = tokens[i..<(i + 4)].joined(separator: " ")
        grams[gram, default: 0] += 1
    }
    return grams.values.filter { $0 > 3 }.count
}

extension Duration {
    var seconds: Double {
        let comps = components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}

// MARK: - Progress tracker (callback may fire from concurrent VAD workers)

final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocationCount = 0
    private var lastReportedBucket = -1

    func record(_ progress: TranscriptionProgress) {
        lock.lock()
        defer { lock.unlock() }
        invocationCount += 1
        let audioSeconds = progress.timings.inputAudioSeconds
        let bucket = Int(audioSeconds / 30.0)
        if bucket > lastReportedBucket {
            lastReportedBucket = bucket
            print(
                "progress: windowId=\(progress.windowId) audioSeconds=\(String(format: "%.1f", audioSeconds)) textLen=\(progress.text.count)"
            )
        }
    }
}

// MARK: - Segment dump

struct SegmentDump: Codable {
    let id: Int
    let start: Float
    let end: Float
    let text: String
}

// MARK: - Main

let args = parseArgs()

print("=== Config ===")
print("model folder: \(args.modelFolder)")
print("tokenizer folder: \(args.tokenizerFolder ?? "(none passed -- defaults to downloadBase)")")
print("audio: \(args.audioPath)")
print("chunking: \(args.chunking)")
print("clip end: \(args.clipEnd.map(String.init) ?? "none")")
print("language: \(args.language)")

let libraryDefaults = DecodingOptions()
print("=== WhisperKit DecodingOptions library defaults ===")
print("compressionRatioThreshold: \(libraryDefaults.compressionRatioThreshold.map { String($0) } ?? "nil")")
print("logProbThreshold: \(libraryDefaults.logProbThreshold.map { String($0) } ?? "nil")")
print("firstTokenLogProbThreshold: \(libraryDefaults.firstTokenLogProbThreshold.map { String($0) } ?? "nil")")
print("noSpeechThreshold: \(libraryDefaults.noSpeechThreshold.map { String($0) } ?? "nil")")
print("concurrentWorkerCount (macOS default): \(libraryDefaults.concurrentWorkerCount)")

let clock = ContinuousClock()

let loadStart = clock.now
let config = WhisperKitConfig(
    modelFolder: args.modelFolder,
    tokenizerFolder: args.tokenizerFolder.map { URL(fileURLWithPath: $0) },
    verbose: false,
    logLevel: .error,
    prewarm: false,
    load: true,
    download: false
)

let whisperKit = try await WhisperKit(config)
let loadDuration = (clock.now - loadStart).seconds
print("=== Load ===")
print(String(format: "load time: %.2f s", loadDuration))

let tracker = ProgressTracker()

var chunkingStrategy: ChunkingStrategy?
switch args.chunking {
case "vad": chunkingStrategy = ChunkingStrategy.vad
case "none": chunkingStrategy = ChunkingStrategy.none
default: chunkingStrategy = nil
}

var clipTimestamps: [Float] = []
if let clipEnd = args.clipEnd {
    clipTimestamps = [0, Float(clipEnd)]
}

let decodeOptions = DecodingOptions(
    verbose: false,
    task: .transcribe,
    language: args.language,
    temperature: 0,
    wordTimestamps: false,
    clipTimestamps: clipTimestamps,
    compressionRatioThreshold: libraryDefaults.compressionRatioThreshold,
    logProbThreshold: libraryDefaults.logProbThreshold,
    firstTokenLogProbThreshold: libraryDefaults.firstTokenLogProbThreshold,
    noSpeechThreshold: libraryDefaults.noSpeechThreshold,
    concurrentWorkerCount: libraryDefaults.concurrentWorkerCount,
    chunkingStrategy: chunkingStrategy
)

print("=== Decoding options in effect ===")
print("concurrentWorkerCount: \(decodeOptions.concurrentWorkerCount)")
print("chunkingStrategy: \(String(describing: decodeOptions.chunkingStrategy))")
print("clipTimestamps: \(decodeOptions.clipTimestamps)")

let transcribeStart = clock.now
let results = try await whisperKit.transcribe(
    audioPath: args.audioPath,
    decodeOptions: decodeOptions,
    callback: { progress in
        tracker.record(progress)
        return true
    }
)
let transcribeDuration = (clock.now - transcribeStart).seconds

print("=== Transcribe ===")
print(String(format: "transcribe time: %.2f s", transcribeDuration))
print("callback invocations: \(tracker.invocationCount)")

let allSegments = results.flatMap { $0.segments }
print("segments: \(allSegments.count)")

print("=== First 3 segments ===")
for seg in allSegments.prefix(3) {
    print("[\(seg.start)\u{2013}\(seg.end)] \(seg.text)")
}
print("=== Last 3 segments ===")
for seg in allSegments.suffix(3) {
    print("[\(seg.start)\u{2013}\(seg.end)] \(seg.text)")
}

var consecutiveDupes = 0
if allSegments.count > 1 {
    for i in 1..<allSegments.count where allSegments[i].text == allSegments[i - 1].text {
        consecutiveDupes += 1
    }
}
let fourGramHeavySegments = allSegments.filter { fourGramRepeatCount(in: $0.text) > 0 }.count
print("=== Repetition check ===")
print("consecutive duplicate segments: \(consecutiveDupes)")
print("segments with a 4-gram repeated >3x: \(fourGramHeavySegments)")

let peakRSS = peakResidentSetSizeBytes()
print("=== Memory ===")
print(String(format: "peak RSS: %.1f MB", Double(peakRSS) / 1024 / 1024))

let dump = allSegments.map { SegmentDump(id: $0.id, start: $0.start, end: $0.end, text: $0.text) }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(dump)
try data.write(to: URL(fileURLWithPath: args.outJSON))
print("segments written to: \(args.outJSON)")
