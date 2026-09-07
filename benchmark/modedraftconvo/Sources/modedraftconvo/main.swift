import Foundation
import MurmureCore

// One-shot network verification for the mode-drafting lot -- not run by `swift test`. Sends the
// assembled system prompt (`ModeDraftSystemPrompt`, the same function the app calls) plus one
// French request to a local Ollama's `/api/chat`, non-streaming, ONE request, against the SMALL
// model (`gemma4:e2b-it-qat`, 4.3 GB) rather than the 12b one -- see docs/plans/2026-09-backlog.md
// §8. Prints the reply verbatim, saves it as a test fixture, and runs it through
// `ModeDraftExtraction.extract` -- the same function the sheet itself calls.
//
// Gated by `MURMURE_NETWORK_TESTS=1`. Run with:
//   MURMURE_NETWORK_TESTS=1 swift run --package-path benchmark/modedraftconvo modedraftconvo
//
// Read-only against `~/Library/Application Support/Murmure/models` (never writes there); never
// pulls or deletes an Ollama model; never touches WhisperKit.
guard ProcessInfo.processInfo.environment["MURMURE_NETWORK_TESTS"] == "1" else {
    print("MURMURE_NETWORK_TESTS is not set to 1 -- skipping. This binary calls a local Ollama.")
    exit(0)
}

let ollamaBase = URL(string: "http://localhost:11434")!
let model = "gemma4:e2b-it-qat"
let userMessage = "Un mode pour dicter des messages Slack courts, en français, tutoiement, sans emoji"

// MARK: - What is actually installed on this machine (read-only)

let modelsStore = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Murmure/models")
let installedSpeechModels = ModelInventory.installedSpeechModels(in: modelsStore).map(\.string)

func fetchOllamaListing() async -> [String] {
    do {
        let (data, response) = try await URLSession.shared.data(from: OllamaProbe.endpoint(base: ollamaBase))
        guard let http = response as? HTTPURLResponse else { return [] }
        if case .listed(let listed) = OllamaProbe.list(status: http.statusCode, body: data) {
            return listed.map(\.name)
        }
    } catch {
        print("could not list Ollama models: \(error)")
    }
    return []
}

let installedOllamaModels = await fetchOllamaListing()
print("installed speech models: \(installedSpeechModels)")
print("installed ollama models: \(installedOllamaModels)")

let systemPrompt = ModeDraftSystemPrompt.build(
    installedSpeechModels: installedSpeechModels, installedOllamaModels: installedOllamaModels)

// MARK: - The one request

// `OllamaChat.requestBody` is exactly the shape this needs -- one system turn, one user turn,
// `stream: false` -- the task explicitly allows non-streaming for this verification.
var request = URLRequest(url: OllamaChat.endpoint(base: ollamaBase))
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = OllamaChat.requestBody(model: model, instructions: systemPrompt, transcript: userMessage)

struct ChatAnswer: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
}

do {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        print("no HTTP response")
        exit(1)
    }
    guard http.statusCode == 200 else {
        print("HTTP \(http.statusCode): \(String(decoding: data, as: UTF8.self))")
        exit(1)
    }
    let reply = try JSONDecoder().decode(ChatAnswer.self, from: data).message.content

    print("=== REPLY (verbatim) ===")
    print(reply)
    print("=== END REPLY ===")

    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MurmureCore/Tests/MurmureCoreTests/Fixtures/mode-draft-reply-gemma4-e2b.txt")
    try reply.write(to: fixturePath, atomically: true, encoding: .utf8)
    print("saved fixture to \(fixturePath.path)")

    let extraction = ModeDraftExtraction.extract(
        from: reply, installedSpeechModels: installedSpeechModels,
        installedOllamaModels: installedOllamaModels, existingModeKeys: ["voice", "prompt"])

    switch extraction {
    case .success(let candidate):
        print(
            "EXTRACTION: success -- key=\(candidate.mode.key) name=\(candidate.mode.name) "
                + "sttInstalled=\(candidate.sttModelInstalled) llmInstalled=\(candidate.llmModelInstalled)")
        do {
            try candidate.mode.validate()
            print("VALIDATION: passes Mode.validate()")
        } catch {
            print("VALIDATION: fails -- \(error)")
        }
    case .failure(let problem):
        print("EXTRACTION: failed -- \(problem)")
    }
} catch {
    print("network error: \(error)")
    exit(1)
}
