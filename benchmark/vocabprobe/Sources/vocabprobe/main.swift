import Foundation
import MurmureCore
import WhisperKit

// A command-line probe for `DecodingOptions.promptTokens`, run against Louis's own
// recordings. It exists because the question -- does feeding Whisper a list of his
// technical terms make it spell them correctly -- cannot be answered from the app:
// the app has one decode path, no arms and no repeats.
//
// It deliberately reproduces `WhisperKitEngine` rather than importing it (the app
// target is not a library). Every argument below is copied from that file and the
// copies are load-bearing:
//
//   - the same variant, `downloadBase` and `WhisperKit.init` shape, so CoreML reuses
//     the compiled ANE artefacts instead of spending ~7 minutes recompiling them;
//   - the same `SpeechGate` silence removal, so the samples the model sees here are
//     the samples it would see in a dictation;
//   - the same `DecodingOptions(language: "fr")` baseline, with `promptTokens` as the
//     ONLY thing that varies between arms.
//
// Usage:  vocabprobe <jobs.json> <out.jsonl>
// Jobs:   {"model": "...", "tasks": [{"id","wav","arm","prompt"}]}
//         `prompt` null means no prompt tokens at all -- the arm the app ships today.

// MARK: - Job description

struct Job: Decodable {
    struct Task: Decodable {
        let id: String
        let wav: String
        let arm: String
        /// The literal string handed to WhisperKit's tokenizer. Null = no prompt.
        let prompt: String?
    }

    let tasks: [Task]
}

struct Row: Encodable {
    let id: String
    let arm: String
    let wav: String
    let text: String
    let promptTokenCount: Int
    /// What WhisperKit actually kept after `Array(promptTokens.suffix(maxPromptLen))`.
    let promptTokensKept: Int
    let decodeSeconds: Double
    let audioSeconds: Double
    let decodedSeconds: Double
    let error: String?
}

// MARK: - Model configuration, copied from Murmure/WhisperKitEngine.swift

let dictationModel = "openai_whisper-large-v3-v20240930_turbo"
let modelRepo = "argmaxinc/whisperkit-coreml"

/// `Constants.maxTokenContext` is 224 (`Models.swift:1340`, `Int(448 / 2)`), and the
/// decoder trims the prompt to `(maxTokenContext / 2) - 1` (`TextDecoder.swift:199`).
/// So the real budget is 111 tokens, and the trim is a `.suffix` -- overflow drops the
/// FRONT of the list, not the end.
let maxPromptLen = (Constants.maxTokenContext / 2) - 1

func modelStore() throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false)
    return base.appending(path: "Murmure").appending(path: "models")
}

func cachedModelFolder(in store: URL) -> URL? {
    let folder = HubApiWrapper(downloadBase: store)
        .localRepoLocation(HubApiWrapper.Repo(id: modelRepo, type: .models))
        .appending(path: dictationModel)
    let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    let complete = required.allSatisfy {
        FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
    }
    return complete ? folder : nil
}

// MARK: - Audio, copied from Murmure/WhisperKitEngine.swift

func voicedFrames(in samples: [Float]) -> [Bool] {
    EnergyVAD(
        sampleRate: WhisperKit.sampleRate,
        frameLength: SpeechGate.frameLength,
        energyThreshold: SpeechGate.energyThreshold
    ).voiceActivity(in: samples)
}

func audioWorthDecoding(samples: [Float], voiced: [Bool]) -> [Float] {
    let frameSamples = Int(SpeechGate.frameLength * Float(WhisperKit.sampleRate))
    return SpeechGate.framesWorthDecoding(voiced: voiced).flatMap { frames -> ArraySlice<Float> in
        let start = min(frames.lowerBound * frameSamples, samples.count)
        let end = min(frames.upperBound * frameSamples, samples.count)
        return samples[start..<end]
    }
}

// MARK: - Run

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: vocabprobe <jobs.json> <out.jsonl>\n".utf8))
    exit(2)
}

let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let outURL = URL(fileURLWithPath: args[2])
FileManager.default.createFile(atPath: outURL.path, contents: nil)
let out = try FileHandle(forWritingTo: outURL)

let store = try modelStore()
guard let folder = cachedModelFolder(in: store) else {
    FileHandle.standardError.write(Data("model not cached at \(store.path)\n".utf8))
    exit(3)
}

let loadStart = Date()
let kit = try await WhisperKit(
    model: dictationModel,
    downloadBase: store,
    modelFolder: folder.path,
    verbose: false
)
let loadSeconds = Date().timeIntervalSince(loadStart)
FileHandle.standardError.write(Data("model loaded in \(String(format: "%.1f", loadSeconds))s\n".utf8))
// A load measured in minutes rather than seconds means CoreML did NOT reuse the ANE
// artefacts and is recompiling them. Say so loudly: it is the one side effect this
// harness is not allowed to have.
if loadSeconds > 60 {
    FileHandle.standardError.write(Data("WARNING: cold load -- the ANE cache was not reused\n".utf8))
}

guard let tokenizer = kit.tokenizer else {
    FileHandle.standardError.write(Data("no tokenizer on the loaded model\n".utf8))
    exit(4)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

// Samples are cached per WAV: reading and gating a file is identical across arms and
// repeats, so paying for it once keeps the measured latency the decoder's own.
var sampleCache: [String: (audio: [Float], full: Int)] = [:]

for (index, task) in job.tasks.enumerated() {
    var promptTokens: [Int]?
    var kept = 0
    if let prompt = task.prompt {
        let encoded = tokenizer.encode(text: prompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        promptTokens = encoded
        kept = min(encoded.count, maxPromptLen)
    }

    var row = Row(
        id: task.id, arm: task.arm, wav: task.wav, text: "",
        promptTokenCount: promptTokens?.count ?? 0, promptTokensKept: kept,
        decodeSeconds: 0, audioSeconds: 0, decodedSeconds: 0, error: nil)

    do {
        let cached: (audio: [Float], full: Int)
        if let hit = sampleCache[task.wav] {
            cached = hit
        } else {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: task.wav)
            let voiced = voicedFrames(in: samples)
            cached = (audioWorthDecoding(samples: samples, voiced: voiced), samples.count)
            sampleCache[task.wav] = cached
        }

        let options = DecodingOptions(language: "fr", promptTokens: promptTokens)
        let start = Date()
        let results = try await kit.transcribe(audioArray: cached.audio, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        row = Row(
            id: task.id, arm: task.arm, wav: task.wav, text: text,
            promptTokenCount: promptTokens?.count ?? 0, promptTokensKept: kept,
            decodeSeconds: elapsed,
            audioSeconds: Double(cached.full) / Double(WhisperKit.sampleRate),
            decodedSeconds: Double(cached.audio.count) / Double(WhisperKit.sampleRate),
            error: nil)
    } catch {
        row = Row(
            id: task.id, arm: task.arm, wav: task.wav, text: "",
            promptTokenCount: promptTokens?.count ?? 0, promptTokensKept: kept,
            decodeSeconds: 0, audioSeconds: 0, decodedSeconds: 0,
            error: error.localizedDescription)
    }

    out.write(try encoder.encode(row))
    out.write(Data("\n".utf8))
    if (index + 1) % 10 == 0 {
        FileHandle.standardError.write(Data("\(index + 1)/\(job.tasks.count)\n".utf8))
    }
}

try out.close()
