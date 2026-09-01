#!/usr/bin/env bash
# Build Murmure from this checkout and install it at ONE stable path.
#
# Why a stable path matters, and why this script exists: macOS ties microphone
# and Accessibility permission to the app's LOCATION. An app run straight out of
# DerivedData moves every time a verification build runs elsewhere, so macOS sees
# a different app each time and asks again -- which once produced a stream of
# permission prompts. It also lets a stale build linger under a sibling hash, and
# a glob over DerivedData then launches SEVERAL copies at once, which fight over
# the microphone and the ⌥Space registration.
#
# Usage: ./scripts/install.sh        (quits a running Murmure first)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Applications/Murmure.app"
DD="$ROOT/.build/xcode"

cd "$ROOT"
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)"; exit 1; }
xcodegen generate >/dev/null

echo "Building $(git rev-parse --short HEAD)…"
xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug \
    -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO >/dev/null

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
