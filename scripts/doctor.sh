#!/usr/bin/env bash
# Check a Murmure install and, for anything that is wrong, name the fix.
#
# Every problem a real first install hit was found by typing ad-hoc commands and knowing what to
# look for: `security find-identity` answering "0 valid identities", a mode pointing at a model
# nobody had pulled, an app running out of DerivedData under a hash that changed. None of those
# announce themselves -- the app starts, records, transcribes, and then does the wrong thing
# quietly. This script is the list of those commands, with the remedy attached to each one, so
# that finding them takes no expertise and no memory.
#
# It is READ-ONLY, and that is a design constraint rather than an omission. A doctor that also
# repairs is a doctor nobody dares point at a machine that is working; this one can be run on
# Louis's daily driver mid-sentence. It never writes, never pulls, never launches the app, and
# never touches ~/Library/Application Support/Murmure -- it only reads it.
#
# Usage: ./scripts/doctor.sh
#        MURMURE_MODES_DIR=/some/copy ./scripts/doctor.sh   (to check a modes folder elsewhere)
#        MURMURE_SUPPORT_DIR=/some/copy ./scripts/doctor.sh (to check a whole support folder elsewhere)
#
# Exit status: 0 if nothing FAILED (warnings do not fail), 1 otherwise.
set -euo pipefail

# Both overridable for the same reason the stores in MurmureCore take their location as a
# parameter: a check that can only ever be pointed at Louis's real folder is a check whose
# failure branch nobody has ever seen run.
SUPPORT="${MURMURE_SUPPORT_DIR:-$HOME/Library/Application Support/Murmure}"
MODES_DIR="${MURMURE_MODES_DIR:-$SUPPORT/modes}"
APP="$HOME/Applications/Murmure.app"

# WhisperKit's own layout, spelled the same way `bootstrap.sh` writes it and
# `WhisperKitEngine.dictationModel` names it. `openai_whisper-large-v3-v20240930_turbo` IS
# large-v3-turbo.
WHISPER_VARIANT="openai_whisper-large-v3-v20240930_turbo"
WHISPER_DIR="$SUPPORT/models/models/argmaxinc/whisperkit-coreml/$WHISPER_VARIANT"

failures=0
warnings=0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mOK\033[0m    %s\n' "$1"; }
warn() { warnings=$((warnings + 1)); printf '    \033[33mWARN\033[0m  %s\n' "$1"; }
bad()  { failures=$((failures + 1));  printf '    \033[31mFAIL\033[0m  %s\n' "$1"; }
# The remedy always follows the line that failed, indented under it, because a red line with the
# fix somewhere else in the output is a red line someone reads and then goes and asks about.
fix()  { printf '          \033[2m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. The machine and the tools
# ---------------------------------------------------------------------------

step "The machine and the tools"

if [ "$(uname -s)" != "Darwin" ]; then
    bad "not macOS -- Murmure is macOS only"
    exit 1
fi

os_version="$(sw_vers -productVersion)"
if [ "$(echo "$os_version" | cut -d. -f1)" -lt 14 ]; then
    bad "macOS $os_version -- the deployment target is 14.0"
    fix "Update macOS, or build with a lower target and expect the notch card to be unavailable."
else
    ok "macOS $os_version"
fi

if xcodebuild -version >/dev/null 2>&1; then
    ok "Xcode $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
else
    bad "xcodebuild does not run"
    fix "Install Xcode from the App Store and OPEN IT ONCE -- the licence prompt and the"
    fix "first-launch component install both block xcodebuild until they are done."
fi

# `hf` and `huggingface-cli` are the same tool either side of a rename that broke a real install:
# huggingface_hub 1.x dropped the `huggingface-cli` binary and the Homebrew formula is now `hf`.
# A machine set up before the rename still has the old name, which is why this was invisible for
# a long time. Either one is fine; neither is only a problem before the model is downloaded.
if command -v hf >/dev/null || command -v huggingface-cli >/dev/null; then
    ok "Hugging Face CLI present"
elif [ -f "$WHISPER_DIR/config.json" ]; then
    ok "Hugging Face CLI absent, but the model it fetches is already on disk"
else
    bad "no Hugging Face CLI, and no transcription model on disk"
    fix "brew install hf   (the formula was renamed from huggingface-cli)"
fi

if command -v xcodegen >/dev/null; then
    ok "xcodegen present"
else
    warn "xcodegen absent -- install.sh cannot regenerate Murmure.xcodeproj"
    fix "brew install xcodegen"
fi

# ---------------------------------------------------------------------------
# 2. The codesigning identity -- the one that blocked a real first install
# ---------------------------------------------------------------------------

step "Codesigning identity"

# macOS keys a permission grant to the app's code signature as well as its location. An ad-hoc
# signature derives its identity from the binary, so EVERY rebuild is a different app and
# Accessibility is silently revoked: dictation records and transcribes normally, then the paste
# does nothing. Any identity will do -- what matters is that one exists and stays the same.
identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*) \([0-9A-F]\{40\}\) "\(.*\)"$/\1 \2/p' || true)"
if [ -n "$identities" ]; then
    ok "$(printf '%s\n' "$identities" | wc -l | tr -d ' ') identity/identities available"
    printf '%s\n' "$identities" | sed 's/^/          /'
else
    bad "no codesigning identity -- every rebuild will revoke Accessibility silently"
    fix "Signing in to Xcode with an Apple ID is NOT enough. This is the trap: the account"
    fix "shows as signed in while \`security find-identity\` still answers 0 valid identities."
    fix "The certificate is a SECOND, separate step:"
    fix "  Xcode -> Settings -> Accounts -> your Apple ID -> Manage Certificates… -> + ->"
    fix "  Apple Development"
    fix "Or let the build ask for one:  DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/install.sh"
fi

# ---------------------------------------------------------------------------
# 3. Which copy of the app is installed, and which one is running
# ---------------------------------------------------------------------------

step "The installed app"

if [ -d "$APP" ]; then
    ok "installed at $APP"
else
    bad "no app at $APP"
    fix "./scripts/install.sh   (it builds and copies to that ONE stable path)"
fi

# An app run straight out of DerivedData moves every time a verification build runs elsewhere, so
# macOS sees a different app and asks for the microphone again. Worse, a stale build lingers under
# a sibling hash and a glob over DerivedData launches SEVERAL copies at once, which then fight over
# the microphone and the ⌥Space registration -- one of them wins and the other looks broken.
# `pgrep -x Murmure` and not `pgrep -f <path>`: -f matches any process whose COMMAND LINE holds
# the string, which caught this script's own shell and every other one that happened to mention
# the path -- two /bin/zsh reported as rival copies of Murmure the first time this ran. The
# executable path is then read from the process itself, which is the thing the check is about.
running="$(pgrep -x Murmure 2>/dev/null || true)"
if [ -z "$running" ]; then
    warn "Murmure is not running -- nothing to say about which copy has the microphone"
    fix "open \"$APP\""
else
    count=0
    stray=0
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        count=$((count + 1))
        path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        case "$path" in
            "$HOME/Applications/"*) ;;
            *) stray=$((stray + 1)); bad "running from $path"
               fix "That copy moves on every build, so macOS treats it as a new app and asks"
               fix "for permissions again. Quit it and run ./scripts/install.sh, then open"
               fix "$APP" ;;
        esac
    done <<EOF
$running
EOF
    if [ "$count" -gt 1 ]; then
        bad "$count copies of Murmure are running -- they fight over the microphone and ⌥Space"
        fix "Quit them all (osascript -e 'quit app \"Murmure\"', repeat), then open $APP"
    elif [ "$stray" -eq 0 ]; then
        ok "one copy running, from ~/Applications"
    fi
fi

# Not a failure by itself: these only bite when something launches them. Said out loud because
# they are invisible otherwise, and because the glob that launches them is a plausible thing to
# type.
stale="$(ls -d "$HOME/Library/Developer/Xcode/DerivedData/"Murmure-*/Build/Products/Debug/Murmure.app 2>/dev/null || true)"
if [ -n "$stale" ]; then
    warn "$(printf '%s\n' "$stale" | wc -l | tr -d ' ') stale build(s) under DerivedData"
    printf '%s\n' "$stale" | sed 's/^/          /'
    fix "Harmless while nothing opens them. install.sh builds into .build/xcode inside the"
    fix "checkout for exactly this reason. Delete them if you want the ambiguity gone."
fi

# ---------------------------------------------------------------------------
# 4. The transcription model -- the mandatory one
# ---------------------------------------------------------------------------

step "Transcription model (Whisper large-v3-turbo)"

# Two files rather than one folder: an interrupted download leaves the directory in place with
# most of it missing, and `config.json` alone is 3 kB of the 1.6 GB. `AudioEncoder.mlmodelc` is
# the big one, so requiring both is what tells a real install apart from a stopped one. Without
# them the app sits on "transcribing" while it downloads the model itself -- the failure that
# looked exactly like a hang on a second machine.
if [ -f "$WHISPER_DIR/config.json" ] && [ -d "$WHISPER_DIR/AudioEncoder.mlmodelc" ]; then
    ok "$WHISPER_VARIANT present ($(du -sh "$WHISPER_DIR" 2>/dev/null | cut -f1))"
else
    bad "$WHISPER_VARIANT is missing or incomplete under $WHISPER_DIR"
    [ -f "$WHISPER_DIR/config.json" ] || fix "config.json absent"
    [ -d "$WHISPER_DIR/AudioEncoder.mlmodelc" ] || fix "AudioEncoder.mlmodelc absent (this is the 1.6 GB half)"
    fix "./scripts/bootstrap.sh   (it downloads this before the app can ask for it)"
fi

# An `hf download` killed halfway leaves these behind. They are why a folder can look present and
# still be short of a gigabyte.
incomplete="$(find "$SUPPORT/models" -name '*.incomplete' 2>/dev/null | head -5 || true)"
if [ -n "$incomplete" ]; then
    warn "interrupted downloads left behind:"
    printf '%s\n' "$incomplete" | sed 's/^/          /'
    fix "Re-run ./scripts/bootstrap.sh -- hf resumes."
fi

# ---------------------------------------------------------------------------
# 5. The modes, and the refiner each one points at
# ---------------------------------------------------------------------------

step "Modes ($MODES_DIR)"

# Parsed with python3 rather than jq: jq only ships with macOS from 15, and python3 comes with the
# Command Line Tools that Xcode has already required by the time anyone runs this.
PY=python3
command -v python3 >/dev/null || PY=/usr/bin/python3

if [ ! -d "$MODES_DIR" ]; then
    bad "no modes folder"
    fix "It is written on first launch. open \"$APP\" once, then re-run."
elif [ -z "$(ls "$MODES_DIR"/*.json 2>/dev/null || true)" ]; then
    bad "modes folder holds no *.json"
    fix "open \"$APP\" once -- ModeStore writes the four built-ins on every launch."
else
    # One line per mode, tab-separated, so the shell below decides nothing about JSON. The
    # `instructions` shape is reduced here to the only distinction the rules turn on: whether the
    # text is nothing but bracketed control fields. That scan mirrors
    # `Mode.containsOnlyControlFields` -- a field opens with '[', is not empty, holds no second
    # '[', closes on the first ']', and only whitespace separates two of them.
    #
    # Held in a variable and passed with -c rather than piped straight into a command substitution:
    # bash 3.2, which is the bash macOS ships, cannot parse a here-document nested inside "$( )".
    read -r -d '' MODE_READER <<'PY' || true
import glob, json, os, sys

def only_control_fields(text):
    rest = text.strip()
    while rest:
        if not rest.startswith("["):
            return False
        close = rest.find("]")
        if close < 0:
            return False
        body = rest[1:close]
        if not body or "[" in body:
            return False
        rest = rest[close + 1:].lstrip()
    return True

for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    name = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as handle:
            mode = json.load(handle)
    except Exception as error:                                  # noqa: BLE001
        print("\t".join([name, "UNPARSEABLE", str(error), "", "", "", ""]))
        continue
    llm = mode.get("llm") or {}
    instructions = mode.get("instructions", "")
    if not instructions.strip():
        shape = "empty"
    elif only_control_fields(instructions):
        shape = "control"
    else:
        shape = "prose"
    print("\t".join([
        name,
        "OK",
        str(mode.get("key", "")),
        "true" if llm.get("enabled") else "false",
        str(llm.get("endpoint", "")),
        str(llm.get("model", "")),
        # Absent `api` means chat: every mode file written before s1-mini shipped names a model
        # that speaks /api/chat, and Mode.LLM's hand-written decoder defaults it that way.
        str(llm.get("api", "chat")),
    ]) + "\t" + shape)
PY
    modes_tsv="$("$PY" -c "$MODE_READER" "$MODES_DIR")"

    # Ollama's tag list, fetched once per distinct endpoint the modes actually name, rather than
    # from `ollama list`: the endpoint in the mode file is the one Murmure will call, and a mode
    # pointing at a server that is not there is the same failure as a model that is not pulled.
    tags_for() {
        curl -fsS --max-time 5 "${1%/}/api/tags" 2>/dev/null \
            | "$PY" -c 'import json,sys; print("\n".join(m["name"] for m in json.load(sys.stdin).get("models", [])))' 2>/dev/null \
            || true
    }

    while IFS=$'\t' read -r file status key enabled endpoint model api shape; do
        [ -n "$file" ] || continue

        if [ "$status" = "UNPARSEABLE" ]; then
            bad "$file is not valid JSON: $key"
            fix "ModeStore skips a file it cannot read, so this mode simply is not there --"
            fix "no error, just one fewer mode in the menu. Fix the JSON or delete the file"
            fix "and relaunch: the built-ins are rewritten on every launch."
            continue
        fi

        if [ "$enabled" != "true" ]; then
            ok "$key: refiner off (raw transcript inserted, by design)"
            continue
        fi

        mode_bad=0
        mode_noted=0

        # The endpoint is the SERVER ROOT: the client appends /api/chat or /api/generate itself.
        # A path left here is silently concatenated -- spec §5's own example carried "/v1", which
        # yields /v1/api/chat, a 404, and a client that can only report it as a response it could
        # not read.
        endpoint_bad=0
        case "$endpoint" in
            http://*|https://*) ;;
            *) bad "$key: \"llm.endpoint\" $endpoint is not an http(s) URL"; mode_bad=1; endpoint_bad=1 ;;
        esac
        stripped="${endpoint#*://}"
        case "$stripped" in
            */?*) bad "$key: \"llm.endpoint\" $endpoint must be the server root -- Murmure appends the API path itself"
                  fix "Write http://localhost:11434, not http://localhost:11434/v1"
                  mode_bad=1; endpoint_bad=1 ;;
        esac

        model_missing=0
        [ -n "$model" ] || { bad "$key: \"llm.model\" is empty while \"llm.enabled\" is true"; mode_bad=1; model_missing=1; }

        # The api/instructions agreement, which is the same trap set-refiner.sh exists for.
        if [ "$api" = "s1" ] && [ "$shape" = "prose" ]; then
            bad "$key: \"api\": \"s1\" with prose instructions"
            fix "Mode.validate rejects this (instructionsAreNotControlFields), so the mode is"
            fix "reported unusable and the RAW transcript is inserted. With api s1 the whole"
            fix "interface is bracketed fields: \"[Context: general]\". Measured on the v3 probe,"
            fix "a sentence appended to the control line came back verbatim at the top of the"
            fix "cleaned text on 1 fixture in 4 -- your dictation with someone else's words in it."
            fix "  ./scripts/set-refiner.sh $key $model"
            mode_bad=1
        elif [ "$api" = "chat" ] && [ "$shape" = "control" ]; then
            # Validation accepts this, which is exactly why it needs saying: the mode is declared
            # usable and quietly does the wrong thing.
            warn "$key: \"api\": \"chat\" with a control line for instructions"
            fix "This VALIDATES and still refines nothing useful: a control line sent as a system"
            fix "prompt to /api/chat is not instructions to a chat model. If the model is s1-mini,"
            fix "the api field is what is wrong -- and on /api/chat s1-mini answers EMPTY content,"
            fix "so the raw transcript is inserted."
            fix "  ./scripts/set-refiner.sh $key $model --api s1"
            mode_noted=1
        elif [ "$shape" = "empty" ]; then
            bad "$key: \"instructions\" is empty while \"llm.enabled\" is true"
            mode_bad=1
        fi

        # Is the model actually pulled, on the server this mode names? A mode pointing at an
        # unpulled model refines nothing and inserts the raw transcript, silently -- the app has
        # nothing to show, because Ollama answers a clean 404 and the fallback is by design.
        if [ "$endpoint_bad" -eq 1 ] || [ "$model_missing" -eq 1 ]; then
            continue
        fi

        cache_key="$(printf '%s' "$endpoint" | tr -c 'a-zA-Z0-9' '_')"
        eval "tags=\${TAGS_$cache_key-__unset__}"
        if [ "$tags" = "__unset__" ]; then
            tags="$(tags_for "$endpoint")"
            eval "TAGS_$cache_key=\$tags"
        fi

        if [ -z "$tags" ]; then
            bad "$key: no answer from $endpoint"
            fix "Ollama is not running or not reachable there. Start it (open -a Ollama, or"
            fix "\`ollama serve\`) and re-run. Without it this mode inserts the raw transcript."
            mode_bad=1
        else
            # An id with no tag means :latest, the way Ollama itself resolves it.
            want="$model"
            case "$want" in *:*) ;; *) want="$want:latest" ;; esac
            if printf '%s\n' "$tags" | grep -qxF "$want"; then
                if [ "$mode_bad" -eq 0 ] && [ "$mode_noted" -eq 0 ]; then
                    ok "$key: $api -> $model, pulled"
                fi
            else
                bad "$key: model $model is NOT pulled on $endpoint"
                fix "The mode refines nothing and inserts the RAW transcript, with no error"
                fix "anywhere -- Ollama answers 404 and Murmure falls back by design."
                fix "  ollama pull $model"
                mode_bad=1
            fi
        fi
    done <<EOF
$modes_tsv
EOF
fi

# ---------------------------------------------------------------------------
# 6. What is left is what only a human can see
# ---------------------------------------------------------------------------

step "Summary"

if [ "$failures" -eq 0 ]; then
    printf '    \033[32m%s\033[0m\n' "Nothing failed. $warnings warning(s)."
else
    printf '    \033[31m%s\033[0m\n' "$failures failure(s), $warnings warning(s)."
fi

cat <<'EOF'

    Two things this script cannot check, because macOS does not expose them to a script:
      - the microphone grant, and Accessibility (System Settings -> Privacy & Security).
        If dictation records and transcribes and then the paste does nothing, it is
        Accessibility, and the cause is almost always the codesigning identity above.
      - whether ⌥Space actually reached Murmure. Another app holding the same shortcut wins
        silently.
EOF

[ "$failures" -eq 0 ]
