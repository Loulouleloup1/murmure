#!/usr/bin/env bash
# Contrat du chemin de démarrage RÉEL du serveur de contrôle (lot 11-S, carte QA `t_aeb3aea0`).
#
# Ce que ce script est, et ce qu'il n'est pas :
#
#   * Il ne prouve JAMAIS le chemin Finder avec un harnais. Un serveur démarré par un harnais est
#     précisément le défaut que le lot 11-S existe pour fermer (`TranscriptControlServer.start()`
#     n'avait aucun appelant ; `cli-end-to-end.sh` le démarrait lui-même). La famille EXECUTION
#     ouvre donc le bundle par LaunchServices (`/usr/bin/open -gj`), comme le Finder le fait, et
#     attend le socket. Aucun mode de ce script n'appelle `start()`.
#   * Il ne peut pas non plus se_CONTENT_satisfaire d'une absence de socket : « le socket n'est pas
#     là » est rouge, jamais une preuve de succès.
#   * `MURMURE_NO_APP_LAUNCH=1` ne prouve QUE LE REFUS (plan §11-S critère 4) : un run qui ne l'a
#     pas demands ne peut pas rendre `finder-*` vert, et un run qui l'a demandé ne peut pas rendre
#     `finder-*` vert davantage.
#
# DEUX FAMILLES, JAMAIS MÉLANGÉES :
#
#   * GRAPHE — le câblage lu dans les sources Swift : l'ownership du serveur, le handover
#     idempotent, un seul moteur, une seule file, le submitteur/status provider de 10-S. Chaque
#     contrôle nommé est TOUJOURS exécuté et il est rouge ou vert sur la preuve LUE ; aucun n'est
#     rouge par construction. Un serveur conforme les rend tous verts.
#   * EXECUTION — le chemin Finder réel : construction Release, ouverture du bundle par
#     LaunchServices, attente du socket dans la fenêtre de 10 s du §2.5, `murmure status` puis
#     `murmure transcribe <fixture> --wait`, codes 0, transcript présent, aucune file fantôme, et un
#     journal sans texte transcrit.
#
# `Murmure/` n'a pas de bundle de tests (plan §1) : cette couture ne peut pas être prouvée par
# XCTest, d'où un script. `MurmureCore` garde le sien et le contrat l'exerce séparément.
#
# ISOLATION — la gate ne touche jamais `~/Library/Application Support/Murmure/`. L'application est
# ouverte avec `CFFIXED_USER_HOME` pointant vers un home jetable, ce qui déplace `NSHomeDirectory()`
# et donc le socket, la base et les transcripts (mesuré : `CFFIXED_USER_HOME` change
# `FileManager.urls(for: .applicationSupportDirectory)`, `HOME` seul ne le fait pas). `models/`,
# `modes/`, `tools/`, `recordings/` et `vocabulary.json` y sont des liens vers les données réelles :
# le modèle n'est pas retéléchargé et rien n'est écrit dedans.
#
# DEUX CONTRAINTES MESURÉES, ÉCRITES ICI POUR QU'ON NE LES REDÉCOUVRE PAS :
#
#   * `sun_path` fait 104 octets : un home isolé trop long fait échouer le `bind` et l'app journalise
#     « control socket path too long » au lieu de démarrer. Le chemin doit être court ; le script
#     mesure la longueur du chemin final et rend `finder-socket-chemin` rouge au-delà de 100.
#   * la transcription réelle charge le modèle : `--wait` sur une fixture de 3 s a pris plusieurs
#     minutes sur une machine où le modèle est déjà sur disque. Le délai est donc borné par
#     `MURMURE_TRANSCRIBE_TIMEOUT` (900 s par défaut), jamais par un seuil arbitraire court, et le
#     transcript est cherché SUR LE DISQUE — dont l'existence est la seule preuve de la fin du
#     travail.
#
# UN MUTANT EST UNE DIFFÉRENCE, PAS UN ÉTAT : le run rejoue la famille visée sur l'assemblage non
# muté, puis sur l'assemblage muté, et ne revendique une capture que pour un contrôle VERT sur le
# premier et ROUGE sur le second. Un contrôle déjà rouge ne prouve rien ; une mutation qui ne change
# rien est inapplicable. Les deux sortent en 3 en le disant.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
MODE=${1:-finder}
GRAPH_ONLY=${2:-}
EXPECTED=""

# L'arbre sous test. `MURMURE_STARTUP_ROOT` permet à un harnais de désigner une AUTRE assemblage
# comme arbre sous test (une base correcte par construction, par exemple) ; les contrôles
# « sous-test » jugent alors cet assemblage. C'est un localisateur de sources, jamais un crochet de
# verdict : les contrôles relisent les fichiers et rejouent l'exécution, ils n'en apprennent rien.
TEST_ROOT=${MURMURE_STARTUP_ROOT:-$ROOT}

# Les sources 11-S sont non suivies dans chaque worktree d'écrivain, donc l'arbre sous test peut ne
# pas les porter. Chaque fichier est donc résolu depuis l'arbre sous test d'abord, puis depuis les
# worktrees qui l'ont écrit, le plus aval d'abord.
FALLBACK_ROOTS=(
  "$ROOT/../t_3762b434"   # DEV 10-S : le serveur, le panneau, la file, la couture 10-S
  "$ROOT/../t_d1dbdc77"   # L11-R : le serveur et project.yml
)
ROOTS=("$TEST_ROOT" "${FALLBACK_ROOTS[@]}")

canon() { # a file path -> that file with its directory resolved
  local dir base
  dir=$(dirname "$1"); base=$(basename "$1")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  [[ "$base" == "." || -z "$base" ]] && { printf '%s' "$dir"; return 0; }
  printf '%s' "$dir/$base"
}
TEST_ROOT_REAL=$(canon "$TEST_ROOT") || TEST_ROOT_REAL=$TEST_ROOT
resolve() { # relative path -> absolute path of the first root that holds it
  local rel=$1 root
  for root in "${ROOTS[@]}"; do
    [[ -f "$root/$rel" ]] && { canon "$root/$rel"; return 0; }
  done
  return 1
}

# `mktemp -d` sous le TMPDIR de macOS (`/var/folders/…/T/`) produit un home de plus de 100 octets
# une fois `Library/Application Support/Murmure/control.sock` ajouté — mesuré : 126, donc `bind`
# échoue et le contrôle `finder-socket-chemin` devient rouge sur un chemin correct. Le home isolé
# est donc choisi COURT et sous `/tmp` (hors du volume de travail), jamais sous `$TMPDIR`.
work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-startup.XXXXXX")
short_home=$(mktemp -d "/tmp/m11s.XXXXXX")
# `kill 0` — ce que `${APP_PID:-0}` donnerait quand aucun processus n'a été lancé — tue le GROUPE
# DE PROCESSUS ENTIER, le script et le terminal qui l'a lancé compris : un run qui s'achève
# correctement se faisait SIGTERM lui-même (mesuré). Le piège ne tue donc que s'il a un PID réel.
trap '[[ -n "${APP_PID:-}" && "$APP_PID" -gt 1 ]] && kill "$APP_PID" 2>/dev/null; rm -rf "$work" "$short_home"' EXIT

APP_REL=Murmure/TranscriptControlServer.swift
DELEGATE_REL=Murmure/AppDelegate.swift
APPFILE_REL=Murmure/MurmureApp.swift
PANE_REL=Murmure/TranscriptsPaneModel.swift
DICTATION_REL=Murmure/DictationController.swift
ENGINE_REL=Murmure/WhisperKitEngine.swift

server_file=$(resolve "$APP_REL" || true)
delegate_file=$(resolve "$DELEGATE_REL" || true)
appfile_file=$(resolve "$APPFILE_REL" || true)
pane_file=$(resolve "$PANE_REL" || true)
dictation_file=$(resolve "$DICTATION_REL" || true)
engine_file=$(resolve "$ENGINE_REL" || true)

for pair in "server:$APP_REL:${server_file:-ABSENT}" \
            "delegate:$DELEGATE_REL:${delegate_file:-ABSENT}" \
            "app:$APPFILE_REL:${appfile_file:-ABSENT}" \
            "pane:$PANE_REL:${pane_file:-ABSENT}" \
            "dictation:$DICTATION_REL:${dictation_file:-ABSENT}" \
            "engine:$ENGINE_REL:${engine_file:-ABSENT}"; do
  name=${pair%%:*}; rest=${pair#*:}; rel=${rest%%:*}; hit=${rest#*:}
  printf 'INFO source=%s chemin=%s résolu=%s\n' "$name" "$rel" "$hit"
done

[[ -n "$server_file" ]] && cp "$server_file" "$work/server.swift" || : >"$work/server.swift"
[[ -n "$delegate_file" ]] && cp "$delegate_file" "$work/delegate.swift" || : >"$work/delegate.swift"
[[ -n "$appfile_file" ]] && cp "$appfile_file" "$work/app.swift" || : >"$work/app.swift"
[[ -n "$pane_file" ]] && cp "$pane_file" "$work/pane.swift" || : >"$work/pane.swift"
[[ -n "$dictation_file" ]] && cp "$dictation_file" "$work/dictation.swift" || : >"$work/dictation.swift"

# `MURMURE_STARTUP_SERVER` / `MURMURE_STARTUP_DELEGATE` pointent un contrôle de graphe sur UN
# fichier précis, pour qu'un mutant soit mesuré comme une DIFFÉRENCE entre deux assemblages. Comme
# `MURMURE_STARTUP_ROOT`, c'est un localisateur de sources : les contrôles relisent le fichier, ils
# ne reçoivent pas son verdict.
if [[ -n "${MURMURE_STARTUP_SERVER:-}" && -f "${MURMURE_STARTUP_SERVER:-}" ]]; then
  cp "$(canon "$MURMURE_STARTUP_SERVER")" "$work/server.swift"
  printf 'INFO source=serveur-surchargé chemin=%s\n' "$(canon "$MURMURE_STARTUP_SERVER")"
fi
if [[ -n "${MURMURE_STARTUP_DELEGATE:-}" && -f "${MURMURE_STARTUP_DELEGATE:-}" ]]; then
  cp "$(canon "$MURMURE_STARTUP_DELEGATE")" "$work/delegate.swift"
  printf 'INFO source=delegate-surchargé chemin=%s\n' "$(canon "$MURMURE_STARTUP_DELEGATE")"
fi
if [[ -n "${MURMURE_STARTUP_APP:-}" && -f "${MURMURE_STARTUP_APP:-}" ]]; then
  cp "$(canon "$MURMURE_STARTUP_APP")" "$work/app.swift"
  printf 'INFO source=app-surchargé chemin=%s\n' "$(canon "$MURMURE_STARTUP_APP")"
fi

mutate() { # <file> <perl-args...>: applies the edit in place, 0 if the file changed
  local file=$1; shift
  local before after
  before=$(shasum -a 256 <"$file")
  perl "$@" "$file"
  after=$(shasum -a 256 <"$file")
  [[ "$before" != "$after" ]]
}

# The graph family, re-run in this same process on whichever files the MURMURE_STARTUP_* locators
# name. Swift and the Finder path are not re-run: they depend on a whole build, not on one file.
run_graph() { # <label> -> prints the red controls of that assembly
  local label=$1 line name out
  red_set=" "
  out=$(MURMURE_STARTUP_ROOT="$TEST_ROOT" \
        MURMURE_STARTUP_SERVER="$work/server.swift" \
        MURMURE_STARTUP_DELEGATE="$work/delegate.swift" \
        MURMURE_STARTUP_APP="$work/app.swift" \
        "$SELF" wire graph 2>&1)
  while IFS= read -r line; do
    [[ "$line" == ROUGE\ contrôle=* ]] || continue
    name=${line#ROUGE contrôle=}; name=${name%% *}
    red_set="$red_set $name"
  done <<<"$out"
  printf '%s rouges=%s\n' "$label" "${red_set:- aucun}"
  # The re-read files live in a temp directory, so their `-sous-test` controls are red BY
  # CONSTRUCTION and say nothing about the assembly under test. Excluded, so they can never stand
  # in for the control a mutant is meant to flip.
  local u
  for u in delegate-sous-test app-sous-test source-serveur-sous-test; do
    red_set=${red_set// $u/}
  done
  red_set=" $red_set "
  baseline_red=$red_set
}

case "$MODE" in
  wire|finder) ;;
  mutant-no-start) EXPECTED=delegate-starts-server
    # Retirer l'appel `start()` du delegate : le socket n'apparaît plus, la gate Finder rouge.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/delegate.swift" -0pi -e 's/^\s*controlServer\?\.start\(\)\s*$//m'; then
      MUTATED=1
    fi ;;
  mutant-second-engine) EXPECTED=one-engine-construction
    # Une seconde construction de moteur : exactement le défaut du critère 1.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/pane.swift" -0pi -e 's/^(\s*)private let engine: WhisperKitEngine$/$1private let engine2: WhisperKitEngine = WhisperKitEngine(progress: DecodeProgressBox())/m'; then
      MUTATED=1
    fi ;;
  mutant-harness-start) EXPECTED=finder-launched-by-launchservices
    # Le harnais qui pilote `start()` au lieu du Finder : rien n'ouvre le bundle, donc rien ne
    # prouve le chemin réel. La mutation retire l'ouverture LaunchServices du harnais.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    MUTATED=1
    FINDER_MUTANT_HARNESS=1 ;;
  mutant-ghost-status) EXPECTED=status-from-provider
    # `status` qui ne dérive pas du provider commun : la file fantôme du critère 3.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/server.swift" -0pi -e 's/await fournisseurStatut\(\)/await Self.fileFantome()/' \
       || mutate "$work/app.swift" -0pi -e 's/transcriptsModel\.queueStatus\(\)/"idle" (nothing)/'; then
      MUTATED=1
    fi ;;
  *) printf 'usage: %s [finder|wire|mutant-no-start|mutant-second-engine|mutant-harness-start|mutant-ghost-status]\n' "$0" >&2; exit 64 ;;
esac
if [[ -n "$EXPECTED" && -z "${MUTATED:-}" ]]; then
  printf 'MUTANT INAPPLICABLE mode=%s : la mutation n’a rien changé dans la copie\n' "$MODE"
  exit 3
fi

fail=0
matched=0
total=0
failed_controls=" "
pass() { printf 'VERT contrôle=%s\n' "$1"; }
red() { fail=1; failed_controls="$failed_controls$1 "; printf 'ROUGE contrôle=%s détail=%s\n' "$1" "$2"; }
check() {
  total=$((total + 1))
  if [[ "$2" -eq 0 ]]; then matched=$((matched + 1)); pass "$1"; else red "$1" "$3"; fi
}
source_check() { # <name> <resolved-path> <detail-when-absent>
  local name=$1 hit=$2 detail=$3
  total=$((total + 1))
  if [[ -z "$hit" ]]; then
    red "$name-present" "$detail absent de tout assemblage"
  else
    matched=$((matched + 1)); pass "$name-present"
  fi
  total=$((total + 1))
  if [[ -n "$hit" && "$hit" == "$TEST_ROOT_REAL/"* ]]; then
    matched=$((matched + 1)); pass "$name-sous-test"
  elif [[ -n "$hit" ]]; then
    red "$name-sous-test" "$detail présent hors de l'arbre sous test : $hit"
  else
    red "$name-sous-test" "$detail absent de l'arbre sous test $TEST_ROOT"
  fi
}

# Balanced Swift body for a named signature, so a forbidden word in a comment or in an unrelated
# method is never mistaken for the named graph. Comments are stripped first: these files narrate
# the very vocabulary the controls forbid.
clean_of() { perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g'; }
body_for() {
  SIGNATURE="$1" SOURCE="$2" perl -0777 -e '
    my($s,$x)=@ENV{qw(SIGNATURE SOURCE)};
    my $t = $x; $t =~ s{/\*.*?\*/}{}gs; $t =~ s{//[^\n]*}{}g;
    exit 1 unless $t =~ /\Q$s\E[^{]*\{/s;
    my $o=index($t,"{",$-[0]); my $d=0; my $e=$o;
    for my $p ($o..length($t)-1) { my $c=substr($t,$p,1); $d++ if $c eq "{"; $d-- if $c eq "}"; if (!$d) {$e=$p; last} }
    exit 1 if $d; print substr($t,$o+1,$e-$o-1);'
}
# Signature of a named DECLARATION, from the keyword up to the body's opening brace, so an
# INJECTED dependency (a parameter) is seen and not only what the body does with it. This is the
# house idiom of `control-queue-wiring.sh`, for the same reason: matching a bare substring lets a
# comment that merely NAMES a method donate its own brace.
sig_for() {
  SIGNATURE="$1" SOURCE="$2" perl -0777 -e '
    my($s,$x)=@ENV{qw(SIGNATURE SOURCE)};
    my $t = $x; $t =~ s{/\*.*?\*/}{}gs; $t =~ s{//[^\n]*}{}g;
    my $k = $s;
    exit 1 unless $t =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|class|static|final|mutating)[ \t]+)*\Q$k\E\b[^\n{(]*[(<]/m;
    my $st = $-[0];
    my $o = $st; my $d = 0; my $found = 0;
    for my $p ($st .. length($t) - 1) {
      my $c = substr($t, $p, 1);
      $d++ if $c eq "{"; $d-- if $c eq "}";
      if ($c eq "{" && $d == 1) { $o = $p; $found = 1; last }
    }
    exit 1 unless $found; print substr($t, $st, $o - $st);'
}
# EVERY executed `status` path of the server, ACCUMULATED — a `func status`/`func statut` body PLUS
# every `case .status:`/`case "status":` arm. The same two shapes `control-queue-wiring.sh`
# accepts, and for the same reason: the delivered server answers `status` from a `case`, and a
# contract that read only the declaration would be red on the minimal correct edit — and would make
# the plan's mandatory ghost-status mutant uncapturable.
cat >"$work/status_paths.pl" <<'STATUS_PATHS_PL'
use strict; use warnings;
local $/; my $x = <STDIN>;
$x =~ s{/\*.*?\*/}{}gs;
$x =~ s{//[^\n]*}{}g;
my $trouve = 0;
while ($x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|class|static|final|mutating)[ \t]+)*func[ \t]+(?:status|statut)\b[^{]*\{/gm) {
  my $o = index($x, '{', $-[0]); my $d = 0; my $e = -1;
  for my $p ($o .. length($x) - 1) {
    my $c = substr($x, $p, 1);
    $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  next if $e < 0;
  print substr($x, $o + 1, $e - $o - 1);
  $trouve = 1;
}
while ($x =~ /^([ \t]*)case[ \t]+(?:\.status|"status")[ \t]*:[ \t]*\n/gm) {
  my $st = $-[0]; my $ind = $1; my $p = index($x, "\n", $st); my $out = '';
  while ($p < length($x)) {
    my $nl = index($x, "\n", $p + 1); $nl = length($x) if $nl < 0;
    my $line = substr($x, $p + 1, $nl - $p - 1);
    last if $line =~ /^\Q$ind\E(?:case\b|default\b|\})/;
    $out .= $line . "\n";
    $p = $nl;
  }
  print $out;
  $trouve = 1;
  pos($x) = $p;
}
exit($trouve ? 0 : 1);
STATUS_PATHS_PL
status_paths() { perl "$work/status_paths.pl"; }
has_any() { local hay=$1 needle; shift; for needle in "$@"; do [[ "$hay" == *"$needle"* ]] && return 0; done; return 1; }

server=$(clean_of <"$work/server.swift")
delegate=$(clean_of <"$work/delegate.swift")
appfile=$(clean_of <"$work/app.swift")
pane=$(clean_of <"$work/pane.swift")
dictation=$(clean_of <"$work/dictation.swift")

# --- inventory: the 11-S sources themselves --------------------------------------------------
source_check source-serveur  "$server_file"    "$APP_REL"
source_check source-delegate "$delegate_file" "$DELEGATE_REL"
source_check source-app      "$appfile_file"   "$APPFILE_REL"
source_check source-pane     "$pane_file"      "$PANE_REL"
source_check source-dictation "$dictation_file" "$DICTATION_REL"

# --- the named wiring graph: AppDelegate owns the server --------------------------------------
if [[ -n "$delegate_file" ]]; then
  launch=$(body_for 'func applicationDidFinishLaunching' "$delegate" || true)
  has_any "$launch" 'start()' && [[ -n "$launch" ]]; check delegate-starts-server "$?" \
    "applicationDidFinishLaunching n'appelle pas start() : le socket n'apparaîtra jamais par le chemin Finder"
  term=$(body_for 'func applicationWillTerminate' "$delegate" || true)
  has_any "$term" 'stop()' && [[ -n "$term" ]]; check delegate-stops-server "$?" \
    "applicationWillTerminate n'appelle pas stop() : le socket survit à la terminaison"
  # The handover is a NAMED method, and it must be guarded against a second configuration: a
  # delegate that re-configures builds a second server, and two listeners on one path is exactly the
  # failure `unlink` then `bind` papers over.
  handover=$(body_for 'func configureControlServer' "$delegate" || true)
  [[ -n "$handover" ]]; check delegate-configure-handover "$?" \
    "le delegate ne reçoit pas les dépendances par une méthode de configuration nommée"
  printf '%s' "$handover" | grep -qE 'guard .*(== nil|!= nil)|if .*(== nil|!= nil)'; check delegate-handover-idempotent "$?" \
    "configureControlServer n'est pas idempotent : une seconde configuration créerait un second serveur"
  # The server is a PROPERTY of the delegate, not something it builds per call.
  printf '%s' "$delegate" | grep -qE 'var[[:space:]]+[A-Za-z_]*[Ss]erver[^\n]*:[[:space:]]*TranscriptControlServer\?'; \
    check delegate-owns-server "$?" "le delegate ne possède pas le serveur comme propriété"
else
  for c in delegate-starts-server delegate-stops-server delegate-configure-handover \
           delegate-handover-idempotent delegate-owns-server; do
    check "$c" 1 "$DELEGATE_REL absent de l'assemblage"
  done
fi

# --- the named wiring graph: MurmureApp hands the 10-S seams over ------------------------------
if [[ -n "$appfile_file" ]]; then
  printf '%s' "$appfile" | grep -q 'configureControlServer'; check app-configures-server "$?" \
    "MurmureApp ne configure pas le serveur du delegate"
  # The submitteur handed over must be the PANEL's submitter (10-S), not a runner of the app's own.
  cfg=$(body_for 'var body' "$appfile" || true)
  has_any "$cfg" 'submit(' && has_any "$cfg" 'queueStatus()'; check app-submitter-from-pane "$?" \
    "le handover ne soumet pas par le submitteur du panneau (10-S)"
  # The pane is built WITH the dictation's engine: `TranscriptsPaneModel(engine:` — a DEV that
  # forgot it cannot compile, and one that builds its own is the criterion-1 defect.
  printf '%s' "$appfile" | grep -qE 'TranscriptsPaneModel\([^)]*engine:'; check app-pane-gets-engine "$?" \
    "MurmureApp ne construit pas le panneau avec le moteur de la dictée"
else
  for c in app-configures-server app-submitter-from-pane app-pane-gets-engine; do
    check "$c" 1 "$APPFILE_REL absent de l'assemblage"
  done
fi

# --- the named wiring graph: ONE engine, ONE queue --------------------------------------------
# Criterion 1: exactly one `WhisperKitEngine(` CONSTRUCTION in `Murmure/`, and it is the dictation's.
# The construction form is `WhisperKitEngine(` or `WhisperKitEngine {`; a bare type mention (a
# parameter annotation) is not a construction and stays allowed.
if [[ -n "$pane_file" && -n "$dictation_file" ]]; then
  n_engine=$(printf '%s' "$dictation" | perl -ne '$n+=()=/WhisperKitEngine\s*[({]/g; END{print $n+0}')
  n_engine_pane=$(printf '%s' "$pane" | perl -ne '$n+=()=/WhisperKitEngine\s*[({]/g; END{print $n+0}')
  [[ "$n_engine" -ge 1 && "$n_engine_pane" -eq 0 ]]; check one-engine-construction "$?" \
    "constructions de WhisperKitEngine : dictée=$n_engine panneau=$n_engine_pane (1 au total, dans la dictée)"
  # And the video reuses it: `loadedModelForVideo` on the RECEIVED engine, with the shared policy.
  printf '%s' "$pane" | grep -qE 'engine\.loadedModelForVideo\('; check video-uses-shared-engine "$?" \
    "la vidéo n'appelle pas loadedModelForVideo sur le moteur reçu"
  # One queue: the pane's. 10-S already freezes this in the panel; 11-S must not add a second.
  n_queue=$(printf '%s' "$pane" | perl -ne '$n+=()=/TranscriptQueue\s*[({]/g; END{print $n+0}')
  [[ "$n_queue" -eq 1 ]]; check one-queue-construction "$?" \
    "constructions de TranscriptQueue dans le panneau=$n_queue (exactement 1 attendue)"
  printf '%s' "$server" | perl -ne '$n+=()=/TranscriptQueue\s*[({]/g; exit($n>0)'; check server-no-queue "$?" \
    "le serveur construit une file"
else
  for c in one-engine-construction video-uses-shared-engine one-queue-construction server-no-queue; do
    check "$c" 1 "sources du moteur ou du panneau absentes de l'assemblage"
  done
fi

# --- the named wiring graph: the server reads the COMMON queue --------------------------------
if [[ -n "$server_file" ]]; then
  status=$(printf '%s' "$server" | status_paths || true)
  has_any "$status" 'fournisseurStatut(' 'statusProvider(' && [[ -n "$status" ]]; check status-from-provider "$?" \
    "aucun chemin status exécuté n'appelle le status provider injecté (cherché : func status/statut, case .status:)"
  # The socket adds no state of its own: no second board, no enchainer, no phantom file.
  [[ "$server" != *'ControlJobBoard'* && "$server" != *'enchainer'* && "$server" != *'fileFantome'* ]]
  check server-no-phantom-board "$?" "le serveur contient une file/chaîne provisoire"
else
  for c in status-from-provider server-no-phantom-board; do
    check "$c" 1 "$APP_REL absent de l'assemblage"
  done
fi

# ============================ la gate EXECUTION : le chemin Finder =============================
# Nothing below may be satisfied by a harness: the bundle is opened by LaunchServices, exactly as
# the Finder opens it, and no mode of this script calls `start()`.
TRANSCRIBE_TIMEOUT=${MURMURE_TRANSCRIBE_TIMEOUT:-900}
SOCKET_WINDOW=10   # §2.5 : the window the CLI itself grants before failing in code 3.

run_finder() { # the real Finder path; prints its evidence, sets FINDER_* reason strings
  local app="$work/Murmure.app" home="$short_home" socket transcripts cli fixture
  local elapsed=0 waited=0

  printf '\n--- EXECUTION : chemin Finder réel ---\n'
  # 1. Build Release. No bootstrap, no model download, no xcodegen regeneration beyond the spec
  #    that the tree already carries (AGENTS.md).
  printf 'BUILD configuration=Release\n'
  if [[ -f "$TEST_ROOT/project.yml" && -d "$TEST_ROOT/Murmure" ]]; then
    ( cd "$TEST_ROOT" && xcodebuild -project Murmure.xcodeproj -scheme Murmure \
        -configuration Release -derivedDataPath "$work/dd" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build ) >"$work/build.log" 2>&1
    build_rc=$?
  else
    build_rc=65
    printf 'error: arbre sous test sans project.yml/Murmure (%s)\n' "$TEST_ROOT" >"$work/build.log"
  fi
  printf 'BUILD rc=%s journal=%s\n' "$build_rc" "$work/build.log"
  check finder-build-release "$([[ $build_rc -eq 0 ]] && echo 0 || echo 1)" \
    "la construction Release échoue (rc=$build_rc, journal $work/build.log)"
  if [[ $build_rc -ne 0 ]]; then
    FINDER_NO_APP="la construction Release a échoué : pas de bundle à ouvrir"
    return 1
  fi
  # `$work` est ABSOLU (mktemp) : le concatener a `$TEST_ROOT/` produirait un chemin inexistant
  # (mesuré : le bundle construit n'a jamais été trouvé, et le contrôle CLI est devenu rouge a tort).
  # Le bundle est donc cherché par `find`, jamais par concaténation.
  local built
  built=$(find "$work/dd/Build/Products" -maxdepth 2 -name 'Murmure.app' -type d 2>/dev/null | head -1)
  [[ -n "$built" && -d "$built" ]]; check finder-bundle-built "$?" \
    "aucun Murmure.app construit sous $work/dd (le bundle est-il produit ?)"
  if [[ -z "$built" || ! -d "$built" ]]; then
    FINDER_NO_APP="aucun bundle construit"
    return 1
  fi
  printf 'FINDER bundle_construit=%s\n' "$built"
  cp -R "$built" "$app"
  [[ -x "$app/Contents/Helpers/murmure" ]]; check finder-cli-in-bundle "$?" \
    "le bundle construit ne porte pas Contents/Helpers/murmure"
  cli="$app/Contents/Helpers/murmure"
  [[ -x "$cli" ]] || { FINDER_NO_APP="le CLI n'est pas dans le bundle"; return 1; }

  # 2. The isolated home. SHORT on purpose: `sun_path` is 104 bytes and a long path makes the
  #    server log "control socket path too long" and start nothing.
  mkdir -p "$home/Library/Application Support/Murmure"
  local real="$HOME/Library/Application Support/Murmure"
  for d in models modes recordings tools vocabulary.json; do
    [[ -e "$real/$d" ]] && ln -sfn "$real/$d" "$home/Library/Application Support/Murmure/$d"
  done
  socket="$home/Library/Application Support/Murmure/control.sock"
  transcripts="$home/Library/Application Support/Murmure/Transcripts"
  mkdir -p "$transcripts"
  local socket_len=${#socket}
  printf 'FINDER home=%s socket=%s longueur=%d\n' "$home" "$socket" "$socket_len"
  [[ "$socket_len" -le 100 ]]; check finder-socket-chemin "$?" \
    "le chemin du socket fait $socket_len octets : `bind` échouerait (sun_path = 104)"

  # 3. THE FINDER PATH. `/usr/bin/open -gj` on the bundle — LaunchServices, like a double-click.
  #    The harness never starts the server, and says so.
  printf 'FINDER ouverture=LaunchServices commande="/usr/bin/open -gj --env CFFIXED_USER_HOME=%s %s"\n' \
    "$home" "$app"
  if [[ -n "${FINDER_MUTANT_HARNESS:-}" ]]; then
    # The mutant: a harness that drives `start()` instead of the Finder. Reproduced HERE, on the
    # same base, so the control below flips for the reason the card names.
    printf 'FINDER MUTANT le harnais pilote start() au lieu du Finder\n'
    launched=0
  else
    /usr/bin/open -gj --env CFFIXED_USER_HOME="$home" "$app" >/dev/null 2>&1
    open_rc=$?
    launched=1
    printf 'FINDER open rc=%s\n' "$open_rc"
  fi
  [[ "$launched" -eq 1 ]]; check finder-launched-by-launchservices "$?" \
    "le bundle n'a pas été ouvert par LaunchServices : rien ne prouve le chemin Finder réel"

  # 4. The socket inside the 10 s window, and OWNED BY THE APP — a socket some other process
  #    happens to serve is not the acceptance proof.
  while [[ ! -S "$socket" && $waited -lt $((SOCKET_WINDOW * 2)) ]]; do
    sleep 0.5; waited=$((waited + 1)); elapsed=$(awk "BEGIN{print $waited * 0.5}")
  done
  if [[ -S "$socket" ]]; then
    # Le socket doit être tenu par un processus réel, et ce processus doit être LE BUNDLE OUVERT.
    # Un socket que quelqu'un d'autre servirait ne prouve pas le chemin Finder : c'est pourquoi le
    # détenteur est mesuré, puis son exécutable comparé au bundle de CE run.
    owner=$(lsof -U 2>/dev/null | grep -F "$socket" | awk 'NR==1{print $2}')
    [[ -n "$owner" ]]; check finder-socket-owner-is-app "$?" \
      "le socket n'est tenu par aucun processus identifiable"
    local owner_exe="" owner_app=""
    [[ -n "$owner" ]] && owner_exe=$(ps -o command= -p "$owner" 2>/dev/null || true)
    # `ps` rapporte un chemin CANONIQUE (`/private/var/…`) là où le script a construit un chemin
    # symlinké (`/var/…`) : une comparaison de chaînes rendait ce contrôle rouge sur le bundle
    # correct (mesuré). Les deux côtés sont donc canonicalisés avant d'être comparés.
    [[ -n "$owner_exe" ]] && owner_app=$(cd "$(dirname "$owner_exe")/../.." 2>/dev/null && pwd -P || true)
    local app_real
    app_real=$(cd "$app" 2>/dev/null && pwd -P || printf '%s' "$app")
    [[ "$owner_app" == "$app_real" ]]; check finder-socket-served-by-bundle "$?" \
      "le socket est servi par « ${owner_app:-inconnu} », pas par le bundle ouvert ($app_real)"
    printf 'FINDER socket_appeared_after=%ss owner_pid=%s\n' "$elapsed" "${owner:-inconnu}"
    [[ "$(awk "BEGIN{print ($elapsed <= $SOCKET_WINDOW) ? 0 : 1}")" -eq 0 ]]; check finder-socket-in-window "$?" \
      "le socket a mis ${elapsed}s à apparaître (fenêtre du §2.5 : ${SOCKET_WINDOW}s)"
  else
    for c in finder-socket-owner-is-app finder-socket-served-by-bundle finder-socket-in-window; do
      check "$c" 1 "le socket n'a pas été créé en ${SOCKET_WINDOW}s (chemin Finder non prouvé)"
    done
    FINDER_NO_APP="le socket n'a pas été créé en ${SOCKET_WINDOW}s"
    return 1
  fi

  export MURMURE_CONTROL_SOCKET="$socket" MURMURE_TRANSCRIPTS_DIR="$transcripts"

  # 5. `status` first, on an IDLE queue: it must describe the common queue, and a queue that
  #    describes work nobody submitted is the phantom queue the card forbids.
  status_out=$(timeout 30 "$cli" status 2>&1); status_rc=$?
  printf 'FINDER status rc=%s sortie=%s\n' "$status_rc" "$status_out"
  [[ "$status_rc" -eq 0 ]]; check finder-status-code "$?" \
    "« murmure status » rend $status_rc (0 attendu) : $status_out"
  local phantom=0
  grep -qiE 'running|waiting' <<<"$status_out" && phantom=1
  [[ "$phantom" -eq 0 ]]; check finder-no-phantom-queue "$?" \
    "« status » décrit un travail en cours sur une file vide : $status_out"

  # 6. `transcribe <fixture> --wait` — la transcription réelle, le transcript SUR LE DISQUE comme
  #    preuve. La fixture est copiée dans le home COURT et non dans `$work` : sous `/var/folders`
  #    le chemin est un lien symbolique, l'application résout `/private/var/...`, et l'identité du
  #    document calculée par le lanceur ne correspond plus à celle qu'écrit le runner — le travail
  #    se termine alors sur « finished without writing a transcript » alors que le transcript EST
  #    sur le disque (mesuré). Une fixture sous un chemin réel n'a pas ce défaut.
  fixture_src=""
  for root in "$TEST_ROOT" "${FALLBACK_ROOTS[@]}"; do
    if [[ -f "$root/MurmureCore/Tests/MurmureCoreTests/Fixtures/bonjour.wav" ]]; then
      fixture_src="$root/MurmureCore/Tests/MurmureCoreTests/Fixtures/bonjour.wav"; break
    fi
  done
  [[ -n "$fixture_src" ]]; check finder-fixture-available "$?" \
    "aucune fixture audio suivie (bonjour.wav) dans l'assemblage"
  if [[ -n "$fixture_src" ]]; then
    fixture="$home/fixture.wav"
    cp "$fixture_src" "$fixture"
    transcribe_out=$(timeout "$TRANSCRIBE_TIMEOUT" "$cli" transcribe "$fixture" --wait 2>&1); tr_rc=$?
    printf 'FINDER transcribe rc=%s (délai maximal %ss)\n' "$tr_rc" "$TRANSCRIBE_TIMEOUT"
    printf 'FINDER transcribe sortie=%s\n' "$(printf '%s' "$transcribe_out" | head -3 | tr '\n' '|')"
    [[ "$tr_rc" -eq 0 ]]; check finder-transcribe-code "$?" \
      "« transcribe --wait » rend $tr_rc (0 attendu) : $(printf '%s' "$transcribe_out" | head -2 | tr '\n' ' ')"
    local doc
    doc=$(find "$transcripts" -maxdepth 1 -name '*.json' -newer "$fixture" 2>/dev/null | head -1)
    [[ -n "$doc" ]]; check finder-transcript-on-disk "$?" \
      "aucun transcript écrit dans $transcripts après « transcribe --wait »"
    if [[ -n "$doc" ]]; then
      # A transcript with no segment is a transcript nobody transcribed.
      local segments
      segments=$(grep -c '"text"' "$doc" 2>/dev/null || echo 0)
      [[ "${segments:-0}" -ge 1 ]]; check finder-transcript-has-text "$?" \
        "le transcript $doc ne porte aucun segment"
    fi
    # After the work, `status` must be back to a resting queue: not a queue stuck on a finished job.
    status_after=$(timeout 30 "$cli" status 2>&1); sa_rc=$?
    printf 'FINDER status_apres rc=%s sortie=%s\n' "$sa_rc" "$status_after"
    ! grep -qiE '^running' <<<"$status_after"; check finder-status-settles "$?" \
      "« status » reste sur un travail terminé : $status_after"
  fi

  # 7. `MURMURE_NO_APP_LAUNCH=1` proves THE REFUSAL ONLY (criterion 4). It must be asked of a socket
  #    that is genuinely ABSENT: pointed at the socket of the running app it would answer `idle`
  #    and succeed, which measures nothing. A separate, never-created path is used, and the control
  #    can never contribute to a green Finder path.
  refusal_socket="$home/absent.sock"
  refusal_out=$(MURMURE_CONTROL_SOCKET="$refusal_socket" MURMURE_NO_APP_LAUNCH=1 \
    timeout 30 "$cli" status 2>&1); refusal_rc=$?
  printf 'FINDER refus socket_absent=%s rc=%s sortie=%s\n' "$refusal_socket" "$refusal_rc" "$refusal_out"
  [[ ! -S "$refusal_socket" ]]; check no-app-launch-no-socket "$?" \
    "le socket du refus existe : le contrôle « refus » ne prouverait rien"
  [[ "$refusal_rc" -eq 3 ]]; check no-app-launch-refusal "$?" \
    "« MURMURE_NO_APP_LAUNCH=1 » sur un socket absent rend $refusal_rc (3 attendu) : $refusal_out"

  # 8. The journal carries no transcribed text (criterion 5). The log is read AFTER the work, and
  #    the check is a negative on a POSITIVE corpus: the same window must contain the server's
  #    control lines, or the absence of transcript text proves nothing (an empty log is silent
  #    evidence, never a passing verdict).
  # `--info --debug` est OBLIGATOIRE et mesuré : le serveur journalise « control: listening » en
  # `.info`, et `log show` SANS `--info` ne rend que le défaut et au-dessus — le contrôle
  # `log-has-control-activity` était donc rouge sur une application qui, elle, journalisait
  # (mesuré : la ligne est bien dans la base, invisible sans le drapeau).
  log_out=$(log show --last 30m --predicate 'subsystem == "com.louiscourcier.Murmure"' --info --debug --style compact 2>/dev/null || true)
  local listening=0 leaked=0
  grep -qi 'control' <<<"$log_out" && listening=1
  [[ "$listening" -eq 1 ]]; check log-has-control-activity "$?" \
    "le journal ne mentionne pas le contrôle : une absence de transcript y serait une preuve muette"
  if [[ "$listening" -eq 1 ]]; then
    if [[ -n "$doc" ]]; then
      # The exact segments of the document just written: a real leak, not a guess.
      local needle
      needle=$(grep -o '"text" : "[^"]*"' "$doc" 2>/dev/null | head -1 | sed 's/.*"text" : "//; s/"$//')
      if [[ -n "$needle" && ${#needle} -ge 8 ]]; then
        grep -qF "$needle" <<<"$log_out" && leaked=1
        [[ "$leaked" -eq 0 ]]; check log-no-transcript-text "$?" \
          "le journal contient le texte transcrit « ${needle:0:40}… »"
        printf 'FINDER journal_sonde=%s\n' "${needle:0:40}"
      else
        red log-no-transcript-text "aucun segment lisible dans $doc : la sonde serait muette"
      fi
    fi
  fi
}

if [[ "$GRAPH_ONLY" == graph ]]; then
  # Graph family only. A mutant is measured by re-running the graph on two assemblies, and the
  # Finder path depends on a whole build, so it is skipped rather than paid for twice per mutant.
  #
  # The MUTANT VERDICT is printed BEFORE this early exit, and it is the only line that says
  # « capturé ». Sans cela un mutant capturé et un simple run rouge sortent tous deux en 1, sans
  # que rien ne les distingue (mesuré : les trois mutants de la famille câblage sortaient en 1
  # SANS leur ligne de verdict). Un rc ne prouve rien ; la ligne le prouve.
  printf '\nCONTRÔLE=N/M=%d/%d\n' "$matched" "$total"
  if [[ -n "$EXPECTED" ]]; then
    if [[ "$failed_controls" != *" $EXPECTED "* ]]; then
      printf 'MUTANT NON capturé contrôle=%s (aucun rouge exact sur l’assemblage muté)\n' "$EXPECTED"
      exit 3
    fi
    if [[ "${baseline_red:- }" == *" $EXPECTED "* ]]; then
      printf 'MUTANT NON capturé contrôle=%s (déjà rouge sur l’assemblage de référence : la mutation ne prouve rien)\n' \
        "$EXPECTED"
      exit 3
    fi
    printf 'MUTANT capturé contrôle=%s (vert sur l’assemblage de référence, rouge sur l’assemblage muté)\n' \
      "$EXPECTED"
    exit 1
  fi
  printf 'PARTIEL famille=câblage N/M=%d/%d (chemin Finder non exécuté : aucun verdict de bout en bout)\n' \
    "$matched" "$total"
  exit 1
fi

# A GRAPH mutant is measured on the graph family alone: its control is a graph control, and paying a
# Release build plus a real transcription to move it would be both slow and beside the point. The
# FINDER mutant is the opposite — its control lives in the execution family, so that family runs.
if [[ -n "$EXPECTED" && "$EXPECTED" != finder-* ]]; then
  printf '\nCONTRÔLE=N/M=%d/%d\n' "$matched" "$total"
else
  run_finder
  printf '\nCONTRÔLE=N/M=%d/%d\n' "$matched" "$total"
fi

# A mutant run is a DIFFERENCE, not a state.
if [[ -n "$EXPECTED" ]]; then
  if [[ -n "${FINDER_MUTANT_HARNESS:-}" ]]; then
    if [[ "$failed_controls" != *" $EXPECTED "* ]]; then
      printf 'MUTANT NON capturé contrôle=%s (aucun rouge exact sur l’assemblage muté)\n' "$EXPECTED"
      exit 3
    fi
    printf 'MUTANT capturé contrôle=%s (le harnais piloté par start() ne prouve pas le chemin Finder)\n' "$EXPECTED"
    exit 1
  fi
  if [[ "$failed_controls" != *" $EXPECTED "* ]]; then
    printf 'MUTANT NON capturé contrôle=%s (aucun rouge exact sur l’assemblage muté)\n' "$EXPECTED"
    exit 3
  fi
  if [[ "${baseline_red:- }" == *" $EXPECTED "* ]]; then
    printf 'MUTANT NON capturé contrôle=%s (déjà rouge sur l’assemblage de référence : la mutation ne prouve rien)\n' \
      "$EXPECTED"
    exit 3
  fi
  printf 'MUTANT capturé contrôle=%s (vert sur l’assemblage de référence, rouge sur l’assemblage muté)\n' \
    "$EXPECTED"
  exit 1
fi

if [[ "$fail" -ne 0 ]]; then
  printf 'ROUGE CONTRAT=11-S\n'
  exit 1
fi
printf 'VERT contrôle=11-S\n'
