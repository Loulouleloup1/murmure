#!/usr/bin/env bash
# Gate locale SwiftPM : aucun lancement d'app ni téléchargement de modèle.
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
RUN_DIR="$ROOT/.codex/workflow-runs"
mkdir -p "$RUN_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG="$RUN_DIR/verify-$RUN_ID.jsonl"
TIMEOUT_SECONDS="${CODEX_VERIFY_TIMEOUT_S:-900}"
TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"
if [ -z "$TIMEOUT_BIN" ] && command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"; fi

log_event() {
  python3 - "$LOG" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
from datetime import datetime, timezone
path, event, code, elapsed, command, detail = sys.argv[1:]
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "event": event,
                               "exit": int(code), "duration_s": int(elapsed),
                               "command": command, "detail": detail}, ensure_ascii=False) + "\n")
PY
}

run_step() {
  local name="$1" command_text="$2" start end code output
  shift 2
  start="$(date +%s)"
  output="$RUN_DIR/verify-$RUN_ID-$name.log"
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$TIMEOUT_SECONDS" "$@" >"$output" 2>&1; else "$@" >"$output" 2>&1; fi
  code=$?
  cat "$output"
  end="$(date +%s)"
  log_event "$name" "$code" "$((end - start))" "$command_text" "output=$output;timeout=${TIMEOUT_BIN:-absent};limit_s=$TIMEOUT_SECONDS"
  return "$code"
}

dirty="$(git status --porcelain | wc -l | tr -d ' ')"
branch="$(git branch --show-current 2>/dev/null || true)"
log_event "preflight" 0 0 "git status --porcelain" "branch=${branch:-detached};preexisting_changes=$dirty"
printf 'Journal : %s\n' "$LOG"
printf 'État Git préexistant : %s changement(s)\n' "$dirty"

failures=0
run_step "diff-working" "git diff --check" git diff --check || failures=$((failures + 1))
run_step "diff-index" "git diff --cached --check" git diff --cached --check || failures=$((failures + 1))
run_step "swift-tests" "cd MurmureCore && swift test" bash -lc 'cd MurmureCore && swift test' || failures=$((failures + 1))

log_event "summary" "$failures" 0 "verify" "failures=$failures"
[ "$failures" -eq 0 ]
