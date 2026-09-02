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

### When something is wrong

```sh
./scripts/doctor.sh
```

Every failure in this file was found once by typing ad-hoc commands and knowing what to look for.
`doctor.sh` is that list, with the remedy attached to each line: the missing codesigning
certificate, a half-downloaded Whisper variant, a mode pointing at a model nobody pulled, an
`api`/`instructions` pair that cannot work, a copy of the app running out of DerivedData. It is
**read-only** — it never writes, pulls, or launches anything — so it is safe to point at a machine
that is working. Exit status is 0 when nothing failed.

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

Both shipped modes run on what this table fetches, and nothing else. That is the point of the
table: an earlier build shipped two more modes — `Message` and `Email` — set to
`gemma4:12b-it-qat`, a separate 7.2 GB pull `bootstrap.sh` does **not** do, so on every machine
installed the documented way they refined nothing and pasted the raw transcript without saying so.
They were removed rather than repointed. `gemma4:12b-it-qat` is still the model to reach for if you
want a mode that *rewrites* rather than cleans — see *Switching a mode to a different refiner* —
but that is now a pull you choose. **On a 16 GB machine, think before you pull it** — see *Memory*,
below.

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

### The wait `bootstrap.sh` now pays for you, once per machine

Not "a little slower", and not "several minutes" either — both were too soft. Once the model is on
disk, macOS still has to compile it for this machine's neural engine, and that compilation is
almost all of what a first run costs:

| | |
|---|---|
| Observed on a real fresh install | **423 s** — `transcriptionSeconds = 423.47`, read out of the history afterwards |
| Argmax, same variant, M4 Pro 48 GB | **440 s** |
| Argmax, same variant, M2 Pro 32 GB | **560 s** |
| Every load after the first | **3–5 s** |

([WhisperKit #309](https://github.com/argmaxinc/WhisperKit/issues/309).) So it is what this model
variant costs, not what a modest machine costs — the Mac this project was written on pays it too.
While it runs, `ANECompilerService` holds **100 % CPU**, load average goes above **40** and the whole
machine feels slow; Murmure itself sits at 2 %, waiting. `sample` on the process shows the thread
parked in `MLE5ProgramLibrary.prepareAndReturnError` for 2046 samples out of 2046 — nothing at all
distinguishes it from a crash.

It happens **once per machine**, and `bootstrap.sh` now does it as its last step, where you are
already waiting, rather than leaving it to your first dictation, where you are waiting for a
sentence. `^C` there if you would rather not: the install is complete by that point, nothing is left
half-written, and the first dictation pays it instead.

**Quitting during it throws it away.** The compilation does not resume — the person who installed
Murmure on a second Mac quit twice without knowing, and turned seven minutes into a perceived half
hour. That is why the app says `Loading model, don't quit` and not just `Loading model`, and why
that wait is worth sitting through. It is not a hang. Every later dictation starts immediately.

---

## Memory, measured

Measured 2026-09-01 on an M4 Pro, one model resident at a time, sampling `llama-server` RSS every
50 ms (`benchmark/v3_measure_ram.py`, raw data in `benchmark/ram-v3*.json`).

| Configuration | Resident |
|---|---|
| `Prompt` — s1-mini @ `num_ctx` 4096 + Whisper | **~2.6 GB** |
| a mode repointed at gemma4 12B + Whisper | **~10.2 GB** |

**A GGUF file's size is not its memory footprint.** s1-mini is 484 MB on disk and 1.54 GB resident
at `num_ctx: 8192` — the KV cache dominates, because the weights are small. Lowering `num_ctx` is a
real lever on s1-mini (0.84 GB at 2048) and does nothing on gemma, which uses sliding attention.

So on a 16 GB machine `Prompt` is comfortable and a 12B refiner is not, especially with other work
open. That number is the other half of why nothing ships pointing at gemma. Pointing a mode at it
is a mode-file edit and not a code change — but it is **three** fields, not one. See below.

---

## Switching a mode to a different refiner

The mode files are hand-editable, in `~/Library/Application Support/Murmure/modes/*.json`. Three of
their fields are correlated, and changing `llm.model` on its own produces a mode that still
validates, still runs, and quietly inserts the **raw transcript**:

| | `s1-mini` | `gemma4:12b-it-qat` |
|---|---|---|
| `llm.model` | `hf.co/superwhisper/s1-mini-GGUF:Q4_K_M` | `gemma4:12b-it-qat` |
| `llm.api` | `"s1"` — `/api/generate` with `raw: true` | `"chat"` — `/api/chat` |
| `instructions` | a **control line**: `[Context: general]` | prose |

**Change `llm.model` and leave `llm.api`** and the call goes to the wrong endpoint. s1-mini cannot
be driven through `/api/chat` at all: measured, it answers with **empty content**, because the model
opens its turn with a `<think>` block and Ollama's chat layer takes that for reasoning and keeps it
(`OllamaS1.swift`). Nothing reports this — the refinement comes back unusable and the raw transcript
is inserted by design.

**Change `llm.api` to `"s1"` and leave prose in `instructions`** and `Mode.validate` returns
`instructionsAreNotControlFields`, the mode is reported unusable, and again the raw transcript is
inserted. That refusal is not pedantry: on the v3 probe a sentence appended to the control line came
back **verbatim at the top of the cleaned text** on 1 fixture in 4 — your dictation with someone
else's words pasted into it.

### The script that writes all three

```sh
./scripts/set-refiner.sh <mode-key> <model> [--api s1|chat] [--instructions TEXT] [--dry-run]
```

It refuses the combinations `Mode.validate` refuses, warns about the ones that validate and are
still wrong, and copies the file aside before writing. `MURMURE_MODES_DIR` points it at a copy.

Pointing `Prompt` at the rewriting model — the escape hatch `Mode.swift` names, and the reason the
`chat` dialect is still supported now that no mode ships using it:

```console
$ ./scripts/set-refiner.sh prompt gemma4:12b-it-qat --api chat --instructions "$(cat rewrite.txt)"
prompt.json

  before
    model         "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"
    api           "s1"
    instructions  "[Context: general]"

  after
    model         "gemma4:12b-it-qat"
    api           "chat"
    instructions  "You turn dictated text into a short Slack message. The input is a…"

  written   ~/Library/Application Support/Murmure/modes/prompt.json
  backup    ~/Library/Application Support/Murmure/modes/prompt.json.20260902T104901.bak
```

Omit the prompt and it refuses, because a chat model is driven by prose and there is nothing to
invent it from:

```console
$ ./scripts/set-refiner.sh prompt gemma4:12b-it-qat --api chat
refused  switching to "chat" leaves a control line where a written prompt has to go
```

Murmure reads the modes at launch, so quit and reopen it afterwards.

### The control line is `[Context: general]`, and nothing else

**Do not copy the control line out of `benchmark/`.** `run_benchmark_v2.py` uses

```python
S1_CONTROL = "[Styling: semi-casual] [Structure: prose] [Context: general]"
```

which is what the grid *measured*, not what ships. Adding `[Styling: …]` — which the model card
presents as the normal way to use the model — **drops sentence capitalisation from 96 % to 29 %**
across the same 48 real dictations, and `[Styling: casual]` is the arm where the runaway repetitions
behind `OllamaS1.repeatPenalty` were found (a 44-word dictation answered with 1 402 words of the
same fragment). Nothing in the app warns about it; the output is simply worse, invisibly.
`set-refiner.sh` warns when you pass a field beyond `[Context: …]`. Every field added there is a
field to re-measure.

The one cost of s1-mini that has no setting behind it, recorded in `Mode.swift` so that whoever
edits the file sees it: **sentences get merged** — 9 of those 48 dictations come back with fewer
sentences than they went in, the widest a 416-word passage going from 27 down to 22. A mode that
cannot afford that is a mode to point back at `gemma4:12b-it-qat` with `--api chat`.

---

## Where your data lives

`~/Library/Application Support/Murmure/`

| | |
|---|---|
| `modes/*.json` | the modes, hand-editable |
| `murmure.sqlite` | history — transcript, refined text, mode, models, timings, target app |
| `recordings/*.wav` | the audio |
| `models/` | Whisper downloads |

Nothing leaves the machine, and what stays on it is now bounded: **audio goes after 3 days, text
after 30, and the rows are kept indefinitely** — a dictation whose text has expired still says it
happened, when, how long it took and through which mode. The purge runs at launch and every six
hours after, off every cutoff computed from the data's own timestamps rather than from a record of
when it last ran, so a Mac that was shut for a week purges the week on the next launch instead of
skipping it. The audio half sweeps `recordings/` as well as the rows, and it has to: on this
machine 122 of 148 WAVs — 614 MB of 731 — were recorded before history existed, so no row names
them and a database-driven purge would never have reached a byte. **A first run therefore deletes
every `.wav` sitting directly in `recordings/` whose file is more than three days old, whether or
not the database has ever heard of it** — but never one a row still points at and still considers
current, however old the file itself looks. On this machine today that comes to nothing at all:
every recording here was made in the last 40 hours. Four days from now it is all 150 of them.

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
