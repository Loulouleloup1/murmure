#!/usr/bin/env bash
# Point one mode at a different refinement model, changing all THREE fields that have to move
# together.
#
# The README used to say that switching a mode to a smaller model "is a mode-file edit, not a code
# change". That is true and it is the dangerous half of the truth: `llm.model` is one of three
# correlated fields, and editing it alone produces a mode that still validates, still runs, and
# quietly inserts the raw transcript.
#
#   llm.model         the Ollama model id
#   llm.api           "s1" or "chat" -- the WIRE PROTOCOL, not the model. s1-mini cannot be driven
#                     through /api/chat at all: measured, it answers with EMPTY content, because
#                     the model opens its turn with a <think> block and Ollama's chat layer takes
#                     that for reasoning and keeps it (OllamaS1.swift). A mode that names s1-mini
#                     with "api": "chat" is a mode that refines nothing, with no error anywhere.
#   instructions      with "api": "s1" this is a CONTROL LINE -- bracketed fields such as
#                     "[Context: general]" -- and not prose. Prose here is refused by
#                     `Mode.validationError` as `instructionsAreNotControlFields`, the mode is
#                     reported unusable, and the raw transcript is inserted instead. The refusal
#                     is deliberate: on the v3 probe a sentence appended to the control line came
#                     back verbatim at the top of the cleaned text on 1 fixture in 4.
#
# This script writes the three together, refuses what `Mode.validate` would refuse, and copies the
# file aside before touching it.
#
# Usage:
#   ./scripts/set-refiner.sh <mode-key> <model> [--api s1|chat] [--instructions TEXT] [--dry-run]
#
#   ./scripts/set-refiner.sh prompt gemma4:12b-it-qat --api chat --instructions "$(cat prompt.txt)"
#   ./scripts/set-refiner.sh prompt hf.co/superwhisper/s1-mini-GGUF:Q4_K_M --api s1
#
# MURMURE_MODES_DIR overrides where the modes live -- required to try this against a copy rather
# than against the real folder.
set -euo pipefail

MODES_DIR="${MURMURE_MODES_DIR:-$HOME/Library/Application Support/Murmure/modes}"

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' >&2
    exit 64
}

MODE_KEY=""
MODEL=""
API=""
INSTRUCTIONS=""
INSTRUCTIONS_GIVEN=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --api) API="${2-}"; shift 2 ;;
        --instructions) INSTRUCTIONS="${2-}"; INSTRUCTIONS_GIVEN=1; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *)
            if [ -z "$MODE_KEY" ]; then MODE_KEY="$1"
            elif [ -z "$MODEL" ]; then MODEL="$1"
            else echo "unexpected argument: $1" >&2; usage
            fi
            shift ;;
    esac
done

[ -n "$MODE_KEY" ] && [ -n "$MODEL" ] || usage

FILE="$MODES_DIR/$MODE_KEY.json"
if [ ! -f "$FILE" ]; then
    echo "no mode file at $FILE" >&2
    [ -d "$MODES_DIR" ] && { echo "modes present:" >&2; ls "$MODES_DIR"/*.json 2>/dev/null | sed 's/^/  /' >&2; }
    exit 66
fi

# Parsed and written with python3 rather than jq: jq only ships with macOS from 15, and python3
# comes with the Command Line Tools that Xcode has already required.
PY=python3
command -v python3 >/dev/null || PY=/usr/bin/python3

MURMURE_FILE="$FILE" MURMURE_MODEL="$MODEL" MURMURE_API="$API" \
MURMURE_INSTRUCTIONS="$INSTRUCTIONS" MURMURE_INSTRUCTIONS_GIVEN="$INSTRUCTIONS_GIVEN" \
MURMURE_DRY_RUN="$DRY_RUN" "$PY" - <<'PY'
import datetime, json, os, shutil, sys

RESET, RED, YELLOW, GREEN, DIM = "\033[0m", "\033[31m", "\033[33m", "\033[32m", "\033[2m"

path = os.environ["MURMURE_FILE"]
model = os.environ["MURMURE_MODEL"]
api = os.environ["MURMURE_API"]
instructions = os.environ["MURMURE_INSTRUCTIONS"]
instructions_given = os.environ["MURMURE_INSTRUCTIONS_GIVEN"] == "1"
dry_run = os.environ["MURMURE_DRY_RUN"] == "1"

# A hint that lives in this SCRIPT and deliberately not in the app. `Mode.LLM.api` is a declared
# field precisely so that no vendor's model id ends up in the routing code: "the mode file says
# which protocol it speaks, and the code never reads the model name". A convenience table here
# spares the common case from having to know, and --api overrides it; a model this table has never
# heard of is asked about rather than guessed at.
SPEAKS_S1 = ("s1-mini",)

# `[Context: general]` ALONE. The omissions are the measured part -- see the note printed below.
DEFAULT_CONTROL = "[Context: general]"


def refuse(message, *lines):
    print(f"{RED}refused{RESET}  {message}")
    for line in lines:
        print(f"         {DIM}{line}{RESET}")
    sys.exit(65)


def warn(message, *lines):
    print(f"{YELLOW}warning{RESET}  {message}")
    for line in lines:
        print(f"         {DIM}{line}{RESET}")


def only_control_fields(text):
    """Mirrors `Mode.containsOnlyControlFields`: a field opens with '[', is not empty, holds no
    second '[', closes on the first ']', and only whitespace separates two of them."""
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


def field_names(text):
    names, rest = [], text.strip()
    while rest.startswith("["):
        close = rest.find("]")
        if close < 0:
            break
        names.append(rest[1:close].split(":")[0].strip())
        rest = rest[close + 1:].lstrip()
    return names


with open(path, encoding="utf-8") as handle:
    try:
        mode = json.load(handle)
    except json.JSONDecodeError as error:
        refuse(f"{path} is not valid JSON: {error}")

llm = mode.setdefault("llm", {})
# An absent `api` means chat, the same default `Mode.LLM`'s hand-written decoder applies: every
# mode file written before s1-mini shipped names a model that speaks /api/chat.
before = {"model": llm.get("model", ""), "api": llm.get("api", "chat"),
          "instructions": mode.get("instructions", "")}

# ---------------------------------------------------------------------------
# Decide the three values
# ---------------------------------------------------------------------------

if api == "":
    if any(marker in model for marker in SPEAKS_S1):
        api = "s1"
    elif before["api"] == "s1":
        # Leaving a model that speaks s1 for one this script does not recognise. Guessing "chat"
        # here would be the exact silent mistake the script exists to prevent.
        refuse(
            f"cannot tell which API {model} speaks, and the mode is currently on \"s1\"",
            "Say so: --api chat for a model driven through /api/chat with written instructions,",
            "--api s1 for one that speaks s1-mini's own conversation format.",
        )
    else:
        api = "chat"

if api not in ("s1", "chat"):
    refuse(f"--api {api!r} is not a value Mode.LLM.API can decode",
           'The two cases are "chat" (/api/chat) and "s1" (/api/generate with raw: true).')

if not instructions_given:
    if api == "s1":
        # Prose cannot be carried across: it is refused by validation on this side, and on the v3
        # probe it came back inside the cleaned text.
        if only_control_fields(before["instructions"]) and before["instructions"].strip():
            instructions = before["instructions"]
        else:
            instructions = DEFAULT_CONTROL
    else:
        if only_control_fields(before["instructions"]):
            # A control line as a chat system prompt is not instructions to a chat model, and
            # there is nothing here to invent it from.
            refuse(
                'switching to "chat" leaves a control line where a written prompt has to go',
                "A chat model is driven by prose, and this script will not write yours.",
                'Pass one:  --instructions "$(cat your-prompt.txt)"',
                "benchmark/prompts/message_rewrite.txt is one that was measured.",
            )
        instructions = before["instructions"]

# ---------------------------------------------------------------------------
# Refuse what Mode.validate would refuse
# ---------------------------------------------------------------------------

if not model.strip():
    refuse('"llm.model" would be empty')
if not instructions.strip():
    refuse('"instructions" would be empty while "llm.enabled" is true')
if api == "s1" and not only_control_fields(instructions):
    refuse(
        '"api": "s1" with instructions that are not a control line',
        "Mode.validate rejects this as instructionsAreNotControlFields: the mode is reported",
        "unusable and the RAW transcript is inserted. With s1 the whole interface is bracketed",
        'fields, e.g. "[Context: general]" -- the model does not follow written instructions,',
        "it copies them into the text it gives back.",
    )

# ---------------------------------------------------------------------------
# Things that validate and are still probably wrong
# ---------------------------------------------------------------------------

if api == "chat" and only_control_fields(instructions):
    warn('"api": "chat" with a control line for instructions',
         "This VALIDATES and still refines nothing useful. If the model speaks s1-mini's format,",
         "the api field is what is wrong -- and on /api/chat it answers EMPTY content.")

if api == "s1":
    extra = [name for name in field_names(instructions) if name != "Context"]
    if extra:
        warn(f"control line carries {', '.join(extra)} beyond [Context: …]",
             "Measured on 48 of Louis's own dictations: adding [Styling: …] -- which the model",
             "card presents as the normal way to use the model -- drops sentence capitalisation",
             "from 96 % to 29 %, and [Styling: casual] is the arm where the runaway repetitions",
             "behind OllamaS1.repeatPenalty were found. benchmark/run_benchmark_v2.py's S1_CONTROL",
             "is one of those fuller lines: it is what the grid measured, not what ships.")

if not llm.get("enabled", False):
    warn('"llm.enabled" is false on this mode, so none of this takes effect yet',
         "Set it to true by hand if you meant to turn the refiner on.")

# ---------------------------------------------------------------------------
# Write, after copying the file aside
# ---------------------------------------------------------------------------

after = {"model": model, "api": api, "instructions": instructions}


def show(label, values):
    print(f"\n  {label}")
    for key in ("model", "api", "instructions"):
        text = values[key]
        shown = text if len(text) <= 68 else text[:65] + "…"
        changed = before[key] != after[key]
        colour = (GREEN if values is after else YELLOW) if changed else ""
        reset = RESET if colour else ""
        print(f'    {colour}{key:<13}{reset} {json.dumps(shown, ensure_ascii=False)}')


print(f"{os.path.basename(path)}")
show("before", before)
show("after", after)

if before == after:
    print(f"\n{DIM}  nothing to change{RESET}")
    sys.exit(0)

if dry_run:
    print(f"\n{DIM}  --dry-run: not written{RESET}")
    sys.exit(0)

stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
backup = f"{path}.{stamp}.bak"
shutil.copy2(path, backup)

llm["model"] = model
llm["api"] = api
mode["instructions"] = instructions

# Re-serialised in the shape Swift's JSONEncoder writes -- sorted keys, two-space indent, a space
# either side of the colon -- so that a file this script touched and a file the app rewrote do not
# differ on whitespace alone. The app rewrites it on its next save either way.
text = json.dumps(mode, ensure_ascii=False, sort_keys=True, indent=2, separators=(",", " : "))
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text + "\n")

print(f"\n{GREEN}  written{RESET}   {path}")
print(f"{DIM}  backup    {backup}{RESET}")
print(f"{DIM}  Murmure reads modes at launch -- quit and reopen it for this to take effect.{RESET}")
PY

# Whether the model is actually there. A warning and not a refusal: Ollama may simply not be
# running right now, and the mode file is still the file you meant to write. Left to the end so it
# cannot stop the edit.
if command -v ollama >/dev/null && ollama list >/dev/null 2>&1; then
    want="$MODEL"
    case "$want" in *:*) ;; *) want="$want:latest" ;; esac
    if ! ollama list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qxF "$want"; then
        printf '\033[33m  warning\033[0m %s\n' "$MODEL is not pulled -- this mode will insert the RAW transcript"
        printf '\033[2m           ollama pull %s\033[0m\n' "$MODEL"
    fi
fi
