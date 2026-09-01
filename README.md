# Murmure

Local dictation for macOS. Hold ⌥Space, speak, and the text lands in whatever app you were in.
Everything runs on the machine: no cloud, no API keys, no account.

Whisper transcribes, an optional local language model cleans the result up, and the text is pasted
into the frontmost application. There is a notch card on a display that has a notch and a floating
panel on one that does not.

---

## Setting it up on a second Mac

Written from a real second-machine install rather than from memory, so each step says what it is for
and what it costs.

### 1. What has to be there first

| | |
|---|---|
| **macOS 14.0** or later | `project.yml` sets the deployment target |
| **Xcode**, opened once and signed in with your Apple ID | needed to build, and it is what puts a codesigning identity in the keychain — see step 4 |
| **`brew install xcodegen`** | the `.xcodeproj` is generated, not committed |
| **[Ollama](https://ollama.com)** | only if you want the refinement modes; transcription alone does not need it |

### 2. Clone and pull the language model

```sh
git clone https://github.com/Loulouleloup1/murmure.git
cd murmure
ollama pull hf.co/superwhisper/s1-mini-GGUF:Q4_K_M
```

That one model is what the `Prompt` mode uses, and `Prompt` is the mode that matters if you dictate
into terminals and agent prompts. Murmure reaches Ollama at `http://localhost:11434`; nothing else
has to be configured.

`Message` and `Email` are set to `gemma4:12b-it-qat`, which is a separate 7.2 GB pull. **On a 16 GB
machine, think before you pull it** — see *Memory*, below. Transcription works with no model pulled
at all; only refinement fails, and it fails by inserting the raw transcript rather than losing it.

### 3. Build and install

```sh
./scripts/install.sh
```

It generates the project, builds, and installs to `~/Applications/Murmure.app` — one stable path, on
purpose. Then launch it from there, not from Xcode's build folder.

### 4. Why the codesigning identity matters more than it looks

macOS keys a permission grant to **both** an app's location *and* its code signature. An ad-hoc
signature has no stable identity, so every rebuild looks like a different app and Accessibility is
silently revoked — the app records and transcribes normally and then the paste does nothing.

`install.sh` picks whatever codesigning identity is in your keychain (`security find-identity`) and
signs with it, which keys the grant to the identifier instead of to the bytes. If it prints

```
WARNING: no codesigning identity found -- falling back to ad-hoc.
```

then open Xcode, sign in with your Apple ID under *Settings → Accounts*, and run it again. It will
otherwise work, but macOS will ask for microphone and Accessibility again after every single build.

### 5. Permissions, once

On the first dictation macOS asks for the **microphone**, and Murmure asks for **Accessibility**
(System Settings → Privacy & Security → Accessibility) because pasting into another app means
sending it a keystroke. Both are once, provided step 4 went well.

### 6. The first dictation is slow, and only the first

Whisper `large-v3-turbo` (~1.6 GB) downloads on first use and then loads through CoreML, which takes
a while the first time on a given machine. There is a progress surface for it. Later dictations
start immediately.

---

## Memory, measured

Measured 2026-09-01 on an M4 Pro, one model resident at a time, sampling `llama-server` RSS every
50 ms (`benchmark/v3_measure_ram.py`, raw data in `benchmark/ram-v3*.json`).

| Configuration | Resident |
|---|---|
| `Prompt` — s1-mini @ `num_ctx` 4096 + Whisper | **~2.6 GB** |
| `Message` / `Email` — gemma4 12B + Whisper | **~10.2 GB** |

**A GGUF file's size is not its memory footprint.** s1-mini is 484 MB on disk and 1.54 GB resident
at `num_ctx: 8192` — the KV cache dominates, because the weights are small. Lowering `num_ctx` is a
real lever on s1-mini (0.84 GB at 2048) and does nothing on gemma, which uses sliding attention.

So on a 16 GB machine `Prompt` is comfortable and the 12B modes are not, especially with other work
open. Switching `Message` and `Email` to something smaller is a mode-file edit, not a code change:
they live in `~/Library/Application Support/Murmure/modes/*.json`.

---

## Where your data lives

`~/Library/Application Support/Murmure/`

| | |
|---|---|
| `modes/*.json` | the modes, hand-editable |
| `murmure.sqlite` | history — transcript, refined text, mode, models, timings, target app |
| `recordings/*.wav` | the audio |
| `models/` | Whisper downloads |

Nothing leaves the machine. Retention was decided at audio for 3 days and text for 30; the
primitives exist and **the purge that calls them does not yet** — so today nothing is deleted
automatically.

---

## Developing

```sh
cd MurmureCore && swift test      # the whole suite
xcodegen generate                 # regenerate the .xcodeproj after changing project.yml
```

Everything testable lives in the `MurmureCore` package: the app target has no test bundle, so logic
that matters belongs in the package and `Murmure/` stays wiring. Tests never write into
`~/Library/Application Support/Murmure/` — every store takes its location as a parameter with no
default, which is what makes that mechanical rather than remembered.

Plans and decisions are in `docs/plans/`, the design record in `docs/design/`, the spec in
`docs/specs/`.
