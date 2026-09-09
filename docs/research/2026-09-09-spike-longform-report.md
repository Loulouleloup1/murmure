# WhisperKit long-form feasibility spike

Throwaway spike. Measures how the owner's already-compiled turbo model handles a 40-60 minute
French audio file, to inform a future "transcribe a long file" feature. No files under
`~/Library/Application Support/Murmure/` were written to; no GUI app, clipboard, keyboard or
microphone were touched; exactly one WhisperKit transcription ran at a time.

## Correction to the brief

The brief specified **WhisperKit 1.7.0**. The version actually resolved by this project is
**1.1.0** — confirmed against `Murmure.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
and `git describe` on `.build/xcode/SourcePackages/checkouts/WhisperKit` (both `v1.1.0`,
revision `1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`). This spike used **1.1.0** — the version the
app itself actually runs — rather than fabricate a build against a version not present in the
project.

## Environment

- Chip: Apple M4 Pro
- RAM: 24 GB
- macOS: 26.6.2 (build 25G83)
- Swift: 6.3.3 (swift-driver 1.148.6)
- WhisperKit: 1.1.0 (`argmaxinc/WhisperKit`, revision `1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`)

## Model

- Model folder: `~/Library/Application Support/Murmure/models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo` (AudioEncoder/TextDecoder/MelSpectrogram `.mlmodelc` bundles, `config.json`, `generation_config.json`)
- Tokenizer folder: `~/Library/Application Support/Murmure/models/models/openai/whisper-large-v3` (`tokenizer.json`, `tokenizer_config.json`, `config.json`)
- Resolved by reading `Murmure/WhisperKitEngine.swift` (`loadKit`, `cachedModelFolder`) and `ModelUtilities.loadTokenizer`: WhisperKit accepts `tokenizerFolder` either as the app's `downloadBase` root (hub-style resolution) or, as used here, the leaf folder directly — `loadTokenizer` explicitly checks "top level of `tokenizerFolder`" for `tokenizer.json` before falling back to the Hub. Passing the leaf folder directly, with `download: false`, means `setupModels` never consults the download path at all (confirmed by reading `WhisperKit.setupModels`: when `modelFolder` is non-nil, `download` is never even checked) — so this harness could not re-download the model even by accident.

## Audio

- Source: Alexandre Dumas, *Les Trois Mousquetaires*, Chapitre 6 ("Sa Majesté le roi Louis XIII"), public-domain LibriVox reading via archive.org
- URL: `https://archive.org/download/alexandre_dumas_-_les_trois_mousquetaires_chap06/Alexandre_Dumas_-_Les_Trois_Mousquetaires_Chap06.mp3`
- Duration: 2447.18 s (40.79 min), confirmed via `afinfo`
- Format: mono, 44.1 kHz MP3, 103 kbps
- Size: 31,656,586 bytes (30.2 MB)
- Deleted at the end of the spike (kept only the JSON segment dumps and this report)

No excerpt file was cut with `afconvert`/`sox` — Run B instead used WhisperKit's own
`clipTimestamps: [0, 600]` to select the first 10 minutes of the same file, per the brief's
documented fallback. `AudioProcessor.loadAudioAsFloatArray` decodes the MP3 itself (AVFoundation
under the hood), so no pre-conversion was needed either way.

## Harness

`benchmark/longform/` — throwaway SPM executable, modelled on `benchmark/modelnettest/Package.swift`
and `benchmark/vocabprobe/Package.swift` (same pinning rationale, no `MurmureCore` dependency
since only the raw WhisperKit `transcribe` API was needed). `swift build -c release` → `Build
complete! (3.78s)` after one fix (see Findings).

CLI: `longform --model-folder <path> --tokenizer-folder <path> --audio <path> --chunking vad|none [--clip-end <seconds>] --language fr --out-json <path>`.

## Library defaults (printed by the harness, `DecodingOptions()`)

| Option | Value |
|---|---|
| `compressionRatioThreshold` | 2.4 |
| `logProbThreshold` | -1.0 |
| `firstTokenLogProbThreshold` | -1.5 |
| `noSpeechThreshold` | 0.6 |
| `concurrentWorkerCount` (macOS) | 16 |

All three requested thresholds plus `concurrentWorkerCount` were kept at these library defaults
in both runs.

## Runs

| Metric | Run A — full file, VAD | Run B — first 10 min, none |
|---|---|---|
| Audio processed | 2447.18 s (40.79 min, full file) | 600 s (10 min, `clipTimestamps: [0, 600]`) |
| Load time (`ContinuousClock`) | 1.96 s | 151.39 s |
| Transcribe time (`ContinuousClock`) | 123.16 s | 38.26 s |
| Real-time factor (audio ÷ transcribe) | 19.87× | 15.68× |
| Peak RSS — Swift (`mach_task_basic_info.resident_size_max`) | 585.3 MB | 461.5 MB |
| Peak RSS — `/usr/bin/time -l` ("maximum resident set size") | 585.3 MB (613,711,872 B) | 461.5 MB (483,950,592 B) |
| Peak memory footprint — `/usr/bin/time -l` | 1002.0 MB | 520.9 MB |
| `/usr/bin/time -l` wall (`real`) | 125.25 s | 190.21 s |
| Segments | 245 | 123 |
| Callback invocations | 12,236 | 3,265 |
| Consecutive-duplicate segments | 0 | 0 |
| Segments with a 4-gram repeated >3× | 0 | 0 |

The two `resident_size_max` cross-checks (Swift's own reading vs. `/usr/bin/time -l`'s
independent measurement) agree exactly in both runs — the peak-RSS instrumentation is sound.
Neither run was aborted or clipped short: 5 minutes of audio in Run B's first pass took well
under the 60 s abort threshold (10 min transcribed in 38.26 s), so Run A proceeded on the full
file as planned; both `runA.log` and `runB.log` are in the scratch directory in full.

Total measured wall time for both runs together: **5m 25s** (`19:00:49` → `19:02:54` for Run A
alone; Run B ran `18:57` → `19:00`). Estimated Neural Engine busy time (transcribe portions
only): 123.16 s + 38.26 s ≈ **161 s**, well inside the ~10 minute budget.

### Why Run A's load was 1.96 s and Run B's was 151.39 s

Not a bug, and not evidence the two runs are incomparable. `WhisperKitEngine.swift`'s own
comments explain the mechanism directly: Core ML "specializes" a model to the device's ANE the
first time it is loaded, and caches the specialized artefact **on disk, outside the app sandbox,
managed by Apple** — evicted only by an OS update or prolonged disuse, not by process exit. Run B
was the first load in this spike (or the first since the last OS update / period of disuse) and
paid that one-time ANE-specialization cost — the same order of magnitude as the "112 s cold"
figure the app's own code comments record for a fresh dictation session. Run A, launched in a
*separate process* about two minutes later, hit the warm cache and loaded in 1.96 s. This
confirms the specialization cache survives process boundaries, not just the lifetime of a single
`WhisperKit` instance — useful for design: a shipped "transcribe a long file" feature pays this
cost once per machine (or once per OS update), not once per invocation, and a first-run UI should
set that expectation explicitly ("preparing the model — this can take a couple of minutes the
first time").

## Quality notes

- French reads correctly throughout both runs; no incoherent output, no obvious mistranslation,
  no visible dropped words at a glance.
- **First segments are unpunctuated and uncapitalized; later segments are properly punctuated and
  cased — in both runs.** Run A/B's segment 1: `chapitre sixième sa majesté le roi louis xiii` (no
  capitals, no punctuation). Run A's near-final segment: `— Eh bien, monsieur le cardinal, comment
  vont ce pauvre Bernageau et ce pauvre Jussac qui sont à vous?` (dash, capitals, comma, question
  mark). This is Whisper's own well-documented behaviour, not a WhisperKit defect: with
  `usePrefillPrompt: true` (the default), each window after the first is conditioned on the
  previous window's decoded tokens, and it is this conditioning — not anything about the words
  themselves — that pushes the model into consistent capitalisation and punctuation. The very
  first window decodes with no prior context and comes out flatter. A feature that streams partial
  results to the user should expect the opening sentence to look rougher than everything that
  follows, and should not read that as a quality regression.
- **Special tokens leak into the segment text.** Every segment that opens a fresh (non-conditioned)
  decoding window is prefixed with literal `<|startoftranscript|><|fr|><|transcribe|><|0.00|>`, and
  every segment carries inline `<|MM.SS|>` timestamp tokens around its text (e.g. `<|4.00|>`,
  `<|12.68|>`), and the very last segment ends with `<|endoftext|>`. This is because
  `DecodingOptions.skipSpecialTokens` defaults to `false` in WhisperKit 1.1.0 — confirmed in
  `Configurations.swift`. Any shipped feature must either set `skipSpecialTokens: true` or
  post-process these tokens out before showing text to a user; this spike did not, precisely so
  the raw behaviour would be visible.
- VAD (Run A) and none (Run B) produce essentially the same underlying text for the same audio —
  segment 1 and 2 are byte-for-byte identical across both runs — but segment **boundaries** differ:
  Run B's segment 3 ends at 19.4 s (`...au louvre`); Run A's segment 3, covering the same audio,
  extends to 29.0 s and folds in the next clause (`...ne pouvait recevoir en ce moment`). VAD
  groups on detected pauses rather than fixed windows, so it produces fewer, longer segments (245
  over the full 40.8 min vs. 123 over 10 min for "none" — roughly 10 s/segment for VAD vs. 4.9
  s/segment for "none"). A rough word-count check over the first 600 s of each run (1769 words for
  VAD's segments starting before 600 s, vs. 1842 words for the "none" run of exactly the first 600
  s) is consistent with this — not an apples-to-apples clip (VAD's segments span the 600 s cut
  unevenly), but no sign of dropped content.
- No hallucination or repetition-loop incidents in either run: 0 consecutive-duplicate segments,
  0 segments with a 4-gram repeated more than 3 times, across 368 total segments and roughly 51
  minutes of combined audio coverage.

## Callback behaviour — the actual, surprising finding

The callback fires **extremely** often: 12,236 times for Run A's 245 segments (≈50 callbacks per
segment) and 3,265 times for Run B's 123 segments (≈27 per segment) — this is essentially a
per-decoded-token callback, not a per-segment or per-window one.

The harness tried to throttle this to "one line per 30 s of audio progress" using
`progress.timings.inputAudioSeconds`, on the assumption that field is a cumulative "audio seconds
transcribed so far" counter. **It is not.** Both `runA.log` and `runB.log` show exactly **one**
`progress:` line each (`windowId=0 audioSeconds=0.0 textLen=49`) despite 12,236 and 3,265 callback
invocations respectively — meaning `inputAudioSeconds` stays inside `[0, 30)` for the *entire*
run rather than growing monotonically. It is scoped to the current decoding window, not to the
transcription as a whole, so it resets (or never advances past a small value) on every new window.
This is a real, load-bearing finding for the feature design, not a detail to gloss over: **a
"time-based" progress readout cannot be built naively on `TranscriptionProgress.timings.inputAudioSeconds`.**
A correct implementation needs either the `windowId` (available on every callback, and does
increment) combined with a known total window count, the segment/seek offset the underlying
`TranscriptionResult` carries once available, or a simple upfront RTF-based time estimate. This
was caught only by looking at the actual log output, not by inspecting the type signature — an
instance of the "verify by tracing an actual value end-to-end" habit paying off.

## Design implications

1. **Chunking strategy.** VAD chunking measured a materially higher real-time factor than serial
   "none" on this M4 Pro (19.87× vs. 15.68×) and produces coherent, fewer, longer segments (better
   suited to a scrubbable transcript UI). VAD should be the default chunking strategy for a
   "transcribe a long file" feature on macOS, consistent with `concurrentWorkerCount`'s 16-worker
   default existing specifically to parallelise VAD's independent chunks.
2. **Progress granularity must be throttled, and not on `inputAudioSeconds`.** With ~50 callbacks
   per segment and a per-window (not cumulative) `inputAudioSeconds`, a UI-facing progress
   indicator needs its own throttling logic keyed on something that actually advances monotonically
   (window index against a precomputed window count, or a periodic wall-clock sample converted via
   the measured RTF) — never call into UI-update code on every raw callback invocation, and never
   assume `inputAudioSeconds` alone tells you how far through the file you are.
3. **Memory budget on a 16 GB Mac running a live dictation app.** Peak RSS was modest in both runs
   (585 MB VAD/full-file, 462 MB none/10-min) and would fit comfortably alongside Murmure's own
   resident WhisperKit instance even on 16 GB. The Apple "peak memory footprint" metric, though,
   nearly doubled for VAD (1002 MB) vs. none (521 MB) — plausibly because VAD's 16 concurrent
   workers keep several audio-window buffers and Core ML compute graphs live at once. A
   long-form-transcribe feature that must coexist with a *second*, already-loaded WhisperKit
   instance for live dictation should budget for combined footprint north of 1.5 GB during a VAD
   run, and — per this repo's own safety rule of "exactly one WhisperKit instance, one
   transcription at a time" — should seriously consider whether it can run concurrently with live
   dictation at all, or whether it needs to pause/unload the dictation model first.
4. **First-load cost is a one-time, cross-process, cross-launch tax**, not a per-invocation one
   (see "Why Run A's load was 1.96 s" above). The UI only needs a distinct "warming up" state for
   the genuinely-first load after install or after an OS update, not for every transcription.
5. **VAD chunking changes segment boundaries, not segment correctness.** Timestamps stay anchored
   to true audio position under both strategies (both runs' segment 1/2 timestamps and text are
   identical), so a feature built on VAD's coarser segments is safe for seek/scrub — it just should
   not assume segment boundaries are comparable across a "none"-transcribed preview and a
   VAD-transcribed final pass.
6. **Special-token leakage and the ragged first sentence are both visible defaults, not bugs to
   chase** — `skipSpecialTokens: true` and awareness that the very first output line will look
   flatter than the rest should both be explicit design decisions in the shipped feature, not
   surprises found later.

## Files created

Harness (kept, part of the repo — not deleted):
- `/Users/louiscourcier/Documents/Perso/murmure/benchmark/longform/Package.swift`
- `/Users/louiscourcier/Documents/Perso/murmure/benchmark/longform/Package.resolved` (generated by `swift build`)
- `/Users/louiscourcier/Documents/Perso/murmure/benchmark/longform/Sources/longform/main.swift`
- `/Users/louiscourcier/Documents/Perso/murmure/benchmark/longform/.build/` (SPM build directory, generated)

Scratch (`/private/tmp/claude-501/-Users-louiscourcier-Documents-Perso/e036e084-c519-4427-a16c-ac22e99ff290/scratchpad/spike-longform/`):
- `chap06.mp3` — downloaded audio, **deleted** after the runs per instructions
- `runB.log` — Run B's full stdout/`/usr/bin/time -l` output (kept)
- `runB_segments.json` — Run B's 123 segments as JSON (kept)
- `runA_start.txt` — two `date` timestamps bracketing Run A's background execution (kept)
- `runA.log` — Run A's full stdout/`/usr/bin/time -l` output (kept)
- `runA_segments.json` — Run A's 245 segments as JSON (kept)
- `spike-report.md` — this report (kept)

No writes were made to `~/Library/Application Support/Murmure/`. No `git stash`, no commit, no
GUI app launched, no key events posted, no clipboard use, no microphone use, no NSEvent monitors.
