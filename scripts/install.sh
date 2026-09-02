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
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*) \([0-9A-F]\{40\}\) ".*/\1/p' | head -1
}

IDENTITY="$(find_identity)"

# Signing in to Xcode with an Apple ID does NOT issue a certificate, and believing it does is what
# actually blocked a first install: the account was there
# (`defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists` listed it) while
# `security find-identity` still answered "0 valid identities found". The certificate is a second,
# separate step -- and rather than tell someone to go and click it, ask xcodebuild to do it, which
# is what unblocked that machine. DEVELOPMENT_TEAM may be set in the environment; without it
# xcodebuild can still resolve a single-team account on its own.
if [ -z "$IDENTITY" ]; then
    echo "No codesigning identity yet -- asking Xcode to issue one…"
    # shellcheck disable=SC2086
    xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug \
        -derivedDataPath "$DD" -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic \
        ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} build >/dev/null 2>&1 || true
    IDENTITY="$(find_identity)"
    [ -n "$IDENTITY" ] && echo "Xcode issued one."
fi

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
    echo
    echo "         To fix it, in Xcode: Settings -> Accounts -> select your Apple ID"
    echo "         -> Manage Certificates… -> + -> Apple Development, then re-run."
    echo "         Adding the Apple ID alone is NOT enough -- that is the trap: the"
    echo "         account shows as signed in while no certificate exists."
    echo "         If you know your team ID:  DEVELOPMENT_TEAM=XXXXXXXXXX $0"
    xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug \
        -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO >/dev/null
fi

BUILT="$DD/Build/Products/Debug/Murmure.app"
[ -d "$BUILT" ] || { echo "build produced no app at $BUILT"; exit 1; }

# Quit rather than kill: a running dictation gets to finish writing its WAV.
#
# `pgrep -x Murmure` and NOT `pgrep -f <path>`, for the reason doctor.sh already carries: -f matches
# any process whose whole COMMAND LINE holds the string, so a shell that merely mentions the app --
# an `open "$DEST"`, a `cp -R`, this script invoked with the path in an outer command -- is reported
# as a running Murmure. The cost here was invisible rather than fatal: the loop below then never
# breaks, and every install paid a silent ten-second wait for a process that was never running.
#
# The same -f trap cost a benchmark run its whole pipeline on 2026-09-02: a `pkill -f` whose pattern
# also matched the waiting shells that carried it in their own wait condition, so the killer killed
# itself. A pattern that can describe the process doing the matching is the bug, in either direction.
if pgrep -x Murmure >/dev/null; then
    echo "Quitting the running Murmure…"
    osascript -e 'quit app "Murmure"' 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -x Murmure >/dev/null || break
        sleep 0.5
    done
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"
echo "Installed at $DEST"
echo "Launch it yourself:  open \"$DEST\""
