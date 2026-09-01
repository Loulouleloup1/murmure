#!/usr/bin/env bash
# Set Murmure up on a machine that has never run it.
#
# Written after a real second-machine install went wrong: the README named the REFINEMENT model
# (s1-mini, 484 MB, pulled with one command) prominently and left the TRANSCRIPTION model (Whisper,
# 1.6 GB, downloaded silently on the first dictation) as a footnote about slowness. The result was
# an app that sat on "transcribing" for a long time and looked broken while it was in fact working.
#
# So this script does not explain the two models -- it installs both, and there is nothing left to
# decide or to read. It is idempotent: run it again and it will skip whatever is already there.
#
# Usage: ./scripts/bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# WhisperKit's own layout, spelled out because we write into it before WhisperKit ever runs.
# `openai_whisper-large-v3-v20240930_turbo` IS large-v3-turbo; the name comes from
# `WhisperKitEngine.dictationModel` and getting it wrong fails later with a confusing
# "model not found".
WHISPER_REPO="argmaxinc/whisperkit-coreml"
WHISPER_VARIANT="openai_whisper-large-v3-v20240930_turbo"
MODEL_BASE="$HOME/Library/Application Support/Murmure/models/models/$WHISPER_REPO"
REFINER_MODEL="hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[33m    %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. The tools
# ---------------------------------------------------------------------------

step "Checking what is installed"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Murmure is macOS only." >&2
    exit 1
fi

os_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$os_major" -lt 14 ]; then
    echo "macOS 14 or later is required (found $(sw_vers -productVersion))." >&2
    exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Xcode is required. Install it from the App Store, open it once, then re-run." >&2
    exit 1
fi

command -v brew >/dev/null || {
    echo "Homebrew is required: https://brew.sh" >&2
    exit 1
}

if command -v xcodegen >/dev/null; then
    echo "    xcodegen: already installed"
else
    echo "    xcodegen: installing"
    brew install xcodegen
fi

# The Hugging Face CLI was RENAMED: the `huggingface-cli` binary is gone from huggingface_hub 1.x
# and the Homebrew formula is now `hf` (with `huggingface-cli` kept only as an old name). A first
# install on a clean machine therefore used to fail here in the worst way -- `brew install
# huggingface-cli` succeeded, installed `hf`, and the next line died on `command not found`.
# Machines set up before the rename still carry the old binary, which is exactly why this was
# invisible on the machine the script was written on. Both names are accepted, new one first.
if command -v hf >/dev/null; then
    HF=hf
elif command -v huggingface-cli >/dev/null; then
    HF=huggingface-cli
else
    echo "    hf: installing"
    brew install hf
    command -v hf >/dev/null && HF=hf || HF=huggingface-cli
fi
echo "    $HF: ready"

# ---------------------------------------------------------------------------
# 2. The transcription model -- the one that was missing on the second machine
# ---------------------------------------------------------------------------

step "Transcription model (Whisper large-v3-turbo, ~1.6 GB)"

if [ -f "$MODEL_BASE/$WHISPER_VARIANT/config.json" ] \
    && [ -d "$MODEL_BASE/$WHISPER_VARIANT/AudioEncoder.mlmodelc" ]; then
    echo "    already present, skipping"
else
    # Downloaded HERE rather than left to the app's first dictation, which is exactly the moment
    # that looked like a hang: a long download behind a screen that said "transcribing".
    echo "    downloading -- several minutes on a first run"
    "$HF" download "$WHISPER_REPO" \
        --include "$WHISPER_VARIANT/*" \
        --local-dir "$MODEL_BASE"
fi

# ---------------------------------------------------------------------------
# 3. The refinement model -- optional, and the script says so rather than failing
# ---------------------------------------------------------------------------

step "Refinement model (s1-mini, 484 MB)"

if ! command -v ollama >/dev/null; then
    warn "Ollama is not installed -- skipping."
    warn "Dictation and transcription will work; the Prompt mode will insert the raw"
    warn "transcript instead of a cleaned-up one. Install from https://ollama.com and"
    warn "re-run this script to add it."
elif ! ollama list >/dev/null 2>&1; then
    warn "Ollama is installed but not running -- start it, then re-run this script."
elif ollama list 2>/dev/null | grep -q "^${REFINER_MODEL%%:*}"; then
    echo "    already pulled, skipping"
else
    ollama pull "$REFINER_MODEL"
fi

# ---------------------------------------------------------------------------
# 4. Build and install
# ---------------------------------------------------------------------------

step "Building and installing"
"$ROOT/scripts/install.sh"

# ---------------------------------------------------------------------------
# 5. The compilation, paid here rather than inside somebody's first sentence
# ---------------------------------------------------------------------------

# The closing instructions, as a function because TWO paths reach them: the ordinary end of the
# script, and a ^C during the model preparation below. That interrupt is not a failed install and
# must not read as one -- everything that makes Murmure work has already happened by this line.
final_notes() {
    step "Done -- two things only you can do"
    cat <<'EOF'
    1. Launch it:  open ~/Applications/Murmure.app
       It has no Dock icon by design; it lives in the menu bar.

    2. Press ⌥Space and speak. macOS will ask for the microphone once, and Murmure
       will ask for Accessibility once (pasting into another app means sending it a
       keystroke). Both are one-time, and both stick -- provided install.sh found a
       codesigning identity. If it warned that it did not, follow the lines it
       printed: signing in to Xcode with an Apple ID is NOT enough on its own, the
       certificate is a separate click (Manage Certificates -> + -> Apple
       Development). Without one, macOS treats every rebuild as a different app and
       revokes Accessibility silently.
EOF
}

# Why this step exists at all, and why it is the LAST one.
#
# The 1.6 GB fetched above is only half of what a first run costs. macOS then compiles the model for
# this machine's neural engine, and THAT is the half that looked like a crash. Measured on a second
# Mac, out of the app's own history: transcriptionSeconds = 423.47, with `sample` on the process
# showing the thread parked in MLE5ProgramLibrary.prepareAndReturnError for 2046 samples out of 2046
# and ANECompilerService holding 100 % CPU while Murmure itself sat at 2 %, waiting. Argmax documents
# the same cost for this exact variant -- 440 s on an M4 Pro 48 GB, 560 s on an M2 Pro 32 GB, then
# 3-5 s on every load afterwards (WhisperKit#309). It is what the variant costs, not what a modest
# machine costs, and the Mac this project was written on pays it too.
#
# The wait is the same length wherever it happens and only one of the two places is bearable: at the
# end of an install you are waiting on purpose, at your first dictation you are waiting for a
# sentence. That is the whole of the argument for these lines.
#
# `--prepare-model` is answered by the app binary before SwiftUI exists (`Launch`, `ModelWarmup`):
# no window, no menu bar item, no microphone, no Accessibility prompt. It loads the model through
# the SAME `WhisperKitEngine` path a dictation uses -- same code, same binary, same signature, same
# store -- so what it compiles here is what the app finds compiled later. A warm-up that opened a
# different configuration would warm nothing and would report that it had.
step "Preparing the model for this machine (once)"

APP="$HOME/Applications/Murmure.app/Contents/MacOS/Murmure"

cat <<'EOF'
    macOS compiles the model for this machine's neural engine the first time it is
    loaded. Measured on a fresh install: 423 s, ANECompilerService at 100 % CPU, the
    whole machine sluggish throughout. Argmax measures 440 s on an M4 Pro 48 GB and
    560 s on an M2 Pro 32 GB for this same variant, then 3-5 s on every load after.
    It happens once per machine.

    ^C is safe: the install above is already complete and nothing here is left
    half-written. It does throw the compilation away though -- quitting during it
    starts it from zero, which is equally true of the app itself later on.
EOF

# Not an error path. A ^C here means "I would rather pay this at the first dictation", which is a
# choice the script has no business overriding and no business punishing: the closing instructions
# are printed either way, and the exit status stays 0 because the install did succeed.
warm_up_interrupted() {
    printf '\n'
    warn "Stopped -- the model is not prepared, and nothing is broken. The install above"
    warn "is complete; the compilation simply starts again from the beginning, either at"
    warn "your first dictation (slow, and the app says \"Loading model, don't quit\" while"
    warn "it happens) or the next time you run this script."
    final_notes
    exit 0
}

if [ ! -x "$APP" ]; then
    warn "No app at $APP -- skipping."
    warn "Run scripts/install.sh, then re-run this script to prepare the model."
else
    trap warm_up_interrupted INT
    # Warned about rather than fatal, for the same reason Ollama's absence is: the app is installed
    # and works, and a failure here costs a slow first dictation and nothing else.
    if ! "$APP" --prepare-model; then
        warn "The model could not be prepared -- the reason is on the line above. Not fatal:"
        warn "the first dictation does it instead, and will be slow while it does."
    fi
    trap - INT
fi

# ---------------------------------------------------------------------------
# 6. What is left, which is only the things macOS will not let a script do
# ---------------------------------------------------------------------------

final_notes
