#!/usr/bin/env bash
# Contract probe for the 10-S panel/socket seam.
#
# Two families of checks, kept strictly apart:
#
#   * the WIRING graph, read from Swift sources.  Each named control is always executed and is
#     red or green on the evidence found in the source; none of them is red by construction.  A
#     server that satisfies the graph passes all of them, and the DEV that lands the 10-S seam
#     turns this whole family green.
#   * the CORE filter, a real XCTest run.  `Executed 0 tests` is an INVENTORY red of its own
#     (a filter that selects nothing is silent evidence, never a passing verdict); the verdict
#     control is green only on a non-zero execution with zero failures.
#
# The 10-S sources are untracked in the writer worktrees, so the current worktree may not carry
# them.  A missing source is therefore never a silent skip: the control that needs it is red,
# naming the file, and every source is echoed with the root it was resolved from.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODE=${1:-wire}
EXPECTED=""

# The plan (revision 16) names the last writer of each 10-S path.  Resolution tries the tree under
# test first, then those worktrees in the declared order, so the graph is read from a real source
# instead of from an absent file.  Every hit prints the root it came from.
FALLBACK_ROOTS=(
  "$ROOT/../t_d1dbdc77"   # TranscriptControlServer.swift, TranscriptQueue + its tests
  "$ROOT/../t_70d649b1"   # TranscriptsPaneModel.swift
  "$ROOT/../t_c17a5c14"   # TranscriptQueue.swift, TranscriptQueueTests.swift
)
ROOTS=("$ROOT" "${FALLBACK_ROOTS[@]}")
[[ -n "${MURMURE_WIRING_ROOT:-}" ]] && ROOTS=("$MURMURE_WIRING_ROOT" "${ROOTS[@]}")

# `MURMURE_WIRING_ROOT` lets a harness point the graph at another assembly of the same sources
# (a correct-by-construction server, for instance).  It is a source root, never a test hook: the
# controls below read files and run XCTest, they do not know who supplied them.
resolve() { # relative path -> prints the absolute path of the first root that holds it
  local rel=$1 root
  for root in "${ROOTS[@]}"; do
    [[ -f "$root/$rel" ]] && { printf '%s' "$root/$rel"; return 0; }
  done
  return 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-queue.XXXXXX")
trap 'rm -rf "$work"' EXIT

SERVER_REL=Murmure/TranscriptControlServer.swift
PANE_REL=Murmure/TranscriptsPaneModel.swift
QUEUE_REL=MurmureCore/Sources/MurmureCore/TranscriptQueue.swift
TEST_REL=MurmureCore/Tests/MurmureCoreTests/TranscriptQueueTests.swift

server_file=$(resolve "$SERVER_REL" || true)
pane_file=$(resolve "$PANE_REL" || true)
queue_file=$(resolve "$QUEUE_REL" || true)
test_file=$(resolve "$TEST_REL" || true)

for pair in "server:$SERVER_REL:${server_file:-ABSENT}" \
            "pane:$PANE_REL:${pane_file:-ABSENT}" \
            "queue:$QUEUE_REL:${queue_file:-ABSENT}" \
            "swift-test:$TEST_REL:${test_file:-ABSENT}"; do
  name=${pair%%:*}; rest=${pair#*:}; rel=${rest%%:*}; hit=${rest#*:}
  printf 'INFO source=%s chemin=%s résolu=%s\n' "$name" "$rel" "$hit"
done

[[ -n "$server_file" ]] && cp "$server_file" "$work/server.swift" || : >"$work/server.swift"
[[ -n "$pane_file" ]] && cp "$pane_file" "$work/pane.swift" || : >"$work/pane.swift"

case "$MODE" in
  wire) ;;
  mutant-queue) EXPECTED=server-no-secondary-queue
    printf '\nprivate final class ControlJobBoard2 {}\n' >>"$work/server.swift" ;;
  mutant-runner) EXPECTED=transcribe-injected
    perl -0pi -e 's/await submitter\(/await runner.submit(/g' "$work/server.swift" ;;
  mutant-status) EXPECTED=status-injected
    perl -0pi -e 's/statusProvider\(\)/phantomFile.status()/g' "$work/server.swift" ;;
  *) printf 'usage: %s [wire|mutant-queue|mutant-runner|mutant-status]\n' "$0" >&2; exit 64 ;;
esac

fail=0
matched=0
total=0
failed_controls=" "
pass() { printf 'VERT contrôle=%s\n' "$1"; }
red() { fail=1; failed_controls="$failed_controls$1 "; printf 'ROUGE contrôle=%s détail=%s\n' "$1" "$2"; }
# check <name> <0=ok> <detail-if-not>
check() {
  total=$((total + 1))
  if [[ "$2" -eq 0 ]]; then matched=$((matched + 1)); pass "$1"; else red "$1" "$3"; fi
}
# source_check <name> <resolved-path> <detail-when-absent>: a required source is a red control, not
# a skip.  The denominator counts executed controls only.
source_check() {
  if [[ -z "$2" ]]; then red "$1" "$3 absent de l'assemblage"; else pass "$1"; fi
  total=$((total + 1))
}

# Balanced Swift body for a named signature, so a forbidden word in a comment or in an unrelated
# method is never mistaken for the named graph.
body_for() {
  SIGNATURE="$1" SOURCE="$2" perl -0777 -e '
    my($s,$x)=@ENV{qw(SIGNATURE SOURCE)}; exit 1 unless $x =~ /\Q$s\E[^{]*\{/s;
    my $o=index($x,"{",$-[0]); my $d=0; my $e=$o;
    for my $p ($o..length($x)-1) { my $c=substr($x,$p,1); $d++ if $c eq "{"; $d-- if $c eq "}"; if (!$d) {$e=$p; last} }
    exit 1 if $d; print substr($x,$o+1,$e-$o-1);'
}
# Body of the first func whose body matches $2 (regex source).
method_with() {
  RELATION="$1" SOURCE="$2" perl -0777 -e '
    my($r,$x)=@ENV{qw(RELATION SOURCE)};
    while ($x =~ /func\s+\w+\s*[^{]*\{/g) {
      my $o=$-[0]; my $d=0; my $e=$o;
      for my $p ($o..length($x)-1) { my $c=substr($x,$p,1); $d++ if $c eq "{"; $d-- if $c eq "}"; if (!$d) {$e=$p; last} }
      my $b=substr($x,$o+1,$e-$o-1); if ($b =~ /$r/) { print $b; last }
    }'
}

server=$(<"$work/server.swift"); pane=$(<"$work/pane.swift")

# --- inventory: the 10-S sources themselves -------------------------------------------------
source_check source-serveur "$server_file"  "$SERVER_REL"
source_check source-pane   "$pane_file"    "$PANE_REL"
source_check source-file   "$queue_file"   "$QUEUE_REL"
source_check source-test   "$test_file"    "$TEST_REL"

# --- the named wiring graph: TranscriptControlServer -----------------------------------------
if [[ -n "$server_file" ]]; then
  init=$(body_for 'init' "$server" || true)
  [[ -n "$init" && "$init" == *submitter* ]]; check initialiseur-submitteur "$?" \
    "l'initialiseur ne reçoit pas de submitteur injecté"
  [[ -n "$init" && "$init" == *statusProvider* ]]; check initialiseur-status "$?" \
    "l'initialiseur ne reçoit pas de status provider injecté"
  transcribe=$(body_for 'func transcribe' "$server" || body_for 'func transcrire' "$server" || true)
  [[ -n "$transcribe" && "$transcribe" == *'submitter('* ]]; check transcribe-injected "$?" \
    "transcribe n'appelle pas le submitteur injecté"
  status=$(body_for 'func status' "$server" || body_for 'func statut' "$server" || true)
  [[ -n "$status" && "$status" == *'statusProvider('* ]]; check status-injected "$?" \
    "status n'appelle pas le status provider injecté"
  [[ -n "$status" && "$status" != *'TranscriptQueue('* ]]; check status-no-queue "$?" \
    "status construit une file secondaire"

  # Comments carry the vocabulary of the old design; only code is searched.
  clean=$(printf '%s' "$server" | perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g')
  [[ "$clean" != *'ControlJobBoard'* && "$clean" != *'enchainer'* \
     && "$clean" != *'dernierTravail'* && "$clean" != *'Task<ControlJobOutcome'* ]]
  check server-no-secondary-queue "$?" "le serveur contient une file/chaîne provisoire"
  [[ "$clean" != *'TranscriptQueue('* ]]; check server-no-queue-construction "$?" \
    "le serveur construit une file"
else
  for c in initialiseur-submitteur initialiseur-status transcribe-injected status-injected \
           status-no-queue server-no-secondary-queue server-no-queue-construction; do
    check "$c" 1 "$SERVER_REL absent de l'assemblage"
  done
fi

# --- the named wiring graph: TranscriptsPaneModel --------------------------------------------
# `TranscriptQueue` exposes enqueue / entries / waiting / running / drain / cancelCurrent.  The
# pane owns the queue and mirrors its state; there is no `status` member to look for.
if [[ -n "$pane_file" ]]; then
  enqueue=$(method_with '(?:file|fileDeTravail)\s*\.\s*enqueue\s*\(' "$pane" || true)
  [[ -n "$enqueue" ]]; check pane-submit "$?" "le panneau ne soumet pas via sa file"
  lecture=$(method_with '(?:file|fileDeTravail)\s*\.\s*(?:entries|waiting|running)\b' "$pane" || true)
  [[ -n "$lecture" ]]; check pane-status-source "$?" \
    "le panneau ne lit pas les éléments de sa file (entries/waiting/running)"
  count=$(printf '%s' "$pane" | perl -ne '$n+=()=/TranscriptQueue\s*\{/g; END{print $n+0}')
  [[ "$count" -eq 1 ]]; check pane-one-queue "$?" \
    "constructions de file dans TranscriptsPaneModel=$count (exactement 1 attendue)"
else
  for c in pane-submit pane-status-source pane-one-queue; do
    check "$c" 1 "$PANE_REL absent de l'assemblage"
  done
fi

# --- the core behavioural filter ------------------------------------------------------------
# `TranscriptQueue` is a regex: it selects every XCTestCase class of the queue contract, present
# or not yet added by 10-S.  A filter that selects nothing is silent evidence, so it is reported as
# its own inventory control and never as a verdict.
# The XCTest run must happen in the same assembly that supplied the test file: running the filter
# in a `MurmureCore` that does not contain the contract would select nothing and prove nothing.
swift_pkg=""
if [[ -n "$test_file" ]]; then
  swift_pkg="$(cd "$(dirname "$test_file")/../../.." && pwd)/MurmureCore"
  [[ -f "$swift_pkg/Package.swift" ]] || swift_pkg=""
elif [[ -f "$ROOT/MurmureCore/Package.swift" ]]; then
  swift_pkg="$ROOT/MurmureCore"
fi

swift_log="$work/swift.log"
if [[ -n "$swift_pkg" ]]; then
  (cd "$swift_pkg" && swift test --filter 'TranscriptQueue') >"$swift_log" 2>&1
  swift_rc=$?
  summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$swift_log" | tail -1 | sed 's/^[[:space:]]*//' || true)
  # BSD sed has no `\+` in a basic regex: the counters are matched positionally.
  executed=$(printf '%s' "$summary" | sed -n 's/.*Executed \([0-9][0-9]*\) tests\{0,1\}.*/\1/p')
  failures=$(printf '%s' "$summary" | sed -n 's/.*with \([0-9][0-9]*\) failures\{0,1\}.*/\1/p')
  printf 'SWIFT rc=%s résumé="%s"\n' "$swift_rc" "$summary"
  # inventory: the filter must select something, otherwise it proves nothing.
  [[ -n "$summary" && "${executed:-0}" -gt 0 ]]; check filtre-10-S-non-vide "$?" \
    "le filtre Swift n'a sélectionné aucun test (preuve muette) : ${summary:-aucun résumé XCTest}"
  # verdict: a non-zero execution with zero failures is green, and can turn green.
  [[ -n "$summary" && "${executed:-0}" -gt 0 && "${failures:-1}" -eq 0 && "$swift_rc" -eq 0 ]]
  check swift-10-S "$?" "le contrat de file 10-S échoue (${summary:-aucun résumé XCTest})"
else
  red filtre-10-S-non-vide "aucun assemblage MurmureCore exécutable (Package.swift absent)"
  red swift-10-S "aucun assemblage MurmureCore exécutable (Package.swift absent)"
  total=$((total + 2))
  printf 'SWIFT rc=skippé résumé=""\n'
fi

printf 'CONTRÔLE=N/M=%d/%d\n' "$matched" "$total"

if [[ "$fail" -ne 0 ]]; then
  if [[ -z "${EXPECTED// /}" ]]; then exit 1; fi
  if [[ "$failed_controls" == *" $EXPECTED "* ]]; then
    printf 'MUTANT capturé contrôle=%s\n' "$EXPECTED"; exit 1
  fi
  printf 'MUTANT NON capturé contrôle=%s (aucun rouge exact)\n' "$EXPECTED"; exit 3
fi
[[ -z "${EXPECTED// /}" ]] || { printf 'MUTANT NON capturé contrôle=%s (aucun rouge)\n' "$EXPECTED"; exit 3; }
printf 'VERT contrôle=10-S\n'
