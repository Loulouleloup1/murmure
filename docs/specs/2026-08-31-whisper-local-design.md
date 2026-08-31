# Murmure — Local voice dictation for macOS (design spec)

Date: 2026-08-31
Status: validated section-by-section with Louis during brainstorming; written for implementation planning.
Name: **Murmure** (confirmed 2026-08-31).

## 1. Purpose

A personal, fully local clone of Superwhisper for macOS: press a hotkey, speak, get clean text
inserted into the active app. Built because the commercial app charges a subscription to run
models that are free and local. Primary daily use case: **dictating prompts to AI harnesses**
(Claude Code in a terminal, Claude Desktop, Hermes Agent) and occasional Slack messages/emails.

Functional and visual inspiration is Superwhisper (documented behaviour from superwhisper.com/docs,
plus screenshots of the installed app taken at implementation time). All UI is recreated from
scratch — no third-party assets, icons, or code are copied. Not for redistribution or sale.

## 2. Scope

In scope (V1):
- Global-hotkey dictation with insertion into the active app.
- Modes with optional LLM refinement, context capture (selected text / clipboard / app context),
  and per-app auto-activation.
- Custom vocabulary (Whisper initial prompt) + post-transcription text replacements.
- History (SQLite + audio files), searchable, with re-processing.
- File transcription (audio/video) and YouTube-URL transcription via yt-dlp.
- Notch-first UI (Dynamic Island style), menu bar item, settings window, onboarding.
- LLM benchmark to pick the default refinement model (first executable lot).

Out of scope (decided):
- Meeting mode, system-audio capture, speaker separation — **permanently out** (user not interested).
- Cloud STT/LLM of any kind, API keys — **100% local** is the point.
- Windows/iOS, licensing, sync, enterprise anything.

## 3. Platform & stack

- macOS (Apple Silicon), MacBook Pro M4 Pro, 24 GB unified RAM.
- Native **Swift / SwiftUI** app, menu-bar only (LSUIElement, no Dock icon).
- STT: **WhisperKit** (argmax, MIT). Defaults decided 2026-08-31: **large-v3-turbo** for live
  dictation, **large-v3** for file/YouTube transcription (§8); both downloadable and selectable
  per mode.
- LLM refinement: HTTP client to any **OpenAI-compatible local endpoint** — Ollama
  (`localhost:11434/v1`) and LM Studio (`localhost:1234/v1`) both already installed.
- Notch UI: **DynamicNotchKit** (MIT, active) as the base library.
- Persistence: SQLite via **GRDB**; modes as JSON files (hand-editable, Superwhisper-style).
- YouTube: **yt-dlp** external binary (brew). Detected at runtime, never bundled.

## 4. Architecture

Four layers, each a separate Swift module boundary with a protocol seam:

```
AudioCapture ──▶ TranscriptionEngine ──▶ Refiner (optional) ──▶ Inserter
     │                   │                     │                    │
 AVAudioEngine       WhisperKit          OpenAI-compat HTTP     AX + CGEvent
     │                                                              │
     └────────────── ContextCapturer (selected text / clipboard / app context)
```

- **AudioCapture**: `AVAudioEngine` mic tap → 16 kHz mono buffers; writes the WAV to disk
  *as it records* (crash never loses audio). Publishes level samples for the waveform.
- **TranscriptionEngine** (protocol): `transcribe(audio, language, initialPrompt) async -> String`
  plus a streaming variant for live partial text. V1 ships one implementation (WhisperKit).
  The seam exists so a Parakeet/FluidAudio engine can be added later without touching callers —
  do NOT build that second engine in V1.
- **Refiner**: builds the prompt (mode instructions + context blocks + transcript), calls the
  configured endpoint/model, returns refined text. Skipped entirely for transcription-only modes.
- **ContextCapturer**: three independent captures with Superwhisper's timing semantics —
  selected text via AX (`AXSelectedText`) at recording start; clipboard if copied within 3 s
  before recording or during it; app context (frontmost app name, window title, focused text
  field content via AX) after transcription, just before the LLM call.
- **Inserter**: save clipboard → set result → synthesize ⌘V via `CGEvent` → restore clipboard.
  Fallback: simulated keystrokes for paste-blocking apps (per-mode or per-app toggle).
  On failure (focus lost), hand the text back to the UI for Re-paste / Copy.

### Coordinator

A single `DictationSession` state machine drives one dictation end-to-end:
`idle → recording → transcribing → refining → inserting → done/failed`.
UI surfaces (notch, menu bar) observe it; nothing else owns state.

### Hotkeys

Carbon `RegisterEventHotKey` for regular combos + `NSEvent` global monitor for single-modifier
keys (Fn, Right ⌘) — both patterns needed to match Superwhisper's flexibility. Toggle and
push-to-talk behaviours.

## 5. Modes

A mode = one JSON file in `~/Library/Application Support/Murmure/modes/<key>.json`:

```json
{
  "key": "prompt", "name": "Prompt", "hotkey": null,
  "stt": {"model": "large-v3-turbo", "language": "auto"},
  "llm": {"enabled": true, "endpoint": "http://localhost:11434/v1", "model": "<benchmark winner>"},
  "instructions": "…",
  "context": {"selectedText": false, "clipboard": false, "appContext": false},
  "autoActivate": ["com.googlecode.iterm2", "com.anthropic.claudefordesktop"],
  "simulateKeypresses": false
}
```

Built-in modes (created on first launch, all editable):
- **Voice** — raw transcription, no LLM. Default mode; the daily driver for Claude Code.
- **Prompt** — light LLM cleanup: remove hesitations/false starts, keep code-switching and
  technical terms verbatim, never rewrite meaning. For dictating to AI harnesses.
- **Message** — short conversational rewrite (Slack).
- **Email** — structured rewrite.

Auto-activation: frontmost-app bundle id → mode, checked at recording start; manual selection
otherwise (notch hover, menu bar). Deep links later if ever needed (out of V1).

Vocabulary (global): word list injected as Whisper `initialPrompt` (bias toward names like
Hindsight, Serena, WeeFin, DCG…). Text replacements (global): case-insensitive find→replace
applied after transcription, before the LLM.

## 6. UI

Design fidelity: at implementation time, screenshot the installed Superwhisper app
window-by-window and match layout/spacing/mood — recreate, never extract assets.

### Notch (primary surface, via DynamicNotchKit)

- **Idle**: nothing — the notch is a notch.
- **Recording**: notch expands sideways (Dynamic Island); live waveform wings on both sides;
  mode colour dot.
- **Processing**: subtle blue pulse; **green flash** on successful insertion.
- **Hover**: full expansion — active mode + switcher, elapsed time, Stop / Cancel
  (confirm if > 30 s), shortcuts to History / Settings.
- **Paste failure**: expanded panel keeps the text with Re-paste / Copy buttons.
- **No notch** (external display, clamshell): identical component anchored as a floating
  top-center pill. Settings choice: notch / pill / classic bottom overlay.

**Interaction model — continuous morphing, never a window glued to the notch** (added 2026-08-31
from Louis's design research). The notch is the ROOT component; it morphs between states, it never
"opens a window": idle (near-invisible) → recording (waveform wings) → processing (pulse) →
done (green flash, then retraction INTO the notch — replaces any macOS notification) →
hover (expanded dashboard) → paste-failure (expanded panel with the text). Collapsed → expanded →
full panel, always animated as one surface.

Design references for the notch UI lot (verify each repo + licence when planning that lot;
inspiration only unless MIT/Apache — DynamicNotchKit stays the dependency):
- AgentNotch (AppGram/agentnotch — verified, no licence: look only) — closed → hover → details pattern.
- Construct Notch (construct-computer/notch) — explicit 3-state UI (compact / hover bar / full).
- NotchNook (commercial) — the collapsed → expanded → full-panel morphing reference.
- DynamicNotch (jackson-storm/dynamicnotch), Atoll, NotchApp (erwinzhang7, SwiftUI+AppKit no deps),
  NotchDrop (Lakr233) — animation/morphing engines and "temporary interaction zone" pattern.
- gh-notch (aymandakirgh/ghnotch, MIT) — AI command bar in the notch with local model dispatch.

### Menu bar

Status-dot icon (yellow = model loading, red = recording, blue = processing, green = done).
Menu: start/stop, mode selector, Transcribe File…, History, Settings, Quit.
Optional Quick Recording (left-click toggles recording).

### Settings window

Sidebar: General (shortcuts, mic, language) · Modes (list + editor) · Models (Whisper model
download/delete, Ollama/LM Studio connection status + model picker) · Vocabulary (hints +
replacements) · History · Advanced (paste behaviour, clipboard restore, simulate keypresses).

### Onboarding (first launch)

1. Microphone permission → 2. Accessibility permission (deep link to System Settings)
→ 3. Default STT model download with progress → trial dictation.

## 7. Data & storage

`~/Library/Application Support/Murmure/`:
- `modes/*.json` — modes (hand-editable).
- `murmure.sqlite` — history: raw transcript, refined text, mode, models used, duration,
  target app, audio path, timestamps.
- `recordings/*.wav` — audio, written during capture.
- `models/` — WhisperKit model downloads.

History UI: three panes (searchable list — search hits raw transcript / playback + raw-vs-refined
toggle / metadata). Actions: Process Again (any mode), copy, delete. No auto-purge in V1;
manual "clear history" button only.

## 8. File & YouTube transcription

- Entry points: menu bar "Transcribe File…", drag-and-drop onto notch/settings window.
- Local audio/video: `AVFoundation` extracts the audio track; chunked transcription with
  progress; result lands in History; export .txt/.md.
- YouTube: paste a URL in the same sheet → `yt-dlp -x` downloads audio → same pipeline.
  If yt-dlp is missing, show the brew install command (copyable), never bundle it.
- Default model here: **large-v3** (quality; latency irrelevant) — decided 2026-08-31.

## 9. Error handling (defined behaviours, not afterthoughts)

| Failure | Behaviour |
|---|---|
| LLM endpoint unreachable | Insert the RAW transcript + toast "refinement unavailable" — a dictation is never lost |
| Accessibility revoked | Detected at launch + banner with deep link to System Settings |
| Paste failure / focus lost | Notch panel keeps text with Re-paste / Copy |
| Crash mid-dictation | Audio already on disk; History shows a recoverable entry |
| Whisper model missing | Settings → Models with download CTA; recording blocked with clear message |

## 10. LLM refinement benchmark (first executable lot)

Data-driven selection of the default refinement model. Candidates (verified on HF 2026-08-31):

| Model | Size | Notes |
|---|---|---|
| `superwhisper/s1-mini` | 0.75B | Superwhisper's own open-sourced dictation post-processor (Qwen3 base); no GGUF — needs MLX/GGUF conversion |
| `ornith-ai/Ornith-1.5-9B-GGUF` | 9B | GGUF ready (Q4_K_M), MIT |
| `google/gemma-4-12b-qat` | 12B | Gated — accept licence with Louis's HF account (or Ollama library equivalent) |
| `Qwen/Qwen3.5-9B` | 9.6B | Apache 2.0 |
| `ibm-granite/granite-4.2-8b` | 8.8B | FR supported |

Rejected from Louis's original list: `incoai/GLM-5.3-Flash-DFlash2` and `z-lab/Qwen3.8-27B-DFlash2`
are speculative-decoding **draft models** (unusable standalone; bases are 321B and 27.8B —
the latter too tight for 24 GB co-residency with Whisper + macOS).

Protocol (validated):
1. ~15 raw-transcript fixtures: 5 dictated for real by Louis (Superwhisper Voice mode) +
   10 synthetic calibrated on his usage (hesitations, false starts, FR/EN code-switching);
   2 tasks per fixture: *Prompt* cleanup and *Message* rewrite.
2. Blind scoring: outputs anonymised and shuffled; cold judge (Opus-tier subagent) with a rubric
   frozen before seeing any output — semantic fidelity / disfluencies removed / technical terms
   preserved verbatim / format respected; Louis adjudicates the top 2.
3. Machine metrics measured on the M4 Pro: end-to-end latency, tokens/s, peak RAM, disk size.
~35 GB of downloads total. Winner becomes the default in built-in modes; every mode keeps a
free-text model field regardless.

## 11. Testing strategy

- Unit tests on the logic core: prompt assembly, text replacements, auto-activation rules,
  mode JSON parsing/migration, clipboard save/restore sequencing.
- **Real round-trips** (per Louis's doctrine — unit tests alone never close a feature):
  dictate a reference phrase → assert the text actually lands in TextEdit; repeat for a
  paste-blocking app via the keystroke fallback; verify clipboard is restored byte-for-byte.
- STT/LLM quality is covered by the benchmark fixtures (§10), not by unit tests.
- Performance claims (transcription RTF, tokens/s) are measured on-device before being stated.

## 12. Open items

- Benchmark winner → default model of Prompt/Message/Email modes.
- Superwhisper UI screenshot pass happens at implementation start (app is installed).
- DynamicNotchKit API fit — if it can't express the waveform-wings layout, fall back to a
  custom NSPanel clone of the same pattern (decision deferred to the first UI task).
