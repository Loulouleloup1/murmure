# Murmure — Transcripts: files and URLs (design spec)

Date: 2026-09-09
Status: validated section-by-section with Louis during brainstorming; written for implementation
planning. Three lots (T1 external tool, T2 pipeline and storage, T3 pane).
Supersedes §8 "File & YouTube transcription" of `2026-08-31-whisper-local-design.md` on three
points, listed in §9.
Companion research: `docs/research/2026-09-09-preparation-youtube-and-stats.md`,
`2026-09-09-url-acquisition-brief.md`, `2026-09-09-longform-stt-brief.md`, and the two spike
reports `2026-09-09-spike-ytdlp-report.md` and `2026-09-09-spike-longform-report.md`.

## 1. Purpose

Paste a YouTube or X URL, or drop an audio/video file, and get a timestamped transcript produced
entirely on the machine. The only network access is fetching the media the user asked for, and the
one-time download of the fetching tool. Transcripts are long-lived documents, unlike dictations:
they live in their own pane and tables and are never purged automatically.

Out of scope for this version: cookies or logins for protected content, playlists, speaker
separation, refinement or summarisation of the transcript by the local LLM, search across
transcripts, a built-in media player, live streams.

## 2. External tool (lot T1)

### 2.1 What is downloaded, when, and with whose consent

Only `yt-dlp` is installed by Murmure, as the official standalone macOS binary of a release pinned
in code (`yt-dlp_macos`, 2026.08.19 at the time of writing, about 37 MB), from
`https://github.com/yt-dlp/yt-dlp/releases/download/<tag>/yt-dlp_macos`. Spike S1 established that
ffmpeg is not needed when the `m4a` stream is selected, and that the tested YouTube and X videos did
not need a JavaScript runtime.

Deno is a second, on-demand download offered only when a job fails with yt-dlp's
"JavaScript runtime required" class of error (§2.4). Same consent sheet, same folder, then passed
to yt-dlp with `--js-runtimes deno:<path>`.

The first time the user submits a URL, a consent sheet is shown before anything is fetched:

> Murmure needs yt-dlp to fetch media from a link. It will download yt-dlp (37 MB) from GitHub
> into Murmure's own folder and keep it up to date. Apart from the links you paste, this is the
> only time Murmure reaches the network. YouTube's terms forbid downloading its videos; use this
> for your own personal viewing only, under your responsibility.
> [Download yt-dlp] [Cancel]

Acceptance is persisted (`AppSettings.externalToolsConsented`), so the sheet appears once. Local
files never trigger it.

### 2.2 Installation

`ExternalTools` (MurmureCore) owns `bin/` under `Storage.directory(subfolder: "bin")`. Install:
`URLSession` download with real byte progress (`Content-Length` is known), SHA-256 of the received
file recorded in `bin/yt-dlp.json` with the release tag and date, `chmod 755`, defensive removal of
the `com.apple.quarantine` attribute (a `curl` fetch does not set it, a quarantine-aware fetch
might), then a `--version` run that must succeed within 30 s. A failed check removes the file and
reports. Apple Silicon only, checked by `uname -m`; Intel Macs get a clear message.

### 2.3 Updates

Before a URL job, if the last successful update check is older than 24 hours, run `yt-dlp -U` with
a 60 s timeout and record the time (`AppSettings.ytDlpLastUpdateCheck`). Failure to update is not
fatal for the job. A job that fails with an extractor error offers "Update yt-dlp" as its action.

### 2.4 Running the tool

`Subprocess` (MurmureCore): wraps Foundation `Process`, runs with a restricted environment
(`PATH=/usr/bin:/bin`, `HOME`), streams stdout and stderr line by line as an `AsyncStream`,
supports cancellation by `terminate()` then `kill` after 5 s. Every yt-dlp invocation carries a
fixed cost of about 10 s (PyInstaller unpacking, measured), so the number of invocations per job
is kept to one for the download itself.

Fetch command, one invocation:

```
yt-dlp --no-playlist --newline
       --progress-template "download:MURMURE %(progress._percent_str)s %(progress.downloaded_bytes)s %(progress.total_bytes_estimate)s"
       --print before_dl:title --print before_dl:duration --print before_dl:webpage_url
       -f "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]"
       -o "<jobdir>/media.%(ext)s" <url>
```

Opus/WebM is never accepted (Core Audio cannot decode it). Pure parsers, tested on the lines
captured in spike S1: `YtDlpProgress.parse(line:)` (tolerates `Unknown`, `NA`, padded percentages)
and `YtDlpFailure.classify(stderr:)` into: `toolMissing`, `jsRuntimeRequired`, `signInRequired`
(bot check), `unsupportedURL`, `extractorError` (likely stale), `network`, `unknown`. Each class
maps to one user-facing message and one action (§4.4).

## 3. Pipeline and storage (lot T2)

### 3.1 Job model

`TranscriptJob`: `id`, `source` (`.file(URL)` or `.url(URL)`), `requestedLanguage` (`String?`, nil
means detect), `state`. States: `queued`, `fetching(fraction, bytes)`, `extractingAudio`,
`transcribing(fraction)`, `completed(transcriptID)`, `failed(TranscriptFailure)`, `cancelled`.
Transitions are a pure state machine tested in isolation.

`TranscriptPipeline` is an actor with a FIFO queue and at most one running job. It depends on
protocols: `MediaFetching` (yt-dlp implementation), `AudioExtracting` (AVFoundation
implementation), `LongFormTranscribing` (WhisperKit implementation), `TranscriptStoring`. Tests
drive it with fakes.

### 3.2 Sources and limits

Local files accepted by extension and by `AVAsset` readability: `mp3`, `m4a`, `aac`, `wav`, `aiff`,
`mp4`, `m4v`, `mov`. `mkv`, `webm`, `ogg`, `opus` are refused up front with "This container cannot be
decoded on macOS; convert it to mp4 or m4a first". URLs: any `http(s)` URL is handed to yt-dlp;
YouTube and X are the named, tested targets. Duration limit 4 hours (16 kHz float audio is held in
memory by WhisperKit: about 3.8 MB per minute, so under 1 GB at the limit).

### 3.3 Audio extraction

`AVAssetReader` on the first audio track, output `kAudioFormatLinearPCM`, 16 kHz, mono, Float32,
written as `<jobdir>/audio.wav`. Used for local files and for the fetched `m4a` alike, so the
transcription stage always receives the same shape and the true duration is known before decoding.

### 3.4 Long-form transcription

`WhisperKitEngine.transcribeLongForm(wav:, language:, progress:)` on the already-loaded model (the
same instance the dictation uses; loading a second copy is not needed and would compete for the
Neural Engine). `DecodingOptions`: `chunkingStrategy: .vad`, `skipSpecialTokens: true`,
`wordTimestamps: false`, `detectLanguage` when the language is nil, library defaults for the three
hallucination thresholds and for `concurrentWorkerCount`, no vocabulary prompt. Spike S2 measured
19.9× real time on 41 minutes of French with zero repetition incidents.

Progress: the WhisperKit callback fires per decoded token; the engine derives the fraction from the
highest segment end time seen so far over the known duration and forwards it at most twice a
second. Cancellation uses Swift task cancellation, which WhisperKit 1.1.0 checks between windows;
the job is marked cancelled and any late result is discarded.

Segments are grouped into paragraphs for display and export: a new paragraph starts when the gap
between two segments exceeds 1.5 s or when the running paragraph exceeds 60 s. Segment rows are
stored as produced; paragraphs are derived, so the rule can change without a migration.

### 3.5 Dictation is suspended while a job transcribes

`AppState.dictationSuspension: DictationSuspension?` with a reason
(`.transcribingFile(progress)`). While set, every dictation hotkey press is refused and the notch
shows a dedicated phase, `NotchPhase.suspended(DictationSuspension)`, with the sentence
"Transcribing a file (42 %). Dictation resumes when it is done" for two seconds; the menu bar item
shows the same reason. Fetching and extraction do not suspend dictation, only the transcription
stage. Conversely a job does not start its transcription stage while a dictation is in flight; it
waits for the pipeline to be idle (the `DictationController` exposes an idle signal, the job polls it
every 500 ms with a 10-minute ceiling, after which it proceeds anyway).

### 3.6 Storage

Same SQLite database, migration `v4-transcripts`:

- `transcript`: `id` (UUID text), `createdAt`, `sourceKind` (`file`/`url`), `sourceLocation` (the URL
  string or the original file path), `title` (from yt-dlp or the file name), `durationSeconds`,
  `language` (detected or requested), `sttModel`, `status` (`completed`/`failed`), `failureMessage`,
  `transcribeSeconds`.
- `transcript_segment`: `transcriptID`, `index`, `startSeconds`, `endSeconds`, `text`, primary key
  (`transcriptID`, `index`), foreign key with cascade delete.

No automatic purge; `RetentionPurge` does not touch these tables, and a test pins that. Deletion is
manual from the pane. The job directory under `Storage.directory(subfolder: "transcripts-tmp")`
(fetched media and extracted WAV) is deleted when the job ends, whatever the outcome; leftovers from
a crash are removed at launch.

## 4. Pane (lot T3)

### 4.1 Sidebar

`WindowSection.transcripts` placed right after `.history`, `.material` group, title "Transcripts",
symbol `text.badge.play` or the nearest SF Symbol. `TranscriptsLayout` constants in MurmureCore.

### 4.2 Master

Above the list: a text field "Paste a YouTube or X link" with a "Transcribe" button, a drop zone
"or drop an audio or video file" (also accepts a file picked through a button), and a language popup
("Same as Voice mode" default, then the languages known to `LanguageOptions`, then "Detect
automatically"). Submitting with an unconsented tool opens the consent sheet (§2.1).

List rows, newest first: title (or the URL host while the title is unknown), a source glyph
(`play.rectangle` for URLs, `doc` for files), duration, date, and on the right either a progress
ring with the stage name or a status badge. Failed jobs stay in the list with their failure until
dismissed.

### 4.3 Detail

Header: title, source (clickable URL or file path), duration, date, model, language. Body:
paragraphs with a timestamp gutter `mm:ss` (or `h:mm:ss` past an hour). Clicking a paragraph copies
its text to the clipboard with a brief "Copied" confirmation. For URL sources a small "Open at this
time" control next to each timestamp opens the page in the default browser with the time
parameter (`&t=754s` for YouTube; for other hosts, the plain URL).

Toolbar: "Copy all" (plain text, paragraphs separated by blank lines, no timestamps), "Export
Markdown" (a save panel; the file carries title, source, date, duration, model, then one paragraph
per block prefixed by its timestamp in bold), "Delete" (confirmation alert, then cascade delete).

### 4.4 Failure messages and actions

| Class | Message | Action |
|---|---|---|
| `toolMissing` | yt-dlp is not installed yet | Download (consent sheet) |
| `jsRuntimeRequired` | This video needs a JavaScript runtime to be fetched | Install Deno (consent sheet) |
| `signInRequired` | The site asks for a sign-in to serve this video; Murmure does not send cookies | Try again later |
| `extractorError` | The site changed and yt-dlp could not read it | Update yt-dlp |
| `unsupportedURL` | No media found at this link | none |
| `network` | Could not reach the site | Retry |
| unsupported container | This container cannot be decoded on macOS | none |
| too long | Longer than 4 hours | none |

## 5. Verification

MurmureCore tests, XCTest:

- `YtDlpProgressTests`, `YtDlpFailureTests`: parsers on the spike S1 lines and on synthetic
  variants.
- `SubprocessTests`: a shell script in a temp dir that prints lines with delays; streaming order,
  exit code, cancellation, restricted environment.
- `ExternalToolsTests`: install against a local file URL served from a temp dir (no network in
  tests), checksum recorded, a corrupt download rejected, `--version` check using a fake script.
- `TranscriptJobTests`: state machine transitions and refused transitions.
- `TranscriptPipelineTests`: with fakes, FIFO order, one job at a time, media deleted on success
  and on failure, suspension set only during transcription, wait for dictation idle, cancellation at
  each stage.
- `AudioExtractorTests`: an `afconvert`-generated tone in `m4a` and `mp4` extracted to 16 kHz mono
  with the expected duration; `mkv` refused.
- `ParagraphGroupingTests`: gap and length rules.
- `TranscriptStoreTests`: round-trip, cascade delete, `RetentionPurge` leaves the tables alone.
- `TranscriptsLayoutTests`.

Real end-to-end, run by an agent with the ANE warning given to Louis first: a CLI harness in
`benchmark/` drives the real `TranscriptPipeline` with the real yt-dlp (installed into a temp
`bin/`, never into the live folder), on one public YouTube URL and one local `m4a`, with the turbo
model loaded from the live models folder read-only; the report records fetch time, extraction time,
transcription time and the first paragraphs. App target: `BUILD SUCCEEDED`, then Louis's eye-gate on
consent sheet, progress, detail view, export and the suspension message.

## 6. Security and privacy notes

- The fetched media and the WAV never leave the job directory and are deleted at job end.
- `Subprocess` runs yt-dlp with a minimal environment and never inherits the app's environment.
- No cookies, no credentials, nothing read from browsers.
- Transcript text is stored unencrypted like dictations; it is the user's own content.

## 7. Lots

- T1: `Subprocess`, `YtDlpProgress`, `YtDlpFailure`, `ExternalTools`, consent sheet, settings keys.
- T2: `TranscriptJob`, `TranscriptPipeline`, `AudioExtractor`, `transcribeLongForm`, migration v4,
  `TranscriptStore`, `DictationSuspension` with notch phase and hotkey refusal, launch cleanup.
- T3: `WindowSection.transcripts`, `TranscriptsLayout`, pane views and model, export, open at time,
  delete, failure actions, end-to-end harness run.

## 8. Open items

- Deno release pinning and its own `--version` check: settled in T1 when the first
  `jsRuntimeRequired` fixture is captured (none was met during the spike).
- Whether a failed-then-updated yt-dlp should retry the job automatically (V1: the user presses
  Retry).

## 9. Divergences from the 2026-08-31 spec §8

1. Results no longer land in History: they get their own pane and tables (decided 2026-09-09).
2. yt-dlp is downloaded and updated by Murmure after consent, instead of asking the user to install
   it with Homebrew (decided 2026-09-09; a user without Homebrew was the deciding case).
3. The model is the already-loaded dictation model (turbo) instead of `large-v3`: spike S2 showed
   turbo's French quality on long-form is good with zero repetition, a second model would double
   the download and compete for the Neural Engine, and the time-per-file matters more than the
   2026-08-31 note assumed. To be confirmed by Louis at spec review.
