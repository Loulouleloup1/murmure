#!/usr/bin/env bash
# Build Murmure from this checkout and install it at ONE stable path.
#
# macOS identifies an app for permission purposes by TWO things, and this script
# has to hold both steady or the microphone and Accessibility grants are lost.
#
# 1. Its LOCATION. An app run straight out of DerivedData moves every time a
#    verification build runs elsewhere, so macOS sees a different app each time
#    and asks again -- which once produced a stream of permission prompts. It
#    also lets a stale build linger under a sibling hash, and a glob over
#    DerivedData then launches SEVERAL copies at once, which fight over the
#    microphone and the ⌥Space registration.
#
# 2. Its CODE SIGNATURE. This is the one that was missed the first time round.
#    An ad-hoc signature (CODE_SIGNING_ALLOWED=NO) has no stable identity: its
#    code directory hash is derived from the binary, so EVERY rebuild produces
#    what macOS considers a different app, and it silently revokes Accessibility.
#    The symptom is the worst kind -- dictation records and transcribes normally,
#    then the paste does nothing and the menu bar shows a warning. Signing with a
#    real identity keys the grant to identifier + team instead of to the bytes,
#    so it survives every subsequent rebuild.
#
# Usage: ./scripts/install.sh        (quits a running Murmure first)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Applications/Murmure.app"
DD="$ROOT/.build/xcode"

cd "$ROOT"
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)"; exit 1; }
xcodegen generate >/dev/null

# Any codesigning identity in the keychain will do -- what matters is that it is
# the SAME one on every run, not which one it is. Picked by query rather than
# named here, so this script belongs to no particular machine or developer.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*) \([0-9A-F]\{40\}\) ".*/\1/p' | head -1)"

echo "Building $(git rev-parse --short HEAD)…"
if [ -n "$IDENTITY" ]; then
    echo "Signing with $IDENTITY (permissions survive rebuilds)."
    xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug \
        -derivedDataPath "$DD" build \
        CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual >/dev/null
else
    # Said out loud rather than fallen back to in silence: this build works, but
    # macOS will ask for microphone and Accessibility again after every rebuild.
    echo "WARNING: no codesigning identity found -- falling back to ad-hoc."
    echo "         Permissions will have to be granted again after each rebuild."
    xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug \
        -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO >/dev/null
fi

BUILT="$DD/Build/Products/Debug/Murmure.app"
[ -d "$BUILT" ] || { echo "build produced no app at $BUILT"; exit 1; }

# Quit rather than kill: a running dictation gets to finish writing its WAV.
if pgrep -f "Murmure.app/Contents/MacOS/Murmure" >/dev/null; then
    echo "Quitting the running Murmure…"
    osascript -e 'quit app "Murmure"' 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -f "Murmure.app/Contents/MacOS/Murmure" >/dev/null || break
        sleep 0.5
    done
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"
echo "Installed at $DEST"
echo "Launch it yourself:  open \"$DEST\""
