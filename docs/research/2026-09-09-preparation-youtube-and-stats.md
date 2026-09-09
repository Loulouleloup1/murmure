# Preparation: URL/file transcription and a statistics Home pane

Date: 2026-09-09. Status: research, nothing approved, nothing implemented.

Two features requested by the owner: (1) transcribe YouTube / X videos locally, (2) a statistics
dashboard "with fun and interesting things". This note synthesises the code grounding and the three
research briefs alongside it (`*-brief.md`, written by research agents: their claims are cited but
not all re-verified). Facts marked **verified** were checked by hand on this machine or in the
resolved WhisperKit checkout.

## 1. What the codebase already offers

| Need | State | Where |
|---|---|---|
| Transcribe an arbitrary audio file | exists | `WhisperKitEngine.transcribe(wav:language:model:initialPrompt:)` takes any file URL (`Murmure/WhisperKitEngine.swift:186`) |
| Long-audio chunking, progress, duration guard | absent | whole file decoded in one call; only silence trimming + `SpeechGate` |
| Record → transcribe → refine → paste → archive pipeline | exists, microphone-shaped | `DictationSession` actor over injected protocols (`MurmureCore/.../DictationSession.swift:176`) |
| Model sequencing | actor + single recorder | `WhisperKitEngine` is an actor; only one recording at a time (`AudioRecorder.swift:57`) |
| Audio decode of video containers | absent | AVFoundation only, no ffmpeg, no external binary anywhere |
| History rows after purge | metadata survives, text cleared | `RetentionPurge` clears the three text columns, keeps duration, chars, mode, model, target app, latencies |
| Word count per dictation | absent | only `insertedCharacters` |
| Dashboard / Home pane, Swift Charts | absent | six panes: History, Modes, Vocabulary, Models, General, Advanced |
| Sandbox | disabled | `ENABLE_APP_SANDBOX: NO`; running a subprocess is possible |
| WhisperKit version resolved | **verified** 1.1.0 | `Murmure.xcodeproj/.../swiftpm/Package.resolved` and `git describe` on the checkout. An earlier draft of this note said 1.7.0: a grep had read the first `Package.resolved` found under `.build`, which belonged to another package. Corrected 2026-09-09 after the S2 spike. |

## 2. URL acquisition (YouTube, X)

- **verified**: yt-dlp release `2026.08.19` ships `yt-dlp_macos` (37 MB) and `yt-dlp_macos.zip`.
  The forum claim that the macOS binary was dropped is false.
- **verified**: this Mac has ffmpeg 9.0.1 (Homebrew, arm64) but no yt-dlp and no Deno. Other users
  will have neither, so the design cannot assume any of them.
- Reported (brief): YouTube in 2026 requires a JavaScript challenge solver (Deno by default; Node,
  Bun or QuickJS opt-in) and periodically PO tokens; failure modes to design for are the
  "Sign in to confirm you're not a bot" wall, solver failure and a stale extractor. X public videos
  extract without login; protected/NSFW/Spaces need browser cookies.
- Reported: no maintained Swift-native extractor exists; Cobalt only works self-hosted. yt-dlp is the
  only realistic option.
- Reported: audio-only extraction (`-x`) needs ffmpeg. Without ffmpeg one can still download the
  `m4a` (AAC) stream, which AVFoundation decodes; `webm`/Opus it cannot.
- Gatekeeper: a downloaded binary launched via `Process` needs the quarantine attribute removed
  (`xattr -d com.apple.quarantine`) and, per the brief, an ad-hoc `codesign`. The official binary is
  a PyInstaller bundle; behaviour on macOS 26 to be confirmed by a spike.
- Terms of service: YouTube's ToS forbid downloading; personal local use is the tolerated grey zone
  in which MacWhisper and Downie operate. Flagged to the owner, not a green light.

## 3. Long-form local transcription

- **verified** in WhisperKit 1.1.0 (the checkout that was grepped): `DecodingOptions.chunkingStrategy: .vad`, `concurrentWorkerCount`,
  `wordTimestamps`, `clipTimestamps`, `compressionRatioThreshold` / `logProbThreshold` /
  `noSpeechThreshold`, and an `EnergyVAD` (no Silero VAD in the package).
- Reported throughput: large-v3-turbo on the ANE around 20× real time on an M3 class chip, so one
  hour of audio in roughly three minutes; quality is preserved by VAD chunking. Whisper's known
  long-form failure is repetition/hallucination after silences; VAD pre-segmentation plus the
  threshold guards are the standard mitigation.
- Reported alternative: Parakeet TDT 0.6B v3 via FluidAudio (CoreML, 25 European languages incl.
  French) at roughly 100× real time. Second engine, second dependency, no head-to-head French WER
  found. Not for a first version.
- Contention with dictation: a long job would occupy the ANE and the same model. Options: pause
  dictation while a file job runs (simple, honest), or a second model instance (memory: turbo is
  about 1.6 GB, acceptable on 16 GB, but two ANE compilations compete). Recommendation: one job at a
  time, dictation shortcut disabled with a visible reason while the job runs.
- Video containers: AVFoundation reads mp4/mov/m4a (AAC, H.264, HEVC); not mkv, not WebM/Opus,
  not Vorbis. Route YouTube through the `m4a` stream or through ffmpeg.
- Post-processing with the local LLM: a 40-minute transcript is 6,000+ words; the current modes
  assume one dictation fits the 8k context. Paragraphing or summarising needs chunked prompts and a
  distinct mode kind. Out of scope for a first version; the raw timestamped transcript is the value.

## 4. Statistics dashboard

What Superwhisper's Home shows (from the UI notes): period picker, four figures (average WPM,
total words, apps used, time saved with a gear to set the formula), onboarding checklist, changelog.
Wispr Flow's Usage tab adds a percentile, a Sun–Sat contribution heatmap, current/longest streak,
an app-usage bar chart and "corrections made by Flow".

Cheap with existing columns: dictations count, spoken minutes, mode split, target-app split,
busiest hours/days heatmap, longest dictation, latency trend. Need a new persisted field: words per
dictation (raw and refined), hence spoken WPM, time saved, "filler words removed" delta.

Design constraints derived from the codebase: rows survive purge, so an "all time" view needs no
separate rollup table if word counts are stored on the row at insert. A backfill can compute word
counts for rows whose text is still present; older rows stay without.

Honesty rules for "time saved": state the typing baseline on screen and let the user change it
(40 WPM is the common default); compute speaking WPM from the user's own timestamps; never a fixed
marketing figure.

Swift Charts (macOS 13+) covers everything: `BarMark`, `LineMark`, `RectangleMark` heatmap;
`.contentTransition(.numericText())` for animated counters; `ContentUnavailableView` for empty
states. No third-party dependency needed.

## 5. Open decisions for the owner

1. Where does a long transcript live and what does the user do with it (history row, dedicated
   Transcripts pane with timestamps, export to Markdown, copy)?
2. Accept three runtime downloads at first use (yt-dlp, ffmpeg, Deno) and the ToS grey zone, or
   restrict to local files and let the user fetch media themselves?
3. Dictation paused during a file job (recommended) or a second model instance?
4. Home pane replacing History as the first screen, or a Statistics pane in the sidebar?
5. Which "fun" widgets make the first cut.

## 6. Spikes (run 2026-09-09, reports alongside)

- S1: run the official `yt-dlp_macos` from a temp directory on one public YouTube URL and one X URL,
  measure whether Deno is demanded, time, format obtained, Gatekeeper behaviour. Throwaway.
- S2: transcribe a 30 to 60 minute French audio file with WhisperKit 1.1.0, `.vad` chunking, turbo
  model, on this machine: real-time factor, peak memory, repetition incidents. Throwaway harness in
  `benchmark/`.

## 7. Spike results (measured on this Mac, M4 Pro 24 GB, macOS 26.6.2)

S1 (`2026-09-09-spike-ytdlp-report.md`): the official `yt-dlp_macos` 2026.08.19 runs first try with a
restricted PATH, no quarantine attribute after a `curl` fetch, already ad-hoc signed; YouTube `-F`
and the `m4a` audio download succeed with only a "no JS runtime" warning; X public video works
without login through native HLS; `afconvert` (Core Audio, same decoders as AVFoundation) decodes
the `m4a` and refuses WebM/Opus; `-U` works. Fixed cost about 10 s per invocation (PyInstaller unpack).
Progress lines need sentinel handling (`Unknown`, `NA`, padded percentages).

S2 (`2026-09-09-spike-longform-report.md`), harness kept in `benchmark/longform/`:

| Run | Audio | Chunking | Load | Transcribe | Real-time factor | Peak RSS | Segments | Repetitions |
|---|---|---|---|---|---|---|---|---|
| A | 2447 s (40.8 min) | vad | 1.96 s | 123.2 s | 19.9x | 585 MB | 245 | 0 |
| B | 600 s | none | 151 s (cold ANE compile in a fresh process) | 38.3 s | 15.7x | 462 MB | 123 | 0 |

French quality good; first segment of each run lower-case without punctuation, later ones punctuated
(known Whisper prefill behaviour). Special tokens leak into segment text unless `skipSpecialTokens`
is set. The progress callback fires per decoded token (about 12,000 times for 41 min) and its
`inputAudioSeconds` resets per window: a progress bar must derive from `windowId` or from a
real-time-factor estimate, and must be throttled. Peak memory footprint under VAD about 1 GB.
