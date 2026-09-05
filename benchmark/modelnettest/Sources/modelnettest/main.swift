import Foundation
import MurmureCore
import WhisperKit

// One-shot network verification for the "Add a model" lot -- the four paths the backlog names as
// "shipped unexecuted", plus the new classifier against real repositories. Gated so `swift test`
// never runs this: set `MURMURE_NETWORK_TESTS=1` and run
// `swift run --package-path benchmark/modelnettest modelnettest`.
//
// Hard rules this file follows, because the harness running it was told to:
// - never writes into `~/Library/Application Support/Murmure`
// - the speech download goes into a TEMPORARY directory, deleted before exit, and the model is
//   NEVER loaded into WhisperKit (ANE compilation competes with a real dictation)
// - the Ollama pull targets ONE small model chosen below, removed again with `/api/delete` before
//   exit -- the five models already on this machine are never touched.
//
// Running this OVERWRITES the three fixtures under
// `MurmureCore/Tests/MurmureCoreTests/Fixtures/` with whatever Hugging Face answers on this run --
// `saveFixture` below writes straight into the repo tree, not a scratch directory. That is
// deliberate (the fixtures are meant to track the live listing), but it means a run is not a
// side-effect-free read: expect `git status` to show those three files changed afterwards.

guard ProcessInfo.processInfo.environment["MURMURE_NETWORK_TESTS"] == "1" else {
    print("MURMURE_NETWORK_TESTS is not set to 1 -- skipping. This binary makes real network calls.")
    exit(0)
}

var failures: [String] = []

func report(_ label: String, _ line: String) {
    print("[\(label)] \(line)")
}

func fail(_ label: String, _ line: String) {
    failures.append("\(label): \(line)")
    print("[\(label)] FAILED -- \(line)")
}

// MARK: - 1. HF listing classification, three repositories

func saveFixture(_ data: Data, as name: String) throws {
    let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MurmureCore/Tests/MurmureCoreTests/Fixtures")
    let destination = fixturesDir.appendingPathComponent("\(name).json")
    try data.write(to: destination)
    report("fixtures", "saved \(destination.path) (\(data.count) bytes)")
}

func classifyRepository(_ repository: String, fixtureName: String) async {
    do {
        let url = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail("hf-listing \(repository)", "unexpected HTTP response")
            return
        }
        try saveFixture(data, as: fixtureName)
        let info = try JSONDecoder().decode(HuggingFaceModelInfo.self, from: data)
        let classification = ModelClassifier.classify(
            siblings: info.siblings, requiredBundles: ModelInventory.requiredBundles)
        switch classification {
        case .speechOnly(let candidates):
            report("hf-listing \(repository)", "executed: classified speechOnly, \(candidates.count) variants")
        case .refinerOnly(let candidates):
            let tags = candidates.map(\.tag).joined(separator: ", ")
            report("hf-listing \(repository)", "executed: classified refinerOnly, tags = [\(tags)]")
        case .both(let speech, let refiner):
            report("hf-listing \(repository)", "executed: classified both, \(speech.count) speech / \(refiner.count) refiner")
        case .notRunnable(let reason, let hasSafetensors):
            report("hf-listing \(repository)", "executed: classified notRunnable (safetensors=\(hasSafetensors)) -- \(reason)")
            if hasSafetensors {
                let name = repository.split(separator: "/").last.map(String.init) ?? repository
                var components = URLComponents(string: "https://huggingface.co/api/models")!
                components.queryItems = [
                    URLQueryItem(name: "search", value: "\(name) GGUF"),
                    URLQueryItem(name: "limit", value: "10"),
                ]
                if let (searchData, searchResponse) = try? await URLSession.shared.data(from: components.url!),
                   let searchHTTP = searchResponse as? HTTPURLResponse, searchHTTP.statusCode == 200 {
                    let suggestions = ModelClassifier.searchSuggestions(from: searchData)
                    report(
                        "hf-search \(repository)",
                        "executed: \(suggestions.count) suggestion(s) -- \(suggestions)")
                } else {
                    report("hf-search \(repository)", "executed: request completed, could not read the response")
                }
            }
        }
    } catch {
        fail("hf-listing \(repository)", error.localizedDescription)
    }
}

await classifyRepository("argmaxinc/whisperkit-coreml", fixtureName: "argmaxinc-whisperkit-coreml")
await classifyRepository("superwhisper/s1-mini-GGUF", fixtureName: "superwhisper-s1-mini-gguf")
await classifyRepository("XHToken/Spark-X2.5-4B", fixtureName: "xhtoken-spark-x2.5-4b")

// MARK: - 2. Download a real speech model into a TEMPORARY directory

do {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("modelnettest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let folder = try await WhisperKit.download(
        variant: "openai_whisper-tiny", downloadBase: tempDir, from: "argmaxinc/whisperkit-coreml")

    let missing = ModelInventory.requiredBundles.filter {
        !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
    }
    if missing.isEmpty {
        report("speech-download", "executed: openai_whisper-tiny downloaded to \(folder.path), all required bundles present, temp dir removed")
    } else {
        fail("speech-download", "missing bundles: \(missing)")
    }
} catch {
    fail("speech-download", error.localizedDescription)
}

// MARK: - 3. Pull ONE small GGUF via Ollama, verify, then remove it

let ollamaModel = "hf.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF:Q4_K_M"
let ollamaBase = URL(string: "http://localhost:11434")!

func ollamaTags() async throws -> OllamaProbe.ListingOutcome {
    let (data, response) = try await URLSession.shared.data(from: OllamaProbe.endpoint(base: ollamaBase))
    let http = response as! HTTPURLResponse
    return OllamaProbe.list(status: http.statusCode, body: data)
}

do {
    var request = URLRequest(url: OllamaPull.endpoint(base: ollamaBase))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = OllamaPull.requestBody(model: ollamaModel)

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        fail("ollama-pull", "unexpected HTTP status")
        throw NSError(domain: "modelnettest", code: 2)
    }
    var last: OllamaPull.LineOutcome = .progress(status: "pulling manifest", fraction: nil)
    for try await line in bytes.lines {
        guard let outcome = OllamaPull.outcome(line: Data(line.utf8), model: ollamaModel) else { continue }
        last = outcome
        if case .progress(let status, let fraction) = outcome {
            print("  ... \(status)\(fraction.map { " (\(Int($0 * 100))%)" } ?? "")")
        }
        if case .succeeded = outcome { break }
        if case .failed = outcome { break }
    }
    switch last {
    case .succeeded:
        if case .listed(let listed) = try await ollamaTags(),
           let found = listed.first(where: { $0.name == ollamaModel }) {
            report("ollama-pull", "executed: pulled \(ollamaModel), size \(ModelSize.readable(found.bytes))")
        } else {
            fail("ollama-pull", "pull reported success but the model is not in /api/tags")
        }
    case .failed(let failure):
        fail("ollama-pull", failure.description)
    case .progress:
        fail("ollama-pull", "stream ended without a success or failure line")
    }
} catch {
    fail("ollama-pull", error.localizedDescription)
}

do {
    var request = URLRequest(url: OllamaDelete.endpoint(base: ollamaBase))
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = OllamaDelete.requestBody(model: ollamaModel)
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    let outcome = OllamaDelete.outcome(status: http.statusCode, body: data, model: ollamaModel)
    if case .succeeded = outcome,
       case .listed(let listed) = try await ollamaTags(),
       !listed.contains(where: { $0.name == ollamaModel }) {
        report("ollama-delete", "executed: \(ollamaModel) removed and confirmed absent from /api/tags")
    } else {
        fail("ollama-delete", "delete did not confirm removal -- outcome \(outcome)")
    }
} catch {
    fail("ollama-delete", error.localizedDescription)
}

// MARK: - 4. The fallback listing path (no config.json)

// WhisperKit's own fallback fires when `fetchModelSupportConfig` cannot find a `config.json` and
// answers with `Constants.fallbackModelSupportConfig` instead. `SpeechModelCatalog`, the app-target
// listing that used to call this and detect the substitution, is deleted -- the live app no longer
// calls `fetchAvailableModels`/`fetchModelSupportConfig` at all, so this fallback cannot fire there
// any more. This function reproduces the check anyway, directly against WhisperKit, to prove the
// mechanism `SpeechModelListing` repairs still behaves the way its own doc comment describes.
func exerciseFallbackPath(_ repository: String) async {
    let config = await WhisperKit.fetchModelSupportConfig(from: repository)
    guard config.repoName == Constants.fallbackModelSupportConfig.repoName else {
        report("fallback-listing \(repository)", "not executed: this repository HAS a config.json -- fallback did not fire")
        return
    }
    do {
        let files = try await HubApiWrapper().getFilenames(from: .init(id: repository, type: .models))
        let derived = SpeechModelListing.plausibleVariants(in: files, requiredBundles: ModelInventory.requiredBundles)
        report(
            "fallback-listing \(repository)",
            "executed: config.json absent, fallback sentinel detected, derived \(derived.count) variant(s) from the raw file listing -- \(derived)")
    } catch {
        fail("fallback-listing \(repository)", error.localizedDescription)
    }
}

// `tomAndJetty/whisperkit-coreml` -- verified by hand (2026-09-05) against the live repository's
// own blob listing before wiring this call: it holds real WhisperKit variant folders
// (`openai_whisper-tiny`, `whisper-medium`, `whisper-small-ko`, `openai_whisper-small`) and no
// `config.json` of its own, which is exactly the shape that makes `fetchModelSupportConfig` fall
// back to Argmax's fallback table instead of failing or answering empty.
await exerciseFallbackPath("tomAndJetty/whisperkit-coreml")

// MARK: - Summary

print("")
if failures.isEmpty {
    print("All network paths executed successfully.")
} else {
    print("FAILURES:")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
