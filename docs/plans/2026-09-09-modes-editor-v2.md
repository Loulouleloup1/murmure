# Modes editor v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Voice becomes a protected built-in, Prompt a deletable example; every other mode carries a refiner of one of two kinds (S1 or general); the editor is two cards; the icon grid has no duplicate; refiner models carry a memory-fit badge.

**Architecture:** Rules live in `MurmureCore` (`Mode`, `ModeStore`, new `ModelFit`, `HardwareProfile`, `RefinerKind` helpers) with XCTest; the app target (`Murmure/ModesPaneView.swift`, `ModesPaneModel.swift`) only draws and wires. The app has no test bundle: it is verified by `xcodebuild` and Louis's eye-gate.

**Tech Stack:** Swift 6, SwiftUI (macOS 14), SPM package `MurmureCore`, Ollama HTTP (`/api/tags` already read by `OllamaProbe`).

**Spec:** `docs/specs/2026-09-09-modes-editor-v2-design.md`

## Global Constraints

- Voice is protected: `key == "voice"`; name and symbol immutable; never deletable; language, hotkey, speech model editable; no refiner.
- Prompt is seeded once (marker file `.seeded` in `modes/`), never recreated after deletion.
- A non-protected mode saved through the editor must have `llm.enabled == true` (`ModeValidationError.refinerRequired`); files with it off still load.
- Refiner kinds map 1:1 onto `Mode.LLM.API`: `.s1` lists only names where `ChatModelFilter.looksLikeS1`, `.chat` lists only `ChatModelFilter.isChatCapable` names.
- Kind defaults: `.s1` → model `Mode.cleanupModel`, instructions `Mode.prompt.instructions`; `.chat` → model `Mode.rewriteModel`, instructions `Mode.prompt.instructions`.
- `ModelFit`: recommended ≤ 45 % of physical memory, tight ≤ 70 %, too large above. Badge on refiner models only (Ollama reports bytes; the speech listing does not, so speech models get no badge in this lot — spec §6 amended).
- Icon grid: one list, `ModeSymbol.library`, the stage-default tile captioned "Default" and storing `symbol = nil`.
- Colours only through `Color(role:)`. British English in UI strings. No owner data in tests.
- Never launch the app, never touch `~/Library`, never `git stash`. Implementers do not commit.

## File structure

- Modify `MurmureCore/Sources/MurmureCore/Mode.swift`: `isProtected`, two validation cases, `LLM.API.defaultModel/defaultInstructions`, `Mode.editorValidationError`.
- Modify `MurmureCore/Sources/MurmureCore/ModeStore.swift`: seeding marker, protected refusals.
- Create `MurmureCore/Sources/MurmureCore/ModelFit.swift`: `HardwareProfile`, `ModelFit`.
- Modify `MurmureCore/Sources/MurmureCore/ModeSymbol.swift`: `isStageDefault(_:for:)`.
- Tests: `ModeTests.swift`, `ModeStoreTests.swift`, new `ModelFitTests.swift`, `ModeSymbolTests.swift`.
- App: `Murmure/ModesPaneModel.swift` (hardware profile, fit lookup, kind switch, protected guards), `Murmure/ModesPaneView.swift` (two cards, single icon list, badges, locked fields, notice).
- Docs: `docs/plans/2026-09-backlog.md` §10, `docs/design/ui-design-notes.md`.

---

### Task 1: Protected Voice and mandatory refiner (core rules)

**Files:**
- Modify: `MurmureCore/Sources/MurmureCore/Mode.swift`
- Modify: `MurmureCore/Sources/MurmureCore/ModeStore.swift` (`save(_ draft:)`, `delete(_ draft:)`)
- Test: `MurmureCore/Tests/MurmureCoreTests/ModeTests.swift`, `ModeStoreTests.swift`

**Interfaces:**
- Produces: `Mode.isProtected: Bool`; `ModeValidationError.protectedField(String)`, `.refinerRequired`; `Mode.editorValidationError(original: Mode?) -> ModeValidationError?`; `ModeWriteProblem.protectedMode(key:)`.

- [ ] **Step 1: Failing tests** (append to `ModeTests`):

```swift
    func testVoiceIsTheOnlyProtectedMode() {
        XCTAssertTrue(Mode.voice.isProtected)
        XCTAssertFalse(Mode.prompt.isProtected)
        var custom = Mode.prompt; custom.key = "meeting"
        XCTAssertFalse(custom.isProtected)
    }

    func testEditingAProtectedModesNameOrSymbolIsRefused() {
        var renamed = Mode.voice; renamed.name = "Dictée"
        XCTAssertEqual(renamed.editorValidationError(original: .voice), .protectedField("name"))
        var reglyphed = Mode.voice; reglyphed.symbol = "brain"
        XCTAssertEqual(reglyphed.editorValidationError(original: .voice), .protectedField("symbol"))
    }

    func testAProtectedModeStillAcceptsLanguageShortcutAndSpeechModel() {
        var edited = Mode.voice
        edited.stt.language = "en"
        edited.stt.model = "openai_whisper-small"
        edited.hotkey = KeyCombo(keyCode: 49, modifiers: [.option, .shift])
        XCTAssertNil(edited.editorValidationError(original: .voice))
    }

    func testANonProtectedModeNeedsARefinerInTheEditor() {
        var off = Mode.prompt; off.llm.enabled = false
        XCTAssertEqual(off.editorValidationError(original: .prompt), .refinerRequired)
        XCTAssertNil(off.validationError, "files with the refiner off must still load")
        XCTAssertNil(Mode.voice.editorValidationError(original: .voice), "Voice is the exception")
    }
```

(If `KeyCombo`'s initialiser differs, read `KeyCombo.swift` and use its public init.)

Append to `ModeStoreTests` (reuse the file's temp-directory helper and its `ModeDraft` construction; read the existing `testDeleteRemovesTheFile`-style test first and copy its shape):

```swift
    func testDeletingVoiceIsRefused() throws {
        let store = makeStore()
        try store.createBuiltInsIfMissing()
        let draft = ModeDraft(mode: .voice, original: .voice, previousKey: "voice",
                              previousModifiedAt: store.modificationDate(forKey: "voice"))
        XCTAssertThrowsError(try store.delete(draft)) { error in
            XCTAssertEqual(error as? ModeWriteProblem, .protectedMode(key: "voice"))
        }
        XCTAssertTrue(store.loadAll().contains { $0.key == "voice" })
    }

    func testSavingVoiceWithANewNameIsRefusedButANewLanguageIsKept() throws {
        let store = makeStore()
        try store.createBuiltInsIfMissing()
        var renamed = Mode.voice; renamed.name = "Dictée"
        let bad = ModeDraft(mode: renamed, original: .voice, previousKey: "voice",
                            previousModifiedAt: store.modificationDate(forKey: "voice"))
        XCTAssertThrowsError(try store.save(bad))
        var relangued = Mode.voice; relangued.stt.language = "en"
        let good = ModeDraft(mode: relangued, original: .voice, previousKey: "voice",
                             previousModifiedAt: store.modificationDate(forKey: "voice"))
        XCTAssertNoThrow(try store.save(good))
        XCTAssertEqual(store.loadAll().first { $0.key == "voice" }?.stt.language, "en")
    }
```

- [ ] **Step 2: Run** `swift test --filter 'ModeTests|ModeStoreTests'` → FAIL (missing members).

- [ ] **Step 3: Implement.** In `Mode.swift`:

```swift
extension Mode {
    /// Voice is the built-in dictation mode: its identity (name, glyph) is fixed and it cannot be
    /// deleted, so that "press the shortcut and speak" always exists. Everything else about it
    /// (language, shortcut, speech model) stays the user's.
    public var isProtected: Bool { key == Mode.voice.key }

    /// The rules the editor enforces on top of `validationError`, which stays the on-disk contract:
    /// a file that breaks these still loads, a Save that breaks them is refused.
    public func editorValidationError(original: Mode?) -> ModeValidationError? {
        if let error = validationError { return error }
        if isProtected {
            if let original, name != original.name { return .protectedField("name") }
            if let original, symbol != original.symbol { return .protectedField("symbol") }
            return nil
        }
        if !llm.enabled { return .refinerRequired }
        return nil
    }
}
```

Add to `ModeValidationError`: `case protectedField(String)` with description `"\"<field>\" cannot be changed on the built-in Voice mode"` and `case refinerRequired` with description `"a mode other than Voice needs a refiner; without one it is Voice"`.

In `ModeStore.swift`: add `case protectedMode(key: String)` to `ModeWriteProblem` (description `"\"<key>\" is built in and cannot be deleted"`), make `delete(_ draft:)` start with `if draft.mode.isProtected { throw ModeWriteProblem.protectedMode(key: draft.mode.key) }`, and make `save(_ draft:)` call `if let error = draft.mode.editorValidationError(original: draft.original) { throw error }` instead of `try draft.mode.validate()`. Keep `save(_ mode: Mode)` (the seeding path) on `validate()`.

- [ ] **Step 4: Run** the two filters → PASS. Run the whole package → all green.

---

### Task 2: Prompt seeded once

**Files:**
- Modify: `MurmureCore/Sources/MurmureCore/ModeStore.swift` (`createBuiltInsIfMissing`)
- Test: `ModeStoreTests.swift`

**Interfaces:** `createBuiltInsIfMissing()` keeps its signature; new private `seededMarkerURL` (`modes/.seeded`).

- [ ] **Step 1: Failing tests:**

```swift
    func testPromptIsSeededOnceAndStaysDeleted() throws {
        let store = makeStore()
        try store.createBuiltInsIfMissing()
        XCTAssertTrue(store.loadAll().contains { $0.key == "prompt" })
        let prompt = store.loadAll().first { $0.key == "prompt" }!
        try store.delete(ModeDraft(mode: prompt, original: prompt, previousKey: "prompt",
                                   previousModifiedAt: store.modificationDate(forKey: "prompt")))
        try store.createBuiltInsIfMissing()   // next launch
        XCTAssertFalse(store.loadAll().contains { $0.key == "prompt" })
    }

    func testVoiceIsStillRepairedAfterSeeding() throws {
        let store = makeStore()
        try store.createBuiltInsIfMissing()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("voice.json"))
        try store.createBuiltInsIfMissing()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("voice.json").path))
    }

    func testAnExistingInstallIsMarkedSeededWithoutReseedingPrompt() throws {
        // A directory that already has a user mode but no marker: the marker is written, Prompt is
        // NOT added (it was deleted on purpose before this lot existed, or never wanted).
        let store = makeStore()
        var custom = Mode.prompt; custom.key = "meeting"; custom.name = "Meeting"
        try store.save(custom)
        try store.createBuiltInsIfMissing()
        XCTAssertFalse(store.loadAll().contains { $0.key == "prompt" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".seeded").path))
    }
```

(`directory` is the test's temp URL; adapt to the helper's name.)

- [ ] **Step 2: Run** → FAIL on the first test.

- [ ] **Step 3: Implement:**

```swift
    /// Voice is repaired at every launch. Prompt is an example: seeded once, into a directory that
    /// has never held any mode, and never again -- deleting it must stick. The marker records that
    /// seeding happened; a directory that already has modes but no marker is an install from
    /// before this rule and is marked without seeding.
    public func createBuiltInsIfMissing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hadModes = !fileNames().filter { $0.hasSuffix(".json") }.isEmpty
        let marker = directory.appendingPathComponent(".seeded")
        if !FileManager.default.fileExists(atPath: marker.path) {
            if !hadModes { try save(Mode.prompt) }
            try Data().write(to: marker, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: fileURL(for: Mode.voice.key).path) {
            try save(Mode.voice)
        }
    }
```

Check `fileNames()` ignores dot-files (or filter `.json` as above, which it does). Existing tests asserting Prompt is recreated on every launch, if any, are updated to the new rule and the ledger says so.

- [ ] **Step 4: Run** → PASS; whole package green.

---

### Task 3: `HardwareProfile` and `ModelFit`

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/ModelFit.swift`
- Test: create `MurmureCore/Tests/MurmureCoreTests/ModelFitTests.swift`

**Interfaces:**
- Produces: `struct HardwareProfile { physicalMemoryBytes: Int64; chipName: String?; static func current() -> HardwareProfile }`; `enum ModelFit { recommended, tight, tooLarge; static func classify(modelBytes: Int64, memoryBytes: Int64) -> ModelFit; var label: String; var symbolName: String }`; `ModelFit.recommendedShare = 0.45`, `tightShare = 0.70`.

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
@testable import MurmureCore

final class ModelFitTests: XCTestCase {
    let memory: Int64 = 24 * 1_073_741_824   // 24 GiB

    func testBoundariesAreInclusive() {
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.45), memoryBytes: memory), .recommended)
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.45) + 1, memoryBytes: memory), .tight)
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.70), memoryBytes: memory), .tight)
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.70) + 1, memoryBytes: memory), .tooLarge)
    }

    func testRealisticModels() {
        XCTAssertEqual(ModelFit.classify(modelBytes: 8_100_000_000, memoryBytes: memory), .recommended)  // 12b q4
        XCTAssertEqual(ModelFit.classify(modelBytes: 20_000_000_000, memoryBytes: memory), .tooLarge)
    }

    func testUnknownMemoryNeverRecommends() {
        XCTAssertEqual(ModelFit.classify(modelBytes: 1, memoryBytes: 0), .tooLarge)
    }

    func testLabels() {
        XCTAssertEqual(ModelFit.recommended.label, "Recommended for this Mac")
        XCTAssertEqual(ModelFit.tight.label, "Tight on this Mac")
        XCTAssertEqual(ModelFit.tooLarge.label, "Too large for this Mac")
    }

    func testCurrentProfileReadsThisMachine() {
        let profile = HardwareProfile.current()
        XCTAssertGreaterThan(profile.physicalMemoryBytes, 1_073_741_824)
    }
}
```

- [ ] **Step 2: Run** → FAIL (type missing).

- [ ] **Step 3: Implement:**

```swift
import Foundation

/// What this Mac can hold. Read once per pane open; injected in tests.
public struct HardwareProfile: Equatable, Sendable {
    public let physicalMemoryBytes: Int64
    public let chipName: String?

    public init(physicalMemoryBytes: Int64, chipName: String?) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.chipName = chipName
    }

    public static func current() -> HardwareProfile {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chip: String?
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                chip = String(cString: buffer)
            }
        }
        return HardwareProfile(
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory), chipName: chip)
    }
}

/// How a model's weight compares with the memory of this Mac. Unified memory is shared with
/// everything else running, so the thresholds are deliberately conservative.
public enum ModelFit: Equatable, Sendable {
    case recommended, tight, tooLarge

    public static let recommendedShare = 0.45
    public static let tightShare = 0.70

    public static func classify(modelBytes: Int64, memoryBytes: Int64) -> ModelFit {
        guard memoryBytes > 0 else { return .tooLarge }
        let share = Double(modelBytes) / Double(memoryBytes)
        if share <= recommendedShare { return .recommended }
        if share <= tightShare { return .tight }
        return .tooLarge
    }

    public var label: String {
        switch self {
        case .recommended: "Recommended for this Mac"
        case .tight: "Tight on this Mac"
        case .tooLarge: "Too large for this Mac"
        }
    }

    public var symbolName: String {
        switch self {
        case .recommended: "checkmark.seal"
        case .tight: "exclamationmark.circle"
        case .tooLarge: "xmark.octagon"
        }
    }
}
```

- [ ] **Step 4: Run** → PASS.

---

### Task 4: Refiner kind defaults and the single icon list (core)

**Files:**
- Modify: `Mode.swift` (`LLM.API` extension), `ModeSymbol.swift`
- Test: `ModeTests.swift`, `ModeSymbolTests.swift`

**Interfaces:**
- Produces: `Mode.LLM.API.title: String` ("Superwhisper S1 (fixed-format cleanup)" / "General model (Gemma, Llama, …)"), `.defaultModel: String`, `.defaultInstructions: String`, `.accepts(modelName:) -> Bool`; `ModeSymbol.isStageDefault(_ symbol: String, for stage: ModeStage) -> Bool`; `Mode.switching(to api: API) -> Mode` (returns a copy with `llm.api`, `llm.model`, `instructions` reset to the kind's defaults, everything else kept).

- [ ] **Step 1: Failing tests:**

```swift
    func testEachRefinerKindHasItsOwnDefaultsAndModelFilter() {
        XCTAssertEqual(Mode.LLM.API.s1.defaultModel, Mode.cleanupModel)
        XCTAssertEqual(Mode.LLM.API.chat.defaultModel, Mode.rewriteModel)
        XCTAssertTrue(Mode.LLM.API.s1.accepts(modelName: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
        XCTAssertFalse(Mode.LLM.API.s1.accepts(modelName: "gemma4:12b-it-qat"))
        XCTAssertTrue(Mode.LLM.API.chat.accepts(modelName: "gemma4:12b-it-qat"))
        XCTAssertFalse(Mode.LLM.API.chat.accepts(modelName: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
        XCTAssertFalse(Mode.LLM.API.chat.accepts(modelName: "nomic-embed-text:latest"))
    }

    func testSwitchingKindResetsModelAndInstructionsOnly() {
        var mode = Mode.prompt
        mode.name = "Meeting"; mode.llm.api = .chat; mode.llm.model = "gemma4:12b-it-qat"
        mode.instructions = "Rewrite as bullet points."
        let switched = mode.switching(to: .s1)
        XCTAssertEqual(switched.llm.api, .s1)
        XCTAssertEqual(switched.llm.model, Mode.cleanupModel)
        XCTAssertEqual(switched.instructions, Mode.LLM.API.s1.defaultInstructions)
        XCTAssertEqual(switched.name, "Meeting")
        XCTAssertEqual(switched.stt, mode.stt)
    }
```

And in `ModeSymbolTests`:

```swift
    func testTheLibraryListsEachGlyphOnce() {
        XCTAssertEqual(Set(ModeSymbol.library).count, ModeSymbol.library.count)
    }

    func testTheStageDefaultsAreInTheLibraryAndRecognised() {
        XCTAssertTrue(ModeSymbol.isStageDefault("mic.fill", for: .transcription))
        XCTAssertTrue(ModeSymbol.isStageDefault("sparkles", for: .refinement))
        XCTAssertFalse(ModeSymbol.isStageDefault("sparkles", for: .transcription))
        XCTAssertTrue(ModeSymbol.library.contains("mic.fill") && ModeSymbol.library.contains("sparkles"))
    }
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement** in `Mode.swift`:

```swift
extension Mode.LLM.API {
    public var title: String {
        switch self {
        case .s1: "Superwhisper S1 (fixed-format cleanup)"
        case .chat: "General model (Gemma, Llama, …)"
        }
    }

    public var defaultModel: String {
        switch self {
        case .s1: Mode.cleanupModel
        case .chat: Mode.rewriteModel
        }
    }

    /// Both kinds start from Prompt's instructions: for S1 they are already control fields only,
    /// for a general model they are a sensible cleanup prompt to edit from.
    public var defaultInstructions: String { Mode.prompt.instructions }

    /// Which installed Ollama names this kind can drive. S1 is one model family with its own
    /// request shape; a general model is anything that can hold a chat and is not an embedder.
    public func accepts(modelName: String) -> Bool {
        switch self {
        case .s1: ChatModelFilter.looksLikeS1(modelName)
        case .chat: ChatModelFilter.isChatCapable(modelName)
        }
    }
}

extension Mode {
    public func switching(to api: Mode.LLM.API) -> Mode {
        var copy = self
        copy.llm.api = api
        copy.llm.model = api.defaultModel
        copy.instructions = api.defaultInstructions
        return copy
    }
}
```

Check `Mode.prompt.instructions` satisfies `containsOnlyControlFields` (the existing S1 validation); if it does not, use the existing S1 default instruction constant found in `Mode.swift` for `.s1` and say so in the report.

In `ModeSymbol.swift`:

```swift
    /// The glyph a mode shows when it has chosen none: the stage default. The picker captions that
    /// tile "Default" and stores `nil` for it, so the list holds each glyph once.
    public static func isStageDefault(_ symbol: String, for stage: ModeStage) -> Bool {
        symbol == stage.symbolName
    }
```

- [ ] **Step 4: Run** → PASS; whole package green.

---

### Task 5: `ModesPaneModel` — hardware, fit, kind switch, protected guards

**Files:**
- Modify: `Murmure/ModesPaneModel.swift`

**Interfaces:**
- Consumes: `HardwareProfile.current()`, `ModelFit.classify`, `OllamaProbe.Listed(name, bytes)` (already in `ollamaModels`), `Mode.LLM.API.accepts/defaultModel`, `Mode.switching(to:)`, `Mode.isProtected`, `ModeWriteProblem.protectedMode`.
- Produces: `let hardware: HardwareProfile` (read in `init`), `func fit(forRefiner name: String) -> ModelFit?` (nil when the name is not in `ollamaModels`), `func refinerChoices(for api: Mode.LLM.API) -> [OllamaProbe.Listed]` (filtered by `accepts`, sorted by name), `func recommendedRefiner(for api:) -> String` (largest `.recommended` among choices, else `api.defaultModel`), `func switchKind(_ api: Mode.LLM.API)` (if `draft.mode.instructions != draft.original.instructions` → set a `@Published var kindSwitchPrompt: ConfirmationPrompt?` reusing the existing `ConfirmationPrompt` shape with confirm → apply; else apply directly; apply = `draft.mode = draft.mode.switching(to: api)` then `draft.mode.llm.model = recommendedRefiner(for: api)`), `var canDeleteDraft: Bool` (`!(draft?.mode.isProtected ?? true)`), and the existing save path surfaces `ModeValidationError.refinerRequired`/`.protectedField` descriptions in `writeProblem` like other validation errors already are.

- [ ] **Step 1:** Read `ModesPaneModel.swift` fully (how `ollamaModels` is refreshed, how `writeProblem` is set on save, `ConfirmationPrompt`).
- [ ] **Step 2:** Implement the members above. `hardware` is read once in `init` with `HardwareProfile.current()` (injectable through an init parameter with default).
- [ ] **Step 3:** `xcodebuild` (command in Global Constraints of the SDD dispatch) → `BUILD SUCCEEDED`. No behaviour beyond the interfaces listed.

---

### Task 6: `ModesPaneView` — two cards, single icon list, badges, locks

**Files:**
- Modify: `Murmure/ModesPaneView.swift`
- Modify: `MurmureCore/Sources/MurmureCore/ModesLayout.swift` (+ `ModesLayoutTests`) only if a new constant is needed (card spacing 12).

**Interfaces:** consumes Task 5's members and `Mode.LLM.API.title`, `ModeSymbol.isStageDefault`, `ModelFit.label/symbolName`.

- [ ] **Step 1:** Read the `editor` computed property (≈ lines 246–300) and the pickers (`iconPicker`, `apiPicker`, `refinerModelPicker`, `speechModelPicker`, `previewBlock`, `contextGroup`).
- [ ] **Step 2: Restructure `editor`** into two `HomeCard`s (reuse `HomeCard` from `Murmure/HomeCards.swift`; if it is `private`, make it internal):
  - **Identity** card (title "Identity"): name, icon, language, shortcut, speech model. When `draft.mode.isProtected`: the name row shows the name as static text with `lock.fill` and the caption "Voice is the built-in dictation mode"; the icon grid is hidden and replaced by the fixed glyph.
  - **Refiner** card (title "Refiner"), hidden entirely when `draft.mode.isProtected`: segmented `Picker` over `[Mode.LLM.API.s1, .chat]` using `title`, bound through `model.switchKind(_:)` (not directly to the draft); model picker limited to `model.refinerChoices(for: api)` with each row `Text(name)` + badge (`Label(fit.label, systemImage: fit.symbolName)` in `.caption2`, secondary colour); then the S1 controls (existing) or the Instructions editor (existing); Context as a compact `HStack` of the three toggles; a `DisclosureGroup("What the refiner receives")` collapsed by default wrapping `previewBlock`; the existing Advanced button.
  - Remove the "Refine the transcript" toggle. If a loaded non-protected mode has `llm.enabled == false`, the Refiner card shows at its top a notice row (`exclamationmark.triangle`, "This mode has no refiner, so it behaves exactly like Voice.") with a button "Turn the refiner on" that sets `llm.enabled = true` and applies `switchKind(draft.mode.llm.api)`.
  - Actions row: hide Delete when `!model.canDeleteDraft`.
- [ ] **Step 3: Icon grid**: delete `defaultIconTile`; iterate `ModeSymbol.library` once; the tile where `ModeSymbol.isStageDefault(symbol, for: stage)` (stage = `.refinement` if `llm.enabled` else `.transcription`) gets a "Default" caption under it (`.caption2`, secondary) and, when tapped, stores `symbol = nil`; `isSelected` for it is `draft.mode.symbol == nil || draft.mode.symbol == symbol`.
- [ ] **Step 4:** `xcodebuild` → `BUILD SUCCEEDED`. Report every string added (British English).

---

### Task 7: Docs and full run

**Files:**
- Modify: `docs/plans/2026-09-backlog.md` (add `## 10. Modes editor v2 — CLOSED <date>` after §9, following §9's shape), `docs/design/ui-design-notes.md` (a `### Modes editor v2 -- shipped <date>` subsection near the earlier "shipped" ones), `docs/specs/2026-09-09-modes-editor-v2-design.md` §6 (badge on refiner models only in this lot; speech models later when the listing knows sizes).

- [ ] **Step 1:** Write the three edits.
- [ ] **Step 2:** `cd MurmureCore && swift test` → quote the totals line. `xcodebuild` → `BUILD SUCCEEDED`.

---

## Orchestrator steps after Task 7 (not for implementers)

1. Whole-branch review (arbiter tier) against the spec; one mutation on `editorValidationError` (drop the `refinerRequired` branch) must go red.
2. Install (`scripts/install.sh` quits Murmure; relaunch with `open "$HOME/Applications/Murmure.app"`), push with the account dance.
3. Louis's eye-gate: Voice shows locked name/icon and no Refiner card, Delete absent; deleting Prompt survives a relaunch; icon grid without duplicate, "Default" caption on the stage glyph; two cards; kind switch resets model and prompt (confirmation when the prompt was edited); badges on refiner models.
