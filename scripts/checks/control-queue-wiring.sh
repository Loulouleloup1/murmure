#!/usr/bin/env bash
# Contract probe for the 10-S panel/socket seam.
# This is a source graph check: it must not manufacture a red result when a production file is
# absent from a partial checkout.  The Swift filter remains the executable behavioural gate.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SERVER="$ROOT/Murmure/TranscriptControlServer.swift"
PANE="$ROOT/Murmure/TranscriptsPaneModel.swift"
QUEUE="$ROOT/MurmureCore/Sources/MurmureCore/TranscriptQueue.swift"
TEST="$ROOT/MurmureCore/Tests/MurmureCoreTests/TranscriptQueueTests.swift"
MODE=${1:-wire}
EXPECTED=""

for spec in "server:$SERVER" "pane:$PANE" "queue:$QUEUE" "swift-test:$TEST"; do
  name=${spec%%:*}; path=${spec#*:}
  if [[ -f "$path" ]]; then
    printf 'INFO source-presente=oui contrôle=source-%s chemin=%s\n' "$name" "$path"
  else
    printf 'INDISPONIBLE contrôle=source-%s chemin=%s (graphe non applicable)\n' "$name" "$path"
  fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-queue.XXXXXX")
trap 'rm -rf "$work"' EXIT
[[ -f "$SERVER" ]] && cp "$SERVER" "$work/server.swift" || : >"$work/server.swift"
[[ -f "$PANE" ]] && cp "$PANE" "$work/pane.swift" || : >"$work/pane.swift"
[[ -f "$QUEUE" ]] && cp "$QUEUE" "$work/queue.swift" || : >"$work/queue.swift"
[[ -f "$TEST" ]] && cp "$TEST" "$work/test.swift" || : >"$work/test.swift"

case "$MODE" in
  wire) ;;
  mutant-queue) EXPECTED=server-no-secondary-queue; printf '\nprivate final class ControlJobBoard {}\n' >>"$work/server.swift" ;;
  mutant-runner) EXPECTED=transcribe-injected; perl -0pi -e 's/await submitter\(/await runner.submit(/g' "$work/server.swift" ;;
  mutant-status) EXPECTED=status-injected; perl -0pi -e 's/statusProvider\(\)/phantomQueue.status()/g' "$work/server.swift" ;;
  *) printf 'usage: %s [wire|mutant-queue|mutant-runner|mutant-status]\n' "$0" >&2; exit 64 ;;
esac

fail=0
matched=0
total=0
failed_controls=""
pass() { printf 'VERT contrôle=%s\n' "$1"; }
red() { fail=1; failed_controls="$failed_controls $1"; printf 'ROUGE contrôle=%s détail=%s\n' "$1" "$2"; }
unavailable() { total=$((total + 1)); printf 'INDISPONIBLE contrôle=%s détail=%s\n' "$1" "$2"; }
check() { # name, condition already evaluated by caller
  total=$((total + 1))
  if [[ "$2" -eq 0 ]]; then
    matched=$((matched + 1)); pass "$1"
  else
    red "$1" "$3"
  fi
}

# Extract balanced Swift bodies, so a forbidden word in comments or an unrelated method is not
# confused with the named graph.  A missing symbol is an unmet check, not a shell/setup error.
body_for() {
  local signature=$1 source=$2
  SIGNATURE="$signature" SOURCE="$source" perl -0777 -e '
    my($s,$x)=@ENV{qw(SIGNATURE SOURCE)}; exit 1 unless $x =~ /\Q$s\E\s*\([^)]*\)[^{]*\{/s;
    my $o=index($x,"{",$-[0]); my $d=0; my $e=$o;
    for my $p ($o..length($x)-1) { my $c=substr($x,$p,1); $d++ if $c eq "{"; $d-- if $c eq "}"; if (!$d) {$e=$p; last} }
    exit 1 if $d; print substr($x,$o+1,$e-$o-1);'
}
method_with() {
  local relation=$1 source=$2
  RELATION="$relation" SOURCE="$source" perl -0777 -e '
    my($r,$x)=@ENV{qw(RELATION SOURCE)};
    while ($x =~ /func\s+\w+\s*\([^)]*\)[^{]*\{/g) {
      my $o=$-[0]; my $d=0; my $e=$o;
      for my $p ($o..length($x)-1) { my $c=substr($x,$p,1); $d++ if $c eq "{"; $d-- if $c eq "}"; if (!$d) {$e=$p; last} }
      my $b=substr($x,$o+1,$e-$o-1); if ($b =~ /$r/) { print $b; last }
    }'
}
server=$(<"$work/server.swift"); pane=$(<"$work/pane.swift")

if [[ -f "$SERVER" ]]; then
  init=$(body_for 'init' "$server" || true)
  [[ -n "$init" && "$init" == *submitter* ]]; check initialiseur-submitteur "$?" "initializer does not receive submitter"
  [[ -n "$init" && "$init" == *statusProvider* ]]; check initialiseur-status "$?" "initializer does not receive statusProvider"
  transcribe=$(body_for 'func transcribe' "$server" || body_for 'func transcrire' "$server" || true)
  [[ -n "$transcribe" && "$transcribe" == *'submitter('* ]]; check transcribe-injected "$?" "transcribe does not call injected submitter"
  status=$(body_for 'func status' "$server" || true)
  [[ -n "$status" && "$status" == *'statusProvider('* ]]; check status-injected "$?" "status does not call injected statusProvider"
  [[ -n "$status" && "$status" != *'TranscriptQueue('* ]]; check status-no-queue "$?" "status constructs a secondary queue"

  clean=$(printf '%s' "$server" | perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g')
  [[ "$clean" != *'ControlJobBoard'* && "$clean" != *'enchainer'* && "$clean" != *'dernierTravail'* && "$clean" != *'Task<ControlJobOutcome'* ]]; check server-no-secondary-queue "$?" "server contains a secondary queue/chain"
  [[ "$clean" != *'TranscriptQueue('* ]]; check server-no-queue-construction "$?" "server constructs a queue"
else
  unavailable initialiseur-submitteur 'TranscriptControlServer.swift absent'
  unavailable initialiseur-status 'TranscriptControlServer.swift absent'
  unavailable transcribe-injected 'TranscriptControlServer.swift absent'
  unavailable status-injected 'TranscriptControlServer.swift absent'
  unavailable status-no-queue 'TranscriptControlServer.swift absent'
  unavailable server-no-secondary-queue 'TranscriptControlServer.swift absent'
  unavailable server-no-queue-construction 'TranscriptControlServer.swift absent'
fi
if [[ -f "$PANE" ]]; then
  enqueue=$(method_with '(?:file|queue)\s*\.enqueue\s*\(' "$pane" || true)
  status_use=$(method_with '(?:file|queue)\s*\.status\b' "$pane" || true)
  [[ -n "$enqueue" ]]; check pane-submit "$?" "pane does not route submissions through its queue"
  [[ -n "$status_use" ]]; check pane-status "$?" "pane does not expose queue status"
  count=$(printf '%s' "$pane" | perl -ne '$n+=()=/TranscriptQueue\s*\{/g; END{print $n+0}')
  [[ "$count" -eq 1 ]]; check pane-one-queue "$?" "TranscriptsPaneModel queue constructions=$count (expected exactly 1)"
else
  unavailable pane-submit 'TranscriptsPaneModel.swift absent'
  unavailable pane-status 'TranscriptsPaneModel.swift absent'
  unavailable pane-one-queue 'TranscriptsPaneModel.swift absent'
fi

# The filtered Swift suite is the behavioural contract.  Report its own N/M summary; a return code
# without XCTest's summary is not accepted as evidence.
swift_log="$work/swift.log"
(cd "$ROOT/MurmureCore" && swift test --filter TranscriptQueueSharedContractTests) >"$swift_log" 2>&1
swift_rc=$?
summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$swift_log" | tail -1 | sed 's/^[[:space:]]*//' || true)
printf 'SWIFT rc=%s résumé="%s"\n' "$swift_rc" "$summary"
if [[ $swift_rc -ne 0 && -n "$summary" ]]; then
  fail=1
  printf 'ROUGE contrôle=swift-10-S détail="%s"\n' "$summary"
else
  fail=1
  printf 'ROUGE contrôle=swift-10-S détail="filtre non exécuté ou sans résumé XCTest"\n'
fi
printf 'CONTRÔLE=N/M=%d/%d\n' "$matched" "$total"

if [[ "$fail" -ne 0 ]]; then
  if [[ -z "$EXPECTED" ]]; then
    exit 1
  fi
  if [[ " $failed_controls " == *" $EXPECTED "* ]]; then
    printf 'MUTANT capturé contrôle=%s\n' "$EXPECTED"
    exit 1
  fi
  printf 'MUTANT NON capturé contrôle=%s (aucun rouge exact)\n' "$EXPECTED"
  exit 3
fi
[[ -z "$EXPECTED" ]] || { printf 'MUTANT NON capturé contrôle=%s\n' "$EXPECTED"; exit 3; }
printf 'VERT contrôle=10-S\n'
