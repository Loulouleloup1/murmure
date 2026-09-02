import Foundation
import WhisperKit

// Where the vocabulary's token cost is read off WhisperKit's OWN tokenizer rather than
// estimated from character counts. It answers two things the decode arms cannot:
//
//   1. how many tokens a list of N terms actually costs, per term;
//   2. which terms a list that exceeds the budget SILENTLY LOSES.
//
// (2) is the one that matters for the interface. The budget is
// `(Constants.maxTokenContext / 2) - 1` = 111 (`TextDecoder.swift:199`, with
// `maxTokenContext = Int(448 / 2)` at `Models.swift:1340`), and the trim is
// `Array(promptTokens.suffix(maxPromptLen))` (`TextDecoder.swift:200`) -- a SUFFIX, so
// overflow discards the FRONT of the list. A vocabulary pane that accepts an unbounded
// list therefore throws away the entries the user typed first.
//
// It is a separate executable rather than a flag on `vocabprobe` so that adding it
// cannot force a relink of a binary that may be mid-run: the two share the package and
// nothing else.
//
// Usage:  tokencount '["term one","term two",...]'  [more lists...]

let dictationModel = "openai_whisper-large-v3-v20240930_turbo"
let modelRepo = "argmaxinc/whisperkit-coreml"
let maxPromptLen = (Constants.maxTokenContext / 2) - 1

let base = try FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
let store = base.appending(path: "Murmure").appending(path: "models")
let folder = HubApiWrapper(downloadBase: store)
    .localRepoLocation(HubApiWrapper.Repo(id: modelRepo, type: .models))
    .appending(path: dictationModel)

let kit = try await WhisperKit(
    model: dictationModel, downloadBase: store, modelFolder: folder.path, verbose: false)
guard let tokenizer = kit.tokenizer else { exit(4) }

print("budget: \(maxPromptLen) tokens (Constants.maxTokenContext = \(Constants.maxTokenContext))")

for arg in CommandLine.arguments.dropFirst() {
    guard let data = arg.data(using: .utf8),
          let terms = try? JSONDecoder().decode([String].self, from: data)
    else { continue }

    // The prompt is built exactly as `vocab_select.prompt_string` builds it, so the
    // counts below are the counts the decode arms actually paid.
    let prompt = terms.joined(separator: ", ") + "."
    let all = tokenizer.encode(text: prompt)
        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }

    print("")
    print("N=\(terms.count)  \(all.count) tokens encoded, \(min(all.count, maxPromptLen)) kept"
          + (all.count > maxPromptLen ? "  -- OVER BUDGET by \(all.count - maxPromptLen)" : ""))

    // Cumulative cost per term, so the boundary can be located exactly. Each prefix is
    // re-encoded rather than summed from per-term counts: BPE merges across the ", "
    // separator, so per-term counts do not add up to the whole.
    var dropped: [String] = []
    var kept: [String] = []
    for (i, term) in terms.enumerated() {
        let prefix = terms.prefix(i + 1).joined(separator: ", ") + "."
        let n = tokenizer.encode(text: prefix)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count
        // A term survives the trim when it ends after the first (total - budget) tokens.
        let cutoff = max(0, all.count - maxPromptLen)
        if n <= cutoff { dropped.append(term) } else { kept.append(term) }
    }
    if all.count > maxPromptLen {
        print("  SILENTLY DROPPED (front of the list): \(dropped)")
        print("  first surviving term: \(kept.first.map { "\($0)" } ?? "none")")
    }
}
