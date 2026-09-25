#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); MODE=${1:-wire}
SERVER="$ROOT/Murmure/TranscriptControlServer.swift"; PANE="$ROOT/Murmure/TranscriptsPaneModel.swift"; TEST="$ROOT/MurmureCore/Tests/MurmureCoreTests/TranscriptQueueTests.swift"
for path in "$SERVER" "$PANE" "$TEST"; do [[ -f "$path" ]]||{ printf 'ROUGE contrôle=fichiers-disponibles détail=%s\n' "$path";exit 2; }; done
work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-queue.XXXXXX"); trap 'rm -rf "$work"' EXIT
function_body(){ SIGNATURE="$1" SOURCE="$2" perl -0777 -e 'my($s,$x)=@ENV{qw(SIGNATURE SOURCE)};exit 1 unless $x=~/$s/g;my$d=$-[0];my$o=index($x,"{",$d);exit 1 if$o<0;my$depth=0;my$e=$o;for my$p($o..length($x)-1){my$c=substr($x,$p,1);$depth++ if$c eq "{";$depth-- if$c eq "}";if(!$depth){$e=$p;last}}exit 1 if$depth;print substr($x,$o+1,$e-$o-1);'; }
function_containing(){ RELATION="$1" SOURCE="$2" perl -0777 -e 'my($r,$x)=@ENV{qw(RELATION SOURCE)};while($x=~/func\s+\w+\s*\([^)]*\)[^{]*\{/g){my$o=$-[0];my$d=0;my$e=$o;for my$p($o..length($x)-1){$d++ if substr($x,$p,1) eq "{";$d-- if substr($x,$p,1) eq "}";if(!$d){$e=$p;last}}my$b=substr($x,$o+1,$e-$o-1);if($b=~$r){print$b;last}}'; }
check_graph(){
  local server=$1 pane=$2 expected=${3:-} failures=() init transcribe status enqueue status_body
  init=$(function_body 'init\s*\(' "$server")||failures+=(initialiseur-introuvable); [[ "$init" == *submitter*&&"$init" == *statusProvider* ]]||failures+=(injections-absentes)
  transcribe=$(function_body '\bfunc\s+transcrire\s*\(' "$server")||failures+=(transcribe-introuvable); [[ "$transcribe" == *'submitter('* ]]||failures+=(transcribe-submitteur-injecte)
  status=$(function_body '\bfunc\s+status\s*\(' "$server" 2>/dev/null||true); [[ -n "$status" ]]||status=$(function_body 'case\s+\.status\s*:' "$server" 2>/dev/null||true)
  [[ -n "$status" ]]||failures+=(status-chemin-introuvable); [[ "$status" == *'statusProvider('*&&"$status" != *'TranscriptQueue('* ]]||failures+=(status-provider-injecte)
  local stripped; stripped=$(printf '%s' "$server"|perl -0777 -pe 's{/\*.*?\*/}{}gs;s{//[^\n]*}{}g')
  for forbidden in ControlJobBoard enchainer dernierTravail 'Task<ControlJobOutcome';do [[ "$stripped" != *"$forbidden"* ]]||failures+=(file-secondaire);done
  enqueue=$(function_containing '(?:file|queue)\s*\.enqueue\s*\(' "$pane"); status_body=$(function_containing '(?:file|queue)\s*\.status\b' "$pane")
  [[ -n "$enqueue" ]]||failures+=(modele-file-absente); [[ -n "$status_body" ]]||failures+=(modele-status-absent)
  local count; count=$(printf '%s' "$pane"|perl -ne '$n+=()=/TranscriptQueue\s*\{/g;END{print$n+0}'); [[ "$count" == 1 ]]||failures+=(modele-file-secondaire)
  if [[ -n "$expected" ]];then [[ " ${failures[*]} " == *" $expected "*&&${#failures[@]} -eq 1 ]]||{ printf 'MUTANT incorrect contrôle=%s failures=%s\n' "$expected" "${failures[*]:-aucun}";return 2; };printf 'MUTANT capturé contrôle=%s\n' "$expected";return 1;fi
  [[ ${#failures[@]} -eq 0 ]]||{ printf 'ROUGE contrôle=câblage-10-S failures=%s\n' "${failures[*]}";return 1; }
}
fixture_server='actor Server { init(submitter: @escaping (String) async -> String, statusProvider: @escaping () async -> String) { self.submitter=submitter;self.statusProvider=statusProvider };private let submitter:(String)async->String;private let statusProvider:()async->String;func transcrire(_ source:String)async->String{await submitter(source)};func status()async->String{await statusProvider()} }'
fixture_pane='final class Pane {private let file=TranscriptQueue{_ in};func submit(_ source:String)async{await file.enqueue(source:source)};var controlStatus:String{get async{await file.status}}}'
case "$MODE" in
  wire)
    check_graph "$(cat "$SERVER")" "$(cat "$PANE")"||true
    if (cd "$ROOT/MurmureCore"&&swift test --filter 'MurmureCoreTests.TranscriptQueueTests/')>"$work/swift.log" 2>&1;then
      printf 'SWIFT rc=0 résumé=contrat-parent\n';exit 1
    fi
    summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$work/swift.log"|tail -1||true)
    if [[ -n "$summary" ]];then printf 'SWIFT résumé="%s"\n' "$summary";exit 1;fi
    compile_errors=$(grep -c 'TranscriptQueue.*has no member' "$work/swift.log"||true)
    printf 'ROUGE contrôle=API-10-S-ABSENTE erreurs-compilation=%s résumé=N=0/M=0\n' "$compile_errors"
    exit 1;;
  mutant-queue) check_graph "$fixture_server
final class ControlJobBoard {}" "$fixture_pane" file-secondaire||true;;
  mutant-runner) check_graph "${fixture_server/await submitter(source)/await runner.submit(source)}" "$fixture_pane" transcribe-submitteur-injecte||true;;
  mutant-status) check_graph "${fixture_server/await statusProvider()/await phantomQueue.status()}" "$fixture_pane" status-provider-injecte||true;;
  *) printf 'usage: %s [wire|mutant-queue|mutant-runner|mutant-status]\n' "$0";exit 64;;
esac
[[ "$MODE" != wire ]]&&exit 1
swift_log="$work/swift.log";(cd "$ROOT/MurmureCore"&&swift test --filter TranscriptQueueSharedContractTests)>"$swift_log" 2>&1;rc=$?;summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$swift_log"|tail -1||true);printf 'SWIFT rc=%s résumé="%s"\n' "$rc" "$summary"
[[ $rc -ne 0&&-n "$summary" ]]||exit 1;exit 1
