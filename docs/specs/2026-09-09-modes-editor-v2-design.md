# Murmure — Modes editor v2 (design spec)

Date: 2026-09-09. Status: draft for Louis's validation. Source: Louis's feedback after the Home lot,
grounded on the code (`Mode.swift`, `ModeStore.swift`, `ModesPaneView.swift`, `ModeSymbol.swift`).

## 1. Problems observed

1. Voice and Prompt are ordinary files: both can be edited or deleted; a deleted `prompt.json` is
   recreated at every launch by `ModeStore.createBuiltInsIfMissing`, so Prompt cannot be removed.
2. The icon grid shows the stage glyph twice: a "Default" tile (`mic.fill` or `sparkles`, meaning
   `symbol == nil`) followed by the same glyph as an ordinary tile of `ModeSymbol.library`.
3. The editor is one long column (name → icon → language → shortcut → speech model → refiner toggle
   → API → model → instructions → preview → context → advanced). A beginner and an expert get the
   same wall; nothing tells a beginner what to leave alone.
4. A mode can be created with the refiner off, which duplicates Voice.
5. Nothing relates model sizes to this Mac's memory.

## 2. Roles of the default modes

- **Voice** (`key == "voice"`) is *protected*: name and icon are fixed; language, shortcut and speech
  model stay editable; no refiner section at all; cannot be deleted (the Delete action is absent).
  `ModeStore` keeps repairing a missing `voice.json` as today.
- **Prompt** is an *example*: fully editable and deletable. It is seeded once, on first launch, and
  never recreated: `ModeStore.createBuiltInsIfMissing` seeds Prompt only when the `modes/` directory
  has never been seeded (a marker `.seeded` file in `modes/`, written after the first seeding).
  Existing installs: the marker is written at the first launch that finds `prompt.json` present or
  any user mode, so nothing changes for them.
- `Mode.isProtected` (computed, `key == "voice"`) is the single rule; the store refuses `delete` and
  refuses a `save` that changes `name` or `symbol` of a protected mode (`ModeValidationError.protectedField`).

## 3. Refiner is mandatory outside Voice

- Saving a non-protected mode with `llm.enabled == false` fails validation
  (`ModeValidationError.refinerRequired`). Files on disk that already have it off still load (no
  migration), and the editor shows a one-line notice with a button "Turn the refiner on".
- The "Refine the transcript" toggle disappears from the editor. `llm.enabled` stays in the model for
  Voice and for backwards compatibility.

## 4. Refiner kinds

`Mode.LLM.API` already has `.chat` and `.s1`. The editor presents them as two kinds:

| Kind | Label | Model picker | Instructions |
|---|---|---|---|
| `.s1` | "Superwhisper S1 (fixed-format cleanup)" | only models whose name matches the S1 family (`ModelClassifier.isS1` = name contains `superwhisper/s1`), default `Mode.cleanupModel` | bracketed control fields only (existing rule), pre-filled with the current default |
| `.chat` | "General model (Gemma, Llama, …)" | every installed Ollama model that is not S1, default `Mode.rewriteModel`; "recommended for this Mac" badge (§6) | free prompt, pre-filled with the default Prompt template |

Switching kind resets model and instructions to that kind's defaults (after a confirmation only if
the instructions were edited). Choosing S1 therefore locks the model list to S1; choosing General
excludes S1. `RefinementPreview` keeps rendering "What the refiner receives", collapsed by default.

## 5. Editor in two parts

Two cards in the inspector, both `HomeCard` style:

1. **Identity** — name, icon, language, shortcut, speech model (with the badge of §6). For Voice, name
   and icon are shown read-only with a lock glyph and the caption "Voice is the built-in dictation
   mode".
2. **Refiner** — kind (segmented), model, then either the S1 controls or the prompt editor, then
   Context (selected text, clipboard, app context) as a compact row of three toggles, then a
   disclosure "What the refiner receives" and the existing Advanced button. Hidden entirely for Voice.

Actions row unchanged (Save, Revert, Delete except for Voice, Draft with help).

### Icon grid

One list only: `ModeSymbol.library` in order, and the tile equal to the stage default
(`ModeStage.symbolName` for the mode's kind) carries a small "Default" caption; selecting it stores
`symbol = nil` as today; selecting any other tile stores the symbol. The separate `defaultIconTile`
is removed. `ModeSymbolTests` pins that the library contains each glyph once.

## 6. Hardware-aware recommendation (macOS only)

`HardwareProfile` in MurmureCore: `physicalMemoryBytes` (`ProcessInfo.processInfo.physicalMemory`),
`chipName` (`sysctlbyname("machdep.cpu.brand_string")`), injected in tests. `ModelFit.classify(modelBytes:
memoryBytes:)` returns `.recommended` (≤ 45 % of memory), `.tight` (≤ 70 %), `.tooLarge` (> 70 %),
pinned by tests with concrete byte values. Sizes come from Ollama `/api/tags` (`size`) for refiner
models and from the speech model inventory for Whisper models. Pickers show a badge per row
("Recommended for this Mac" / "Tight on this Mac" / "Too large for this Mac"); the default choice
of a new mode is the largest `.recommended` model among the installed ones, else the kind's default.
No download, no benchmark, no network beyond the local Ollama call already made.

## 7. Verification

MurmureCore tests: protected-mode rules (delete refused, name/symbol change refused, language and
speech model accepted); Prompt seeding once (marker) and never recreated after deletion; refiner
required for non-protected saves; S1 model filter; kind switch resets; `ModelFit` boundaries;
`ModeSymbol.library` uniqueness. App: `xcodebuild` BUILD SUCCEEDED. Louis's eye-gate: Voice locked
fields, Prompt deletion sticks across relaunch, icon grid without duplicates, two-card editor,
badges in both pickers.

## 8. Out of scope

Cloud models (ChatGPT etc.): the refiner stays local Ollama; a "General model" kind can grow a remote
endpoint later without changing this design. Fine-tuning, per-app auto-activation changes, mode
import/export.
