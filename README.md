# Murmure

Local dictation for macOS. Hold ⌥Space, speak, and the text lands in whatever app you were in.
Everything runs on the machine: no cloud, no API keys, no account.

Whisper transcribes, an optional local language model cleans the result up, and the text is pasted
into the frontmost application. There is a notch card on a display that has a notch and a floating
panel on one that does not.

---

## Setting it up on another Mac

```sh
git clone https://github.com/Loulouleloup1/murmure.git
cd murmure
./scripts/bootstrap.sh
```

That is the whole installation. The script checks the tools, **downloads both models**, builds and
installs, and tells you the two things macOS will not let a script do for you. Run it again any time
— it skips whatever is already there.

### The two models, because getting this wrong looks like a crash

Murmure needs **two** models and they are not interchangeable:

| | What | Size | Without it |
|---|---|---|---|
| **Transcription** | Whisper `large-v3-turbo`, from Hugging Face | **1.6 GB** | **nothing works** — the app sits on "transcribing" while it downloads the model itself |
| **Refinement** | `s1-mini` via Ollama | 484 MB | dictation still works; you get the raw transcript instead of a cleaned-up one |

This table exists because an earlier version of this file led with the *refinement* model and left the
transcription one as a footnote about the first run being slow. A fresh install then spent a long
time apparently frozen, doing a 1.6 GB download behind a screen that said "transcribing". The
transcription model is the mandatory one. `bootstrap.sh` fetches it before the app ever asks.

`Message` and `Email` are set to `gemma4:12b-it-qat`, a separate 7.2 GB pull that the script does
**not** do. **On a 16 GB machine, think before you pull it** — see *Memory*, below.

### What has to be there first

The script checks all of these and installs the last two itself:

| | |
|---|---|
| **macOS 14.0** or later | the deployment target |
| **Xcode**, opened once and signed in with your Apple ID | needed to build, and it is what puts a codesigning identity in the keychain — see below |
| **Homebrew** | to install the two tools |
| `xcodegen`, `huggingface-cli` | installed for you |
| **[Ollama](https://ollama.com)** | optional; only refinement needs it |

### Why the codesigning identity matters more than it looks

macOS keys a permission grant to **both** an app's location *and* its code signature. An ad-hoc
signature has no stable identity, so every rebuild looks like a different app and Accessibility is
silently revoked — the app records and transcribes normally and then the paste does nothing.

`install.sh` signs with whatever identity is in your keychain, which keys the grant to the identifier
instead of to the bytes. If it finds none it asks Xcode to issue one for you
(`-allowProvisioningUpdates`), and only warns if that also fails.

**Signing in to Xcode with your Apple ID does not issue a certificate.** This is the trap, and it is
what actually blocked a real install: Xcode listed the account as signed in while
`security find-identity -v -p codesigning` still answered `0 valid identities found`. The
certificate is a second, separate step:

*Xcode → Settings → Accounts → your Apple ID → **Manage Certificates… → + → Apple Development***

or, if you know your team ID, let the script do it:

```sh
DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/bootstrap.sh
```

### Permissions, once

On the first dictation macOS asks for the **microphone**, and Murmure asks for **Accessibility**
(System Settings → Privacy & Security → Accessibility), because pasting into another app means
sending it a keystroke. Both are once, provided the signature above is in order.

### The first dictation is slow, and so is the whole machine while it happens

Not "a little slower" — that wording was measured wrong and is corrected here. The model is on disk
after bootstrap, but macOS compiles it for this machine's neural engine the first time it loads.
Measured on an 8-core Apple Silicon Mac: `ANECompilerService` pinned at 100 % CPU for **several
minutes**, load average above **40**, the whole machine sluggish.

It happens **once per machine**, it is not a hang, and the app shows what it is doing. Every later
dictation starts immediately.

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
