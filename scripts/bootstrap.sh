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

for tool in xcodegen huggingface-cli; do
    if command -v "$tool" >/dev/null; then
        echo "    $tool: already installed"
    else
        echo "    $tool: installing"
        brew install "$tool"
    fi
done

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
    huggingface-cli download "$WHISPER_REPO" \
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
# 5. What is left, which is only the things macOS will not let a script do
# ---------------------------------------------------------------------------

step "Done -- two things only you can do"

cat <<'EOF'
    1. Launch it:  open ~/Applications/Murmure.app
       It has no Dock icon by design; it lives in the menu bar.

    2. Press ⌥Space and speak. macOS will ask for the microphone once, and Murmure
       will ask for Accessibility once (pasting into another app means sending it a
       keystroke). Both are one-time, and both stick -- provided install.sh found a
       codesigning identity. If it warned that it did not, open Xcode, sign in under
       Settings -> Accounts, and run this script again: without an identity macOS
       treats every rebuild as a different app and revokes Accessibility silently.

    The first dictation still takes a little longer than the rest: the model is on
    disk now, but macOS compiles it for this machine's neural engine on first load.
EOF
