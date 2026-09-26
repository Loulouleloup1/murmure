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
trap '[[ -n "${HARNESS_PID:-}" ]] && kill "$HARNESS_PID" 2>/dev/null; [[ -n "${APP_PID:-}" && "$APP_PID" -gt 1 ]] && kill "$APP_PID" 2>/dev/null; rm -rf "$work" "$short_home"' EXIT

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
[[ -n "$engine_file" ]] && cp "$engine_file" "$work/engine.swift" || : >"$work/engine.swift"

# (le corpus de comptage est construit APRÈS les surcharges ci-dessous : il doit refléter les
# fichiers rejoués, pas ceux d'avant)

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
# Le MÊME localisateur pour le MOTEUR. Il existe parce que la DÉCLARATION de
# `loadedModelForVideo(dedicatingComputeUnits:)` est dans `WhisperKitEngine.swift` : le contrôle
# de la vidéo LIT ce défaut, donc un mutant doit pouvoir le porter sur une copie de travail sans
# que le graphe relise le fichier d'origine — sinon `mutant-default-dedicated` (la sonde S9 de la
# revue round 4) muterait une copie que personne ne relit, et serait déclaré capturé ou
# inapplicable selon le hasard.
if [[ -n "${MURMURE_STARTUP_ENGINE:-}" && -f "${MURMURE_STARTUP_ENGINE:-}" ]]; then
  cp "$(canon "$MURMURE_STARTUP_ENGINE")" "$work/engine.swift"
  printf 'INFO source=engine-surchargé chemin=%s\n' "$(canon "$MURMURE_STARTUP_ENGINE")"
fi

# Le CORPUS de comptage : TOUT `Murmure/` de l'arbre sous test, puis les six copies de travail —
# qui incluent les surcharges ET les mutations — écrasant leur version d'origine. C'est la seule
# façon de compter « une seule construction dans Murmure/ » sans regarder deux noms de fichiers :
# un second moteur ou une seconde file dans `MurmureApp.swift` serait compté (mesuré : les
# contrôles `one-engine-construction`/`one-queue-construction` d'une version antérieure ne
# surveillaient que le panneau et le serveur, et un second moteur dans MurmureApp les laissait
# tous deux verts — 24/24).
#
# Construit À LA DEMANDE, jamais au chargement : le mode mutant mute les copies de travail avant
# de rejouer le graphe, un corpus figé ne verrait pas la mutation (et le mutant serait déclaré
# capturé sur une base où il n'a rien changé).
build_corpus() {
  mkdir -p "$work/corpus"
  # RECURSIF, et c'est le point : `project.yml:37-40` liste `path: Murmure` ENTIER, seule
  # exclusion `Resources`. Un `.swift` dans un sous-dossier de `Murmure/` compile donc dans la
  # cible, et un glob non récif (`cp Murmure/*.swift`) le laissait hors du corpus : mesuré, un
  # second moteur ET une seconde file dans `Murmure/Views/` laissaient `one-engine-construction`
  # et `one-queue-construction` verts (26/26). La structure est PRÉSERVÉE pour que le rapport
  # dise QUEL fichier, et `Resources` est exclu comme le fait la cible.
  #
  # Les six noms de travail sont SAUTÉS dans la copie de l'arbre : ils sont réécrits juste après
  # par les copies de travail (surcharges ET mutations), et les garder en double ferait compter un
  # même fichier deux fois — un rouge de comptage, pas un rouge de câblage.
  if [[ -d "$TEST_ROOT/Murmure" ]]; then
    local rel dest
    while IFS= read -r rel; do
      case "${rel##*/}" in
        Resources) continue ;;
        TranscriptControlServer.swift|AppDelegate.swift|MurmureApp.swift| \
        TranscriptsPaneModel.swift|DictationController.swift|WhisperKitEngine.swift) continue ;;
      esac
      dest="$work/corpus/$rel"
      mkdir -p "$(dirname "$dest")"
      cp "$TEST_ROOT/Murmure/$rel" "$dest" 2>/dev/null || true
    done < <(cd "$TEST_ROOT/Murmure" && find . -name '*.swift' -type f \
              -not -path './Resources/*' 2>/dev/null | sed 's|^\./||' | sort)
  fi
  # Un ARBRE SUPPLÉMENTAIRE, pour qu'un mutant puisse injecter une construction dans un
  # SOUS-DOSSIER de `Murmure/` — le site que le corpus plat ne voyait pas. Comme
  # `MURMURE_STARTUP_ROOT`, c'est un localisateur de SOURCES : il ne peut qu'AJOUTER des fichiers,
  # jamais en retirer, donc il ne peut pas rendre un contrôle vert par ce qu'il cache.
  if [[ -n "${MURMURE_STARTUP_CORPUS:-}" && -d "${MURMURE_STARTUP_CORPUS}" ]]; then
    local rel dest
    while IFS= read -r rel; do
      dest="$work/corpus/$rel"
      mkdir -p "$(dirname "$dest")"
      cp "${MURMURE_STARTUP_CORPUS}/$rel" "$dest" 2>/dev/null || true
    done < <(cd "${MURMURE_STARTUP_CORPUS}" && find . -name '*.swift' -type f 2>/dev/null \
              | sed 's|^\./||' | sort)
    printf 'INFO corpus_supplementaire=%s\n' "${MURMURE_STARTUP_CORPUS}"
  fi
  cp "$work/server.swift"    "$work/corpus/TranscriptControlServer.swift"  2>/dev/null || true
  cp "$work/delegate.swift"  "$work/corpus/AppDelegate.swift"              2>/dev/null || true
  cp "$work/app.swift"       "$work/corpus/MurmureApp.swift"              2>/dev/null || true
  cp "$work/pane.swift"      "$work/corpus/TranscriptsPaneModel.swift"    2>/dev/null || true
  cp "$work/dictation.swift" "$work/corpus/DictationController.swift"     2>/dev/null || true
  cp "$work/engine.swift"    "$work/corpus/WhisperKitEngine.swift"         2>/dev/null || true
  printf 'INFO corpus=%s fichiers=%s\n' "$work/corpus" \
    "$(find "$work/corpus" -name '*.swift' -type f 2>/dev/null | wc -l | tr -d ' ')"
}

mutate() { # <file> <perl-args...>: applies the edit in place, 0 if the file changed
  local file=$1; shift
  local before after
  before=$(shasum -a 256 <"$file")
  perl "$@" "$file"
  after=$(shasum -a 256 <"$file")
  [[ "$before" != "$after" ]]
}

# Les deux fichiers ROGUES des mutants de sous-dossier. Ils sont écrits ici, et non générés par
# le mutant, pour que leur contenu soit LISIBLE et stable : un mutant dont la charge utile est
# reconstruite à chaque run ne prouve que sa propre génération. Les deux sont BIEN TYPÉS comme le
# sont les constructions réelles (`DictationController.swift:358` pour le moteur), donc
# l'assemblage muté reste COMPILABLE — un mutant qui ne compile pas ne prouve rien du contrôle.
write_rogue_engine() { # <destination>
  cat >"$1" <<'ROGUE_ENGINE'
import Foundation
import MurmureCore

/// Second moteur, dans un sous-dossier de `Murmure/` : la seconde instance que le critère 1
/// interdit. Bien typé comme la construction réelle de `DictationController.swift:358`, et
/// `import MurmureCore` compris comme le font les fichiers réels : l'assemblage muté reste
/// COMPILABLE — un mutant qui ne compile pas ne prouve rien du contrôle.
enum RogueEngineFactory {
    static func make() -> WhisperKitEngine {
        WhisperKitEngine(progress: DecodeProgressBox()) { _ in }
    }
}
ROGUE_ENGINE
}
write_rogue_queue() { # <destination>
  cat >"$1" <<'ROGUE_QUEUE'
import Foundation
import MurmureCore

/// Seconde file, dans un sous-dossier de `Murmure/` : le mutant obligatoire « seconde
/// construction moteur/file », au site que le corpus plat ne voyait pas. Même forme que la
/// construction réelle de `TranscriptsPaneModel.swift:82`, `import MurmureCore` compris.
enum RogueQueueFactory {
    static func make() -> TranscriptQueue {
        TranscriptQueue { entry in _ = entry }
    }
}
ROGUE_QUEUE
}
# Second VIDEO PATH, elsewhere in `Murmure/` than the pane, asking for a DEDICATED engine. This is
# the F2 the round-3 review measured at 26/26: the control read the argument on `$pane` only, so a
# second video path in `Murmure/Views/` could claim `dedicatingComputeUnits: true` — the second
# instance criterion 1 forbids — with every control green. It is written here, VISIBLE and stable,
# and well typed as the real call site (`TranscriptsPaneModel.swift:708`): a mutant that does not
# compile proves nothing of the control.
write_rogue_video() { # <destination>
  cat >"$1" <<'ROGUE_VIDEO'
import Foundation

/// Second video path, in a subdirectory of `Murmure/`, asking for a DEDICATED engine — the
/// second instance the criterion 1 forbids, reached from a path the pane-only read never saw.
/// Well typed as `TranscriptsPaneModel.swift:708`, so the mutated assembly still COMPILES.
enum RogueVideoFactory {
    static func model(for engine: WhisperKitEngine) async throws -> LoadedModel {
        try await engine.loadedModelForVideo(dedicatingComputeUnits: true)
    }
}
ROGUE_VIDEO
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
        MURMURE_STARTUP_ENGINE="$work/engine.swift" \
        MURMURE_STARTUP_CORPUS="${MURMURE_STARTUP_CORPUS:-}" \
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
    # Une seconde construction de moteur : exactement le défaut du critère 1. Elle est injectée
    # dans MurmureApp, PAS dans le panneau : c'est le site que les contrôles d'origine ne
    # surveillaient pas, et le mutant doit tomber sur le contrôle le plus large (F2/F3 de la
    # revue round 1 — un second moteur dans MurmureApp laissait 24/24 verts).
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    # `\@` dans le MOTIF : sans l'échappement, `@NSApplicationDelegateAdaptor` est interprété
    # comme un tableau Perl vide et le motif ne matche jamais (mesuré : mutant INAPPLICABLE).
    if mutate "$work/app.swift" -0pi -e 's/^(\s*)\@NSApplicationDelegateAdaptor\(AppDelegate\.self\) private var appDelegate$/$1private let rogueEngine = WhisperKitEngine(progress: DecodeProgressBox()) { _ in }\n$1\@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate/m'; then
      MUTATED=1
    fi ;;
  mutant-second-queue) EXPECTED=one-queue-construction
    # Une seconde FILE, dans MurmureApp : le mutant obligatoire « seconde construction
    # moteur/file », sur le site que `server-no-queue` ne surveillait pas.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/app.swift" -0pi -e 's/^(\s*)\@NSApplicationDelegateAdaptor\(AppDelegate\.self\) private var appDelegate$/$1private let rogueQueue = TranscriptQueue { entry in _ = entry }\n$1\@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate/m'; then
      MUTATED=1
    fi ;;
  mutant-dedicated-compute) EXPECTED=video-compute-not-dedicated
    # `dedicatingComputeUnits: true` : la vidéo prend le chemin du modèle dédié
    # (`WhisperKitEngine.swift:331`), c'est-à-dire la seconde instance que le critère 1 interdit.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/pane.swift" -0pi -e 's/dedicatingComputeUnits: false/dedicatingComputeUnits: true/'; then
      MUTATED=1
    fi ;;
  mutant-dedicated-compute-multiligne) EXPECTED=video-compute-not-dedicated
    # Le MÊME défaut, écrit sur PLUSIEURS LIGNES. C'est la forme que le mutant précédent ne peut
    # pas atteindre : il substitue `false`→`true` EN PLACE, donc forcément sur une seule ligne.
    # Le contrôle, lui, lisait l'argument par un `sed` LIGNE À LIGNE et renvoyait la chaîne vide
    # sur cette forme — puis déclarait l'absence d'argument « conforme » (mesuré : 26/26, F1 de la
    # revue round 2). Swift valide (`swiftc -parse` rc=0) et le dépôt écrit couramment ainsi
    # (509 lignes de plus de 100 caractères dans `Murmure/*.swift`), donc la forme multi-lignes
    # n'est pas une hypothèse : c'est ce que le contrôle doit savoir lire.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/pane.swift" -0pi \
        -e 's/loadedModelForVideo\(dedicatingComputeUnits: false\)/loadedModelForVideo(\n            dedicatingComputeUnits: true)/'; then
      MUTATED=1
    fi ;;
  mutant-sous-dossier-moteur|mutant-sous-dossier-file)
    # Une construction dans un SOUS-DOSSIER de `Murmure/`. `project.yml:37-40` liste `path:
    # Murmure` ENTIER (seule exclusion `Resources`), donc `Murmure/Views/Rogue*.swift` compile
    # dans la cible — et le corpus était plat (`cp Murmure/*.swift`), invisible à ce site
    # (mesuré : 26/26 avec les deux contrôles verts, F2 de la revue round 2). Les mutants
    # existants tombaient, mais sur le site qu'ils choisissent (`MurmureApp.swift`, 1er niveau) :
    # ils ne prouvaient rien du sous-dossier.
    case "$MODE" in
      mutant-sous-dossier-moteur) EXPECTED=one-engine-construction ;;
      *)                         EXPECTED=one-queue-construction ;;
    esac
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    mkdir -p "$work/corpus_rogue/Views"
    if [[ "$MODE" == mutant-sous-dossier-moteur ]]; then
      write_rogue_engine "$work/corpus_rogue/Views/RogueEngine.swift"
    else
      write_rogue_queue "$work/corpus_rogue/Views/RogueQueue.swift"
    fi
    # Localisateur de SOURCES : le graphe relit le fichier injecté. Il ne peut qu'ajouter.
    MURMURE_STARTUP_CORPUS="$work/corpus_rogue"
    MUTATED=1 ;;
  mutant-sous-dossier-video) EXPECTED=video-compute-not-dedicated
    # Un SECOND chemin vidéo, dans un sous-dossier de `Murmure/`, qui réclame un moteur DÉDIÉ. Le
    # contrôle du round 3 lisait l'argument sur le SEUL panneau : cette injection le laissait VERT
    # (mesuré 26/26 par la revue), alors que c'est exactement la seconde instance que le critère 1
    # interdit. Bien typé comme `TranscriptsPaneModel.swift:708`, l'assemblage muté compile.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    mkdir -p "$work/corpus_rogue/Views"
    write_rogue_video "$work/corpus_rogue/Views/RogueVideo.swift"
    # Localisateur de SOURCES : le graphe relit le fichier injecté. Il ne peut qu'ajouter.
    MURMURE_STARTUP_CORPUS="$work/corpus_rogue"
    MUTATED=1 ;;
  mutant-second-control-server) EXPECTED=one-control-server-construction
    # Un SECOND serveur de contrôle, BIEN TYPÉ, construit ET DÉMARRÉ dans MurmureApp — le site que
    # les mutants `mutant-second-engine`/`mutant-second-queue` choisissent déjà. Aucun contrôle ne
    # comptait les serveurs dans l'app : mesuré par la revue round 3, ce mutant laissait 26/26 avec
    # les trois contrôles du critère 2 verts, sur un assemblage COMPILÉ (`BUILD SUCCEEDED`).
    # Ce n'est pas un strawman : `start()` fait `unlink` puis `bind`, donc le second serveur vole
    # le socket au premier au lieu d'échouer.
    #
    # La construction passe par une BOÎTE de référence : un `private var` dans le `struct App` ne
    # compile pas (`cannot assign to property: 'self' is immutable` — l'injection de la revue a
    # buté dessus, mesuré par un vrai build). `final class` + `let` compile dans un struct.
    # Le `submitteur` rend `.failed(String)` : `ControlJobOutcome` ne demande qu'un `String`, donc
    # l'injection n'a pas à construire un `TranscriptDocument` (dont l'initialiseur a onze
    # paramètres) — le mutant reste BIEN TYPÉ, donc l'assemblage compile.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/app.swift" -0pi -e 's/^(\s*)\@NSApplicationDelegateAdaptor\(AppDelegate\.self\) private var appDelegate$/$1\@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate\n\n$1\/\/\/ RogueControlServerBox : le second serveur, construit ET démarré hors du delegate.\n$1private final class RogueControlServerBox {\n$1    static let shared = RogueControlServerBox()\n$1    let server: TranscriptControlServer\n$1    private init() {\n$1        server = TranscriptControlServer(\n$1            submitteur: { _ in ControlJobHandle(libelle: "", attendu: { .failed("rogue") }) },\n$1            fournisseurStatut: { "idle" })\n$1        server.start()\n$1    }\n$1}/m'; then
      MUTATED=1
    fi ;;
  mutant-second-entry-point) EXPECTED=delegate-handover-idempotent
    # `configureControlServer` EXACTEMENT conforme, plus un SECOND point d'entrée
    # (`reconfigureControlServer`) que le menu appelle, qui fait `stop()` puis reconstruit et
    # redémarre un serveur neuf. Les mutants existants ne le voyaient pas : ils mutaient le CORPS
    # de la méthode nommée, et le contrôle ne jugeait que ce corps (mesuré : VERT
    # contrôle=delegate-handover-idempotent, 26/26 — F3 de la revue round 2). C'est le critère 2
    # qui parle d'une seconde CONFIGURATION, donc de tous les chemins qui configurent.
    #
    # Les `start()`/`stop()` ci-dessous sont du TEXTE INJECTÉ dans une copie de travail, jamais
    # exécutés : ce mode ne fait que relire le graphe (`wire graph`), il ne construit pas et n'ouvre
    # rien. C'est pourquoi un `grep '\.start()'` sur ce script trouve ce motif — il fait partie de
    # la charge utile du mutant, au même titre que `.start()` apparaît dans le commentaire l. 7.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/delegate.swift" -0pi \
        -e 's/^(\s*)func applicationDidFinishLaunching\(/$1func reconfigureControlServer(\n$1    submitteur: \@escaping \@Sendable (String) async -> ControlJobHandle,\n$1    fournisseurStatut: \@escaping \@Sendable () async -> String\n$1) {\n$1    controlServer?.stop()\n$1    controlServer = TranscriptControlServer(submitteur: submitteur, fournisseurStatut: fournisseurStatut)\n$1    controlServer?.start()\n$1}\n\n$1func applicationDidFinishLaunching(/m'; then
      MUTATED=1
    fi ;;
  mutant-non-idempotent) EXPECTED=delegate-handover-idempotent
    # Un handover qui reconstruit un serveur à CHAQUE configuration, avec un simple
    # `if controlServer == nil { log.info(…) }` qui ne retourne pas : le défaut exact du critère 2,
    # et ce qu'un grep `== nil` laissait passer (mesuré, 24/24 — F4 de la revue round 1).
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/delegate.swift" -0pi \
        -e 's/^(\s*)guard controlServer == nil else \{ return \}$/$1if controlServer == nil { _ = applicationLaunched }/m'; then
      MUTATED=1
    fi ;;
  mutant-unguarded-construction) EXPECTED=delegate-handover-idempotent
    # Le handover CORRECT, plus une construction de serveur AVANT la garde : le serveur est
    # reconstruit à chaque configuration alors que la garde, la sortie anticipée et la comparaison
    # sur la propriété sont toutes présentes. Seule la contrainte (c) du contrôle peut le voir —
    # c'est le mutant qui prouve que (c) n'est pas décorative.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/delegate.swift" -0pi \
        -e 's/^(\s*)guard controlServer == nil else \{ return \}$/$1_ = TranscriptControlServer(submitteur: submitteur, fournisseurStatut: fournisseurStatut)\n$1guard controlServer == nil else { return }/m'; then
      MUTATED=1
    fi ;;
  mutant-default-dedicated) EXPECTED=video-compute-not-dedicated
    # S9 DE LA REVUE ROUND 4 (non bloquant pour elle, BLOQUANT pour la preuve) : l'appel perd son
    # argument ET le défaut de la déclaration passe à `true`. La vidéo réclame alors un moteur
    # dédié — la seconde instance que le critère 1 interdit — et le contrôle restait VERT, 27/27,
    # parce qu'il AFFIRMAIT le défaut au lieu de le LIRE. Il est vrai que `WhisperKitEngine.swift`
    # est figé ; il est faux que le contrôle le vérifiait. Les DEUX mutations sont donc dans ce
    # mutant : c'est leur ENSEMBLE qui rendait la branche « appel sans argument » verte, et c'est
    # l'ensemble qu'il faut pouvoir casser.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/engine.swift" -0pi \
        -e 's/dedicatingComputeUnits: Bool = false/dedicatingComputeUnits: Bool = true/' \
       && mutate "$work/pane.swift" -0pi \
        -e 's/loadedModelForVideo\(dedicatingComputeUnits: false\)/loadedModelForVideo()/'; then
      MUTATED=1
    fi ;;
  mutant-unguarded-start) EXPECTED=one-control-server-start
    # S10 DE LA REVUE ROUND 4, rejoué tel quel : la garde `if applicationLaunched` du handover
    # devient un APPEL NU. Le delegate reste conforme à tous les autres contrôles — comparison sur
    # la propriété, sortie anticipée, construction unique, `start()` présent dans
    # `applicationDidFinishLaunching` — et le critère 2 est rompu : un handover arrivé APRÈS le
    # lancement redémarre un serveur déjà démarré, et `start()` refait `unlink` puis `bind`.
    # Mesuré par la revue sur un assemblage COMPILÉ : `BUILD SUCCEEDED`, CONTRÔLE=27/27, les six
    # contrôles du critère 2 verts. C'est le témoin que le contrôle qui manquait mesurait le
    # DÉMARRAGE et pas la CONSTRUCTION.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/delegate.swift" -0pi \
        -e 's/^(\s*)if applicationLaunched \{ controlServer\?\.start\(\) \}$/$1controlServer?.start()/m'; then
      MUTATED=1
    fi ;;
  mutant-second-start) EXPECTED=one-control-server-start
    # S6 DE LA REVUE ROUND 4 : un second `start()` dans `applicationDidBecomeActive`, donc à
    # chaque retour dans l'app le serveur se réécrit — `unlink` puis `bind` sur le socket qu'il
    # tient lui-même. Le nombre de CONSTRUCTIONS ne bouge pas (1), `delegate-starts-server` reste
    # vert, et le handover reste idempotent : c'est bien le DÉMARRAGE qui n'est pas unique, ce
    # qu'aucun contrôle ne voyait. Mesuré par la revue : `BUILD SUCCEEDED`, 27/27.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate "$work/delegate.swift" -0pi \
        -e 's/^(\s*)func applicationWillTerminate\(/$1func applicationDidBecomeActive(_ notification: Notification) {\n$1    controlServer?.start()\n$1}\n\n$1func applicationWillTerminate(/m'; then
      MUTATED=1
    fi ;;
  mutant-harness-start) EXPECTED=finder-launched-by-launchservices
    # Le harnais qui pilote `start()` au lieu du Finder. Ce n'est pas un drapeau : un processus
    # ÉTRANGER sert réellement le socket du contrat (voir `run_finder`), donc le socket EXISTE et
    # le CLI peut le joindre — la situation qu'un harnais produirait, et que rien ne prouve le
    # chemin Finder. Le contrôle tombe sur l'état du monde (open exécuté + processus du bundle
    # vivant), jamais sur une variable que ce mode écrit (F5 de la revue round 1).
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
  *) printf 'usage: %s [finder|wire|mutant-no-start|mutant-second-engine|mutant-second-queue|mutant-dedicated-compute|mutant-dedicated-compute-multiligne|mutant-default-dedicated|mutant-sous-dossier-moteur|mutant-sous-dossier-file|mutant-sous-dossier-video|mutant-second-control-server|mutant-second-entry-point|mutant-non-idempotent|mutant-unguarded-construction|mutant-unguarded-start|mutant-second-start|mutant-harness-start|mutant-ghost-status]\n' "$0" >&2; exit 64 ;;
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
# Le comptage « une seule construction dans Murmure/ », sur le CORPUS entier et non sur deux
# noms de fichiers. Un site de construction est WARMUP s'il est dans le corps de la déclaration
# `enum ModelWarmup`, APP sinon ; `WhisperKitEngine {` dans `WhisperKitEngine.swift:29` est la
# DÉCLARATION de l'acteur, pas une construction, et ne doit pas être comptée.
cat >"$work/corpus_scan.pl" <<'CORPUS_SCAN_PL'
use strict; use warnings;
my $dir = $ARGV[0];
# Le corpus est RÉCURSIONNEL : `project.yml:37-40` liste `path: Murmure` entier, seule exclusion
# `Resources`, donc un `.swift` sous un sous-dossier de `Murmure/` compile dans la CIBLE. Un
# parcours non récif laissait un second moteur dans `Murmure/Views/` invisible au comptage
# (mesuré : `one-engine-construction` et `one-queue-construction` verts, 26/26 — F2 de la revue
# round 2). Les chemins sont rapportés RELATIFS à la racine du corpus, donc le rapport dit QUEL
# fichier porte la construction.
my @files;
# Les trois types dont le critère 1 et le critère 2 exigent « exactement une construction dans
# l'app ». `TranscriptControlServer` y figure depuis le round 4 : le critère 2 dit « le serveur est
# démarré EXACTEMENT une fois », et rien ne comptait les serveurs dans l'app — un second serveur
# bien typé, construit ET démarré dans `MurmureApp.swift`, laissait le contrat à 26/26 avec les
# contrôles du critère 2 verts (mesuré par la revue round 3, sur un assemblage COMPILÉ). Le
# comptage est donc le même que pour le moteur et la file : le CORPUS récursif, pas un nom de
# fichier. Le serveur n'a pas d'exception warm-up, mais le partage du mécanisme ne crée pas
# d'exception : c'est le même site, la même déclaration, le même corpus.
my @TYPES = qw(WhisperKitEngine TranscriptQueue TranscriptControlServer);
sub walk {
  my ($d, $prefix) = @_;
  opendir(my $dh, $d) or return;
  for my $e (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
    my $full = "$d/$e";
    if (-d $full) { walk($full, "$prefix$e/") }
    elsif ($e =~ /\.swift$/) { push @files, "$prefix$e" }
  }
  closedir $dh;
}
walk($dir, '');
exit 2 unless @files;
sub strip { my $t = shift; $t =~ s{/\*.*?\*/}{}gs; $t =~ s{//[^\n]*}{}g; $t }
my %sites;   # type -> [ [fichier, offset], ... ]
my %warmup_body_span;
for my $f (@files) {
  open(my $fh, '<', "$dir/$f") or next;
  my $raw = do { local $/; <$fh> }; close $fh;
  my $t = strip($raw);
  # The span of `enum ModelWarmup`'s body, in the coordinates of the STRIPPED text.
  if ($t =~ /enum\s+ModelWarmup\b[^{]*\{/s) {
    my $o = index($t, '{', $-[0]); my $d = 0; my $e = -1;
    for my $p ($o .. length($t) - 1) {
      my $c = substr($t, $p, 1); $d++ if $c eq '{'; $d-- if $c eq '}';
      if (!$d) { $e = $p; last }
    }
    $warmup_body_span{$f} = [$o, $e] if $e > 0;
  }
  for my $type (@TYPES) {
    pos($t) = 0;
    while ($t =~ /\b\Q$type\E\s*[({]/g) {
      my $st = $-[0];
      # A DECLARATION (`actor X {`, `class X {`, `struct X(`, …) is not a construction.
      my $head = substr($t, ($st > 40 ? $st - 40 : 0), ($st > 40 ? 40 : $st));
      next if $head =~ /\b(?:actor|class|struct|enum|extension|protocol|typealias)\s+$/;
      push @{ $sites{$type} }, [$f, $st];
    }
  }
}
for my $type (@TYPES) {
  my ($app, $warm) = (0, 0); my %byfile;
  for my $s (@{ $sites{$type} || [] }) {
    my ($f, $off) = @$s;
    my $sp = $warmup_body_span{$f};
    if ($sp && $off > $sp->[0] && $off < $sp->[1]) { $warm++ } else { $app++; $byfile{$f}++ }
  }
  print "SCAN type=$type total=" . scalar(@{ $sites{$type} || [] })
      . " app=$app warmup=$warm files=";
  print join(',', map { "$_=$byfile{$_}" } sort keys %byfile);
  print "\n";
}
exit 0;
CORPUS_SCAN_PL
scan_corpus() { build_corpus >/dev/null; perl "$work/corpus_scan.pl" "$work/corpus"; }

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

# IDEMPOTENCE du handover, proofed STRUCTURELLEMENT, sur le DELEGATE ENTIER. Exige :
#   (a) une comparaison de la propriété `controlServer` à `nil` (le serveur, pas un paramètre),
#       dans le corps de `configureControlServer` ;
#   (b) une SORTIE ANTICIPÉE sur le chemin « déjà configuré » : `guard … else { return }`, ou
#       `else { return }`, dans ce même corps ;
#   (c) AUCUNE construction `TranscriptControlServer(` en dehors de la branche qui crée — ET
#       aucune construction HORS du corps de `configureControlServer`, dans tout le delegate.
# (c) est ce qui ferme la portée : le contrôle ne jugeait que le corps de la méthode nommée, donc
# un SECOND point d'entrée (`reconfigureControlServer`, appelé par le menu) qui faisait `stop()`
# puis reconstruisait et redémarrait un serveur neuf laissait les cinq contrôles `delegate-*`
# verts (mesuré : VERT contrôle=delegate-handover-idempotent, 26/26 — F3 de la revue round 2).
# C'est le critère 2 qui parle de « une seconde CONFIGURATION », donc de tous les chemins qui
# configurent, pas d'un seul nom de méthode.
# Un handover non idempotent qui reconstruit un serveur à chaque appel viole (b) — son `if … { log }`
# ne retourne pas — et (c) le vérifie séparément. Sort 0 = idempotent, 1 = défaut, 2 = indécidable.
cat >"$work/handover_idem.pl" <<'HANDOVER_IDEM_PL'
use strict; use warnings;
local $/; my $x = <STDIN> // '';
$x =~ s{/\*.*?\*/}{}gs; $x =~ s{//[^\n]*}{}g;

# Le corps de `configureControlServer` : [début, fin] des ACCOLADES de sa définition. Sans lui on
# ne peut pas distinguer « le handover » de « le delegate », qui est la portée du critère 2.
my ($cfg_o, $cfg_e);
if ($x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|class|static|final|mutating)[ \t]+)*func[ \t]+configureControlServer\b[^{]*\{/m) {
  my $o = index($x, '{', $-[0]); my $d = 0; my $e = -1;
  for my $p ($o .. length($x) - 1) {
    my $c = substr($x, $p, 1); $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  ($cfg_o, $cfg_e) = ($o, $e) if $e > 0;
}
if (!defined $cfg_o) { print STDERR "handover: configureControlServer introuvable ou illisible\n"; exit 2 }

# Every `TranscriptControlServer(` CONSTRUCTION offset in the WHOLE delegate, and the spans of the
# branches. Une construction hors du corps de `configureControlServer` est le défaut (c).
my @constr;
while ($x =~ /\bTranscriptControlServer\s*\(/g) { push @constr, $-[0] }
exit 2 unless @constr;                     # no construction at all -> nothing to guard
# Spans of `if <cond involving controlServer == nil> { … } [else { … }]`
my @create_branches;
# Each guard is recorded as [debut_condition, fin_condition, debut_bloc_else, fin_bloc_else].
my @guards;
while ($x =~ /\bguard\b([^;{]*?)\belse\b\s*\{/gs) {
  my $st = $-[0]; my $en = $+[0];
  my $o = $en - 1; my $d = 0; my $e = -1;
  for my $p ($o .. length($x) - 1) {
    my $c = substr($x, $p, 1); $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  push @guards, [$st, $en, $o, $e];
}
while ($x =~ /\bif\b([^{]*?)\{/gs) {
  my $st = $-[0]; my $en = $+[0];
  my $cond = substr($x, $st + 2, $en - $st - 3);
  next unless $cond =~ /controlServer\s*==\s*nil/;
  my $o = $en - 1; my $d = 0; my $e = -1;
  for my $p ($o .. length($x) - 1) {
    my $c = substr($x, $p, 1); $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  next if $e < 0;
  push @create_branches, [$st, $en, $o, $e];
  # the `else` branch, if any, with its span
  if (substr($x, $e + 1) =~ /^\s*else\b\s*\{/s) {
    my $eo = index($x, '{', $e + 1);
    my $ed = 0; my $ee = -1;
    for my $p ($eo .. length($x) - 1) {
      my $c = substr($x, $p, 1); $ed++ if $c eq '{'; $ed-- if $c eq '}';
      if (!$ed) { $ee = $p; last }
    }
    push @guards, [$e + 1, $eo + 1, $eo, $ee] if $ee > 0;
  }
}
# (a) a guard whose CONDITION — the text BETWEEN `guard` and `else` — compares the server property,
#     AND whose whole span is inside `configureControlServer`.
my $cond_guard = 0;
for my $g (@guards) {
  next unless $g->[0] > $cfg_o && $g->[0] < $cfg_e;
  my $cond = substr($x, $g->[0], $g->[1] - $g->[0]);
  $cond_guard = 1 if $cond =~ /controlServer\s*(?:==|!=)\s*nil/;
}
# (b) an EARLY RETURN on the already-configured path: the `else` block that follows the guard, or
#     the `else` of the nil-branch, must START with `return`.
my $early = 0;
for my $g (@guards) {
  next if $g->[3] < 0;
  next unless $g->[0] > $cfg_o && $g->[0] < $cfg_e;
  my $else_body = substr($x, $g->[2] + 1, $g->[3] - $g->[2] - 1);
  $early = 1 if $else_body =~ /^\s*return\b/s;
}
# (c) every construction inside the nil-branch, or after a guard that is BOTH on the property AND
#     early-returning — and inside `configureControlServer` in ALL cases. Without that conjonction,
# ` constructions_gardees=1` sortait vert même sans aucune garde (mesuré sur le mutant non
# idempotent) : un contrôle ne doit pas être vert par défaut.
my $enclosed = 1;
my $early_guard_end = -1;
for my $g (@guards) {
  next if $g->[3] < 0;
  next unless $g->[0] > $cfg_o && $g->[0] < $cfg_e;
  my $else_body = substr($x, $g->[2] + 1, $g->[3] - $g->[2] - 1);
  my $cond = substr($x, $g->[0], $g->[1] - $g->[0]);
  next unless $else_body =~ /^\s*return\b/s;
  next unless $cond =~ /controlServer\s*(?:==|!=)\s*nil/;
  $early_guard_end = $g->[3] if $g->[3] > $early_guard_end;
}
my $hors_corps = 0;
for my $c (@constr) {
  # Sans garde properties-correcte, AUCUNE construction n'est « gardée » : `(c)` ne doit pas être
  # vert par défaut (mesuré : il l'était, `$early_guard_end` valant -1 et tout offset étant > -1).
  my $dans_corps = ($c > $cfg_o && $c < $cfg_e) ? 1 : 0;
  $hors_corps++ unless $dans_corps;
  my $inside = ($early_guard_end >= 0 && $c > $early_guard_end) ? 1 : 0;
  for my $br (@create_branches) { $inside = 1 if $c > $br->[2] && $c < $br->[3] }
  $enclosed = 0 unless $inside;
}
print STDERR "handover: constructions=" . scalar(@constr)
  . " hors_configureControlServer=$hors_corps"
  . " garde_condition=$cond_guard sortie_anticipee=$early constructions_gardees=$enclosed\n";
exit(($cond_guard && $early && $enclosed && $hors_corps == 0) ? 0 : 1);
HANDOVER_IDEM_PL

# LE DÉMARRAGE, « EXACTEMENT UNE FOIS » — ce que le critère 2 dit et ce qu'aucun contrôle ne
# mesurait. `one-control-server-construction` compte les CONSTRUCTIONS ; or `start()` n'est pas
# idempotent (`lierEtEcouter()` fait `unlink` PUIS `bind`), donc c'est le DÉMARRAGE qui doit être
# unique, pas la construction. Mesuré par la revue round 4 sur un assemblage COMPILÉ : deux
# sondes, `BUILD SUCCEEDED` et CONTRÔLE=27/27 avec les six contrôles du critère 2 verts —
#   S10 : la garde `if applicationLaunched` du handover devient un appel nu ;
#   S6  : un second `start()` dans `applicationDidBecomeActive`.
# Le chemin qui rend le démarrage unique dans la référence est EXCLUSIF : le `start()` du
# handover est gardé par un drapeau mis à `true` DANS `applicationDidFinishLaunching`, donc
# « handover avant lancement » et « handover après lancement » ne peuvent pas se cumuler.
#   * handover AVANT : le drapeau est faux → pas de start ici ; `applicationDidFinishLaunching`
#     démarre.   * handover APRÈS : le `start()` du lancement portait sur un serveur `nil`
#     (no-op) ; le handover démarre.   Jamais deux.
# On exige donc, sur le delegate ENTIER : exactement un site `start()` dans
# `applicationDidFinishLaunching` (le chemin Finder), au moins un site ailleurs — sans lui, un
# handover arrivé APRÈS le lancement ne démarrerait jamais — et TOUS les autres sites gardés par un
# drapeau de lancement. Un site non gardé est un second démarrage garanti au premier retour dans
# l'app : le serveur vole son propre socket à lui-même.
#
# LIMITE DÉCLARÉE, pour ne pas surjouer : ce contrôle ne détecte pas un drapeau de garde qui ne
# serait jamais mis à `true` — le handover deviendrait mort et le serveur ne démarrerait jamais.
# Ce cas-là appartient à la gate d'EXECUTION, qui CONSTATE le socket absent dans la fenêtre du
# §2.5 : c'est une observation du monde, pas une lecture de source, et c'est la seule des deux
# qui voie l'ordre réel des deux événements.
#
# La portée s'arrête au delegate PAR CONSTRUCTION, pas par commodité : le serveur n'est construit
# qu'une fois dans l'app (`one-control-server-construction`), et le handover ne transmet que le
# submitteur et le status provider — jamais le serveur. Aucun autre type ne peut donc garder un
# second pointeur vers CE serveur. Sort 0 = démarré exactement une fois, 1 = défaut, 2 = indécidable.
cat >"$work/start_once.pl" <<'START_ONCE_PL'
use strict; use warnings;
local $/; my $x = <STDIN> // '';
$x =~ s{/\*.*?\*/}{}gs; $x =~ s{//[^\n]*}{}g;
exit 2 unless length $x;

# 1. Les propriétés du delegate qui SONT des serveurs de contrôle. On ne devine pas le nom :
# `start()` n'est compté que sur un récepteur dont le TYPE est `TranscriptControlServer?`, donc
# un `recorder.start()` ou un `engine.start()` du delegate n'entre pas dans le décompte.
my @props;
while ($x =~ /\bvar\s+([A-Za-z_]\w*)\s*:\s*TranscriptControlServer\?/g) { push @props, $1 }
if (!@props) { print STDERR "start_once: aucune propriété TranscriptControlServer? dans le delegate\n"; exit 2 }

# 2. Le corps de `applicationDidFinishLaunching` : c'est le CHEMIN FINDER, celui que la gate
#    d'exécution ouvre par LaunchServices. Sans ce corps, « démarré une fois » n'a pas de sens.
my ($lo, $hi);
if ($x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|class|static|final|mutating)[ \t]+)*func[ \t]+applicationDidFinishLaunching\b[^\n{(]*[(<][^{]*\{/m) {
  my $o = index($x, '{', $-[0]); my $d = 0; my $e = -1;
  for my $p ($o .. length($x) - 1) {
    my $c = substr($x, $p, 1); $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  ($lo, $hi) = ($o, $e) if $e > 0;
}
if (!defined $lo) { print STDERR "start_once: applicationDidFinishLaunching introuvable ou illisible\n"; exit 2 }

# 3. Les DRAPEAUX de lancement : un booléen mis à `true` DANS le corps ci-dessus. C'est ce qui
#    rend les deux sites exclusifs, donc c'est ce qu'on cherche.
my %flag;
# Le corps est COPIÉ dans un lexique avant le `/g` : faire correspondre `/g` sur un `substr()`
# en LVALUE (`while (substr($x, …) =~ /…/g)`) est une boucle infinie — le motif est évalué
# sur une cible dont `pos` est sans cesse réinitialisé (mesuré : le perl ne rendait pas, et le
# contrat entier pendait avec lui, sans message). Le lexique rend la boucle finie.
my $launch_body = substr($x, $lo, $hi - $lo);
while ($launch_body =~ /([A-Za-z_]\w*)\s*=\s*true\b/g) { $flag{$1} = 1 }

# 4. Les sites `start()` du delegate, sur les récepteurs typés ci-dessus.
my @sites;
for my $p (@props) {
  pos($x) = 0;
  while ($x =~ /\b\Q$p\E\s*\??\s*\.\s*start\s*\(\s*\)/g) { push @sites, $-[0] }
}
if (!@sites) { print STDERR "start_once: aucun start() sur le serveur du delegate\n"; exit 2 }
@sites = sort { $a <=> $b } @sites;

# 5. Les en-têtes conditionnels du delegate : le texte du site est-il sous une condition de
#    LANCEMENT (`if <drapeau> { … }`) ou derrière une sortie anticipée par ce drapeau
#    (`guard <drapeau> else { return }`) ? Les DEUX écritures sont admises : un DEV ne doit pas
#    se voir rouge pour avoir choisi la seconde.
my @head;
while ($x =~ /\b(?:if|guard)\b([^{;]*?)\{/gs) {
  my $st = $-[0]; my $cond = $1; my $ob = $+[0] - 1;
  my $d = 0; my $e = -1;
  for my $p ($ob .. length($x) - 1) {
    my $c = substr($x, $p, 1); $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  next if $e < 0;
  push @head, [$st, $e, $cond, $ob];
}
my $launch = 0; my @other;
for my $s (@sites) { if ($s > $lo && $s < $hi) { $launch++ } else { push @other, $s } }
my $unguarded = 0;
for my $s (@other) {
  my $ok = 0;
  for my $h (@head) {
    next unless $s > $h->[0] && $s < $h->[1];
    for my $f (keys %flag) { $ok = 1 if $h->[2] =~ /\b\Q$f\E\b/ }
  }
  if (!$ok) {
    # `guard <drapeau> else { return }` terminé juste avant le site, sans autre en-tête entre
    # les deux : le site est encore sous la garde, écrit à l'envers.
    for my $h (@head) {
      next if $h->[1] > $s;
      my $txt = substr($x, $h->[0], $h->[1] - $h->[0]);
      next unless $txt =~ /else\s*\{\s*return\b/s;
      my $hit = 0;
      for my $f (keys %flag) { $hit = 1 if $txt =~ /\b\Q$f\E\b/ }
      next unless $hit;
      my $intercale = 0;
      for my $g (@head) { $intercale = 1 if $g->[0] > $h->[1] && $g->[0] < $s }
      $ok = 1 unless $intercale;
    }
  }
  $unguarded++ unless $ok;
}
print STDERR "start_once: sites=" . scalar(@sites) . " dans_applicationDidFinishLaunching=$launch"
  . " autres=" . scalar(@other) . " non_gardes=$unguarded"
  . " drapeaux=" . join(',', sort keys %flag) . "\n";
# Un seul site de lancement, au moins un site de handover (sinon un handover arrivé APRÈS le
# lancement ne démarre jamais le serveur), et aucun site de handover non gardé.
exit(($launch == 1 && @other >= 1 && $unguarded == 0) ? 0 : 1);
START_ONCE_PL

# L'ARGUMENT de `loadedModelForVideo`, lu sur le texte ENTIER, sur TOUS les fichiers du corpus.
# Le `sed` ligne à ligne d'avant renvoyait une chaîne VIDE sur un appel multi-lignes — et le shell
# traitait cette absence comme « défaut conforme », donc `dedicatingComputeUnits: true` passait
# (mesuré, 26/26) ; et une version plus récente lisait le SEUL panneau, si bien qu'un second chemin
# vidéo ailleurs dans `Murmure/` passait aussi (mesuré 26/26, revue round 3). Ici :
#   * le motif porte `\s*` après le nom, donc l'appel est trouvé quelle que soit sa mise en page ;
#   * les parenthèses de l'ARGUMENT sont ÉQUILIBRÉES, pas capturées par `[^)]*` ;
#   * TOUS les sites d'appel du corpus sont lus, chacun avec son fichier ;
#   * la DÉCLARATION de `WhisperKitEngine.swift:331` est exclue par son `func` — la lire comme un
#     appel rendrait le contrôle rouge sur du code correct ;
#   * sortie : `VIDEO file=<chemin> arg=<texte normalisé>`, `AUCUN` si l'appel est sans argument
#     (il prend alors la valeur par défaut `false`), `IMBALANCE` s'il est illisible.
# Un retour illisible est une VALEUR, jamais un vide confiant : le shell le traite en rouge.
cat >"$work/video_scan.pl" <<'VIDEO_SCAN_PL'
use strict; use warnings;
my $dir = $ARGV[0];
my @files;
sub walk {
  my ($d, $prefix) = @_;
  opendir(my $dh, $d) or return;
  for my $e (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
    my $full = "$d/$e";
    if (-d $full) { walk($full, "$prefix$e/") }
    elsif ($e =~ /\.swift$/) { push @files, "$prefix$e" }
  }
  closedir $dh;
}
walk($dir, '');
exit 2 unless @files;
# EVERY `loadedModelForVideo` CALL in the corpus, not only the pane's. Criterion 1 is about the
# POLICY — no video path may ask for a dedicated engine — and reading only `TranscriptsPaneModel`
# left a second video path anywhere else in `Murmure/` free to ask for one (measured 26/26 by the
# round-3 review). The corpus is the same recursive scope the construction counts use.
for my $f (@files) {
  open(my $fh, '<', "$dir/$f") or next;
  my $raw = do { local $/; <$fh> }; close $fh;
  $raw =~ s{/\*.*?\*/}{}gs; $raw =~ s{//[^\n]*}{}g;
  # The DEFAULT of the parameter, read from the DECLARATION. A call site with no argument is
  # conformant ONLY because the default is `false` — and until now the contract ASSERED that
  # default instead of reading it, so it was true merely because `WhisperKitEngine.swift` is
  # frozen (the round-4 review's non-blocking F2, measured as mutant S9: the call loses its
  # argument AND the default becomes `true` — a dedicated engine, the second instance criterion 1
  # forbids — and the control stayed green, 27/27). An unverified claim about someone else's file
  # is not a control: the default is read HERE, and an unreadable one is RED, never a silent pass.
  pos($raw) = 0;
  while ($raw =~ /\bfunc\s+loadedModelForVideo\s*\(/g) {
    my $o = index($raw, '(', $-[0]);
    my $d = 0; my $e = -1;
    for my $p ($o .. length($raw) - 1) {
      my $c = substr($raw, $p, 1); $d++ if $c eq '('; $d-- if $c eq ')';
      if (!$d) { $e = $p; last }
    }
    last if $e < 0;
    my $sig = substr($raw, $o + 1, $e - $o - 1);
    $sig =~ s/\s+/ /g;
    if ($sig =~ /dedicatingComputeUnits\s*:\s*Bool\s*=\s*(\S+?)\s*$/) { print "DEF default=$1\n" }
    elsif ($sig =~ /dedicatingComputeUnits\s*:\s*Bool\b/)         { print "DEF default=AUCUN\n" }
    else                                                          { print "DEF default=ILLISIBLE\n" }
    last;
  }
  pos($raw) = 0;
  while ($raw =~ /\bloadedModelForVideo\s*\(/g) {
    my $st = $-[0];
    # The DECLARATION in `WhisperKitEngine.swift` is not a call: it carries the default value the
    # criterion relies on, and reading it as a call site would make the control red on correct code.
    my $head = substr($raw, ($st > 60 ? $st - 60 : 0), ($st > 60 ? 60 : $st));
    next if $head =~ /\bfunc\s+$/;
    my $o = index($raw, '(', $st);
    my $d = 0; my $e = -1;
    for my $p ($o .. length($raw) - 1) {
      my $c = substr($raw, $p, 1);
      $d++ if $c eq '('; $d-- if $c eq ')';
      if (!$d) { $e = $p; last }
    }
    if ($e < 0) { print "VIDEO file=$f arg=IMBALANCE\n"; next }
    my $args = substr($raw, $o + 1, $e - $o - 1);
    $args =~ s/\s+/ /g; $args =~ s/^ //; $args =~ s/ $//;
    $args = 'AUCUN' if $args eq '';
    print "VIDEO file=$f arg=$args\n";
  }
}
exit 0;
VIDEO_SCAN_PL
scan_video() { build_corpus >/dev/null; perl "$work/video_scan.pl" "$work/corpus"; }

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
  # IDEMPOTENCE —structurelle, pas lexicale, et sur le DELEGATE ENTIER. Un `if controlServer ==
  # nil { log.info(…) }` qui ne retourne PAS fait passer un grep `== nil` alors qu'un
  # `TranscriptControlServer(…)` non gardé construit un second serveur à chaque configuration :
  # c'est exactement le défaut du critère 2, et une version antérieure de ce contrôle le laissait
  # passer (mesuré, 24/24). Le contrôle exige donc, dans le corps de `configureControlServer` : une
  # comparaison sur la PROPRIÉTÉ `controlServer`, une SORTIE ANTICIPÉE (`guard … else { return }`,
  # ou un `else { return }`), et — sur TOUT le delegate — AUCUNE construction de serveur hors de
  # cette branche et hors de ce corps. La dernière clause est ce qui interdit un second point
  # d'entrée qui reconstruit (mesuré : `reconfigureControlServer` laissait ce contrôle VERT,
  # 26/26 — F3 de la revue round 2) ; c'est elle qui donne au contrôle sa portée de critère.
  printf '%s' "$delegate" | perl "$work/handover_idem.pl"; check delegate-handover-idempotent "$?" \
    "le delegate n'est pas idempotent : une seconde configuration créerait un second serveur"
  # The server is a PROPERTY of the delegate, not something it builds per call.
  printf '%s' "$delegate" | grep -qE 'var[[:space:]]+[A-Za-z_]*[Ss]erver[^\n]*:[[:space:]]*TranscriptControlServer\?'; \
    check delegate-owns-server "$?" "le delegate ne possède pas le serveur comme propriété"
  # LE DÉMARRAGE, exactement une fois — le mot du critère 2 que les contrôles voisins ne
  # mesuraient pas. `delegate-starts-server` vérifie la PRÉSENCE d'un `start()` dans
  # `applicationDidFinishLaunching`, et `one-control-server-construction` compte les
  # CONSTRUCTIONS ; ni l'un ni l'autre ne voit un serveur démarré deux fois, alors que
  # `start()` n'est pas idempotent (`lierEtEcouter()` : `unlink` PUIS `bind` — le second
  # démarrage vole le socket au premier, et le `stop()` du premier supprime le nom du socket
  # du second). Mesuré par la revue round 4 sur un assemblage COMPILÉ : la garde
  # `if applicationLaunched` du handover transformée en appel nu, et un second `start()` dans
  # `applicationDidBecomeActive`, donnaient tous deux `BUILD SUCCEEDED` et CONTRÔLE=27/27 avec
  # les SIX contrôles du critère 2 verts. Aucun des 13 mutants ne pouvait l'attraper : il n'y
  # avait rien à attraper.
  start_reason=$(printf '%s' "$delegate" | perl "$work/start_once.pl" 2>&1); start_rc=$?
  [[ "$start_rc" -eq 0 ]]; check one-control-server-start "$start_rc" \
    "le serveur n'est pas démarré exactement une fois : ${start_reason:-lecture impossible}"
else
  for c in delegate-starts-server delegate-stops-server delegate-configure-handover \
           delegate-handover-idempotent delegate-owns-server one-control-server-start; do
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
# Criterion 1: exactly ONE `WhisperKitEngine(` CONSTRUCTION in the whole APP, and it is the
# dictation's. The scope is the CORPUS (every `Murmure/*.swift` of the tree under test), not two
# filenames: a second engine in `MurmureApp.swift` left both former controls green (measured,
# 24/24) while breaking the criterion.
#
# The construction form is `WhisperKitEngine(` or `WhisperKitEngine {`; a bare type mention (a
# parameter annotation) and the `actor WhisperKitEngine {` DECLARATION are not constructions.
# ONE legitimate exception exists and is not a filename convention: `ModelWarmup` is the
# `--prepare-model` bootstrap tool, a different process from the same binary that exits before
# SwiftUI exists (`MurmureApp.swift:28`). It is counted separately by the scan and excluded BY ITS
# DECLARATION, never by its file name — and `one-engine-warmup-is-bootstrap` proves the exclusion
# is still true: the warm-up body must not be reachable from the app's own graph.
if [[ -n "$pane_file" && -n "$dictation_file" ]]; then
  scan=$(scan_corpus || true)
  eng_line=$(grep -E '^SCAN type=WhisperKitEngine ' <<<"$scan" || true)
  que_line=$(grep -E '^SCAN type=TranscriptQueue ' <<<"$scan" || true)
  srv_line=$(grep -E '^SCAN type=TranscriptControlServer ' <<<"$scan" || true)
  printf 'SCAN >> %s | %s\n' "$eng_line" "$que_line"
  printf 'SCAN >> %s\n' "$srv_line"
  eng_app=$(sed -n 's/.* app=\([0-9]*\) .*/\1/p' <<<"$eng_line")
  que_app=$(sed -n 's/.* app=\([0-9]*\) .*/\1/p' <<<"$que_line")
  srv_app=$(sed -n 's/.* app=\([0-9]*\) .*/\1/p' <<<"$srv_line")
  # L'attribution à un fichier se fait sur une ENTRÉE EXACTE de la liste `files=`, jamais sur un
  # `*DictationController.swift=1*` : les chemins sont maintenant relatifs et `Views/X.swift`
  # produirait la même sous-chaîne qu'un `X.swift` à la racine. `grep -cx` compare la ligne
  # entière, donc un fichier homonyme dans un sous-dossier ne peut pas se faire passer pour
  # l'original — et un second moteur dans ce sous-dossier se voit justement parce qu'il compte.
  eng_dict=$(sed -n 's/.* files=//p' <<<"$eng_line" | tr ',' '\n' | grep -cx 'DictationController.swift=1' || true)
  que_pane=$(sed -n 's/.* files=//p' <<<"$que_line" | tr ',' '\n' | grep -cx 'TranscriptsPaneModel.swift=1' || true)
  # The app's single engine is the dictation's, and it is only that one.
  [[ "${eng_app:-0}" -eq 1 && "${eng_dict:-0}" -eq 1 ]]; check one-engine-construction "$?" \
    "constructions de WhisperKitEngine dans l'app=$eng_app (dictation=$eng_dict) — 1 attendue, dans la dictée ($eng_line)"
  # The warm-up exclusion stays an exclusion: its engine lives in `ModelWarmup`, which only
  # `Launch.main` calls, and only behind the `--prepare-model` flag.
  warm_body=$(body_for 'enum ModelWarmup' "$(clean_of <"$work/corpus/ModelWarmup.swift" 2>/dev/null || printf '')" || true)
  warm_engine=$(printf '%s' "$warm_body" | perl -ne '$n+=()=/WhisperKitEngine\s*[({]/g; END{print $n+0}')
  app_calls_warmup=0
  if [[ -s "$work/corpus/MurmureApp.swift" ]]; then
    clean_of <"$work/corpus/MurmureApp.swift" | grep -qE 'ModelWarmup\.run\(\)' \
      && ! clean_of <"$work/corpus/MurmureApp.swift" | grep -qE 'CommandLine\.arguments\.contains\(ModelWarmup\.flag\)' \
      && app_calls_warmup=1
  fi
  [[ "${warm_engine:-0}" -le 1 && "$app_calls_warmup" -eq 0 ]]; check one-engine-warmup-is-bootstrap "$?" \
    "moteurs dans le corps de ModelWarmup=${warm_engine:-0} (1 max, l'outil --prepare-model) ; appel sans garde de drapeau=$app_calls_warmup"
  # Criterion 1, POLITIQUE: the video path must ask for the DEFAULT compute units. `true` takes a
  # wholly different branch in `WhisperKitEngine.loadedModelForVideo` (dedicated model out of
  # `cachedModelFolder`, `Failure.modelNotOnDisk`) — the SECOND instance the criterion forbids. The
  # argument is therefore READ, not merely the shape of the call (measured: `dedicatingComputeUnits:
  # true` passed 24/24 before this control existed).
  # And the video reuses the RECEIVED engine: the call is made on `engine`, the injected property.
  printf '%s' "$pane" | grep -qE 'engine\.loadedModelForVideo\('; check video-uses-shared-engine "$?" \
    "la vidéo n'appelle pas loadedModelForVideo sur le moteur reçu"
  # L'argument est LU sur le TEXTE DÉCOMMENTÉ COMPLET, pas ligne par ligne. Un `sed` par ligne
  # (`s/.*loadedModelForVideo(\([^)]*\)).*/\1/p`) renvoyait la chaîne VIDE sur un appel écrit en
  # plusieurs lignes — cas réel : le dépôt compte 509 lignes > 100 caractères dans `Murmure/*.swift`
  # — et le script déclarait alors l'absence d'argument « conforme » : mesuré, un
  # `dedicatingComputeUnits: true` sur un appel multi-lignes passait 26/26 (F1 de la revue round 2).
  # `mutant-dedicated-compute` ne le voyait pas non plus : il substitue `false`→`true` EN PLACE,
  # donc forcément sur une ligne. Le motif porte `\s`, l'extraction équilibre les parenthèses, et
  # un argument ILLISIBLE est ROUGE — jamais un « défaut conforme » par défaut de lecture.
  #
  # Un appel SANS argument reste conforme : il prend la valeur par défaut de
  # `loadedModelForVideo(dedicatingComputeUnits: Bool = false)` (`WhisperKitEngine.swift:331`).
  # Le contrat n'exige donc pas une écriture particulière au DEV.
  #
  # ET il est lu sur TOUT le corpus, pas sur le seul panneau. Le critère 1 porte sur la POLITIQUE
  # d'instance — « aucun chemin vidéo ne réclame un moteur dédié » — donc un second chemin vidéo
  # ailleurs dans `Murmure/` doit être lu aussi : mesuré par la revue round 3, un
  # `dedicatingComputeUnits: true` dans `Murmure/Views/` laissait ce contrôle VERT (26/26). La
  # DÉCLARATION de `WhisperKitEngine.swift:331` est exclue par son `func` — la lire comme un site
  # d'appel rendrait le contrôle rouge sur du code correct.
  video_lines=$(scan_video || true)
  printf 'VIDEO >> %s\n' "$(tr '\n' '|' <<<"$video_lines")"
  # Le DÉFAUT de la DÉCLARATION, lu et non supposé. Un appel SANS argument n'est conforme que si
  # ce défaut vaut `false`; le contrat l'affirmait sans le vérifier, donc il était vrai parce que
  # `WhisperKitEngine.swift` est FIGÉ, pas parce que le contrôle le mesurait (F2 non bloquant de
  # la revue round 4, mesuré en S9 : l'appel perd son argument ET le défaut passe à `true`, la
  # vidéo réclame alors un moteur dédié — la seconde instance du critère 1 — et le contrôle
  # restant vert, 27/27). Un défaut ILLISIBLE ou absent est ROUGE : on ne peut pas valider au
  # doigt une politique qu'on n'a pas lue.
  video_default=$(sed -n 's/^DEF default=//p' <<<"$video_lines" | head -1)
  [[ -n "$video_default" ]] || video_default=ABSENT
  printf 'VIDEO default_declaration=%s\n' "$video_default"
  video_policy=0; video_why=""
  # AUCUN site deappel : le contrôle rouge, on ne peut pas lire une politique qui n'est pas écrite.
  if [[ -z "$video_lines" ]]; then
    video_policy=1; video_why="aucun appel à loadedModelForVideo dans Murmure/ — la politique de la vidéo n'est pas écrite" ;
  else
    while IFS= read -r vl; do
      [[ -n "$vl" ]] || continue
      case "$vl" in
        DEF\ *) continue ;;
      esac
      vfile=${vl#*file=}; vfile=${vfile%% *}
      varg=${vl##*arg=}
      case "$varg" in
        IMBALANCE)
          video_policy=1; video_why="$vfile : parenthèses non équilibrées, l'argument ne peut pas être lu — un argument illisible n'est pas un argument conforme" ;;
        AUCUN)
          if [[ "$video_default" == false ]]; then
            video_why="${video_why:+$video_why ; }$vfile : appel sans argument → défaut lu de la déclaration = false"
          else
            video_policy=1; video_why="$vfile : appel sans argument, et le défaut de la déclaration est « $video_default » (false attendu, lu et non supposé)"
          fi ;;
        *dedicatingComputeUnits:false*|*'dedicatingComputeUnits: false'*|*'dedicatingComputeUnits : false'*)
          video_why="${video_why:+$video_why ; }$vfile : dedicatingComputeUnits: false (moteur partagé)" ;;
        *)
          video_policy=1; video_why="$vfile : dedicatingComputeUnits EXPLICITE et non false" ;;
      esac
    done <<<"$video_lines"
  fi
  check video-compute-not-dedicated "$video_policy" \
    "sites de lecture=$video_why"
  # One queue: the pane's, and only that one — counted over the corpus too.
  [[ "${que_app:-0}" -eq 1 && "${que_pane:-0}" -eq 1 ]]; check one-queue-construction "$?" \
    "constructions de TranscriptQueue dans l'app=$que_app (panneau=$que_pane) — exactement 1, dans le panneau ($que_line)"
  # ONE server in the app, and it is the delegate's. Criterion 2 (plan l. 1269) : « le serveur est
  # démarré EXACTEMENT une fois ». C'est le contrôle qui porte ce « exactement une fois » SANS
  # restriction de site : avant lui, le comptage des serveurs n'existait nulle part (le delegate
  # entier pour l'idempotence, `$pane`/`$server` pour le moteur et la file) — mesuré par la revue
  # round 3, un second serveur BIEN TYPÉ, construit ET démarré dans `MurmureApp.swift`, laissait
  # 26/26 avec les trois contrôles du critère 2 verts, sur un assemblage COMPILÉ.
  #
  # Ce n'est pas un strawman. `start()` n'est pas idempotent : `lierEtEcouter()` fait `unlink` PUIS
  # `bind`, donc un second serveur ne échoue pas — il VOLE le socket au premier, et le `stop()` du
  # premier supprime alors le nom du socket du second. Le symptôme est « le socket disparaît après
  # une action de l'app », la classe de bug que le critère 2 interdit.
  srv_delegate=$(sed -n 's/.* files=//p' <<<"$srv_line" | tr ',' '\n' | grep -cx 'AppDelegate.swift=1' || true)
  [[ "${srv_app:-0}" -eq 1 && "${srv_delegate:-0}" -eq 1 ]]; check one-control-server-construction "$?" \
    "constructions de TranscriptControlServer dans l'app=${srv_app:-0} (delegate=${srv_delegate:-0}) — exactement 1, dans le delegate ($srv_line)"
  printf '%s' "$server" | perl -ne '$n+=()=/TranscriptQueue\s*[({]/g; exit($n>0)'; check server-no-queue "$?" \
    "le serveur construit une file"
else
  for c in one-engine-construction one-engine-warmup-is-bootstrap video-uses-shared-engine \
           video-compute-not-dedicated one-queue-construction one-control-server-construction \
           server-no-queue; do
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
  # L'IDENTITÉ DE SIGNATURE est une exigence de la gate (§4 du lot 11-S : « un bundle Release
  # signé/chargé »), et elle manquait entièrement. Un bundle `TeamIdentifier=not set` est une
  # application SANS identité stable : son empreinte dérive des octets du binaire, donc chaque
  # reconstruction est une application DIFFÉRENTE pour macOS et aucune autorisation ne lui est
  # réaccordée. Un vert obtenu sur un tel bundle ne prouve pas le chemin Finder — il prouve qu'un
  # serveur a démarré dans un processus que macOS ne connaît pas. Mesuré : les deux builds de la
  # nuit du 25 au 26 (`.assemblage-11s`, `.assemblage-11s-vert`) sortaient `Signature=adhoc`,
  # `TeamIdentifier=not set`. L'identité est donc résolue avant la construction, et le bundle
  # construit est VÉRIFIÉ après coup : c'est le bundle ouvert, pas l'intention, qui est contrôlé.
  local sign_id="${MURMURE_CODESIGN_IDENTITY:-}"
  if [[ -z "$sign_id" ]]; then
    sign_id=$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*) \([0-9A-F]\{40\}\) ".*".*/\1/p' | head -1)
  fi
  printf 'BUILD identité=%s\n' "${sign_id:-AUCUNE}"
  if [[ -z "$sign_id" ]]; then
    build_rc=65
    printf 'error: aucune identité de signature résolutionnable (security find-identity -v -p codesigning)\n' \
      >"$work/build.log"
  elif [[ -f "$TEST_ROOT/project.yml" && -d "$TEST_ROOT/Murmure" ]]; then
    ( cd "$TEST_ROOT" && xcodebuild -project Murmure.xcodeproj -scheme Murmure \
        -configuration Release -derivedDataPath "$work/dd" \
        CODE_SIGN_IDENTITY="$sign_id" CODE_SIGN_STYLE=Manual build ) >"$work/build.log" 2>&1
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
  # L'identité est contrôlée SUR LE BUNDLE COPIÉ, donc sur celui qui va être ouvert. `codesign -dv`
  # sort sur stderr : sans `2>&1` la mesure ne verrait rien et le contrôle serait vert par défaut.
  local codesign_out team
  codesign_out=$(codesign -dv --verbose=2 "$app" 2>&1 || true)
  team=$(sed -n 's/^TeamIdentifier=//p' <<<"$codesign_out" | head -1)
  printf 'FINDER signature bundle=%s TeamIdentifier=%s\n' \
    "$(sed -n 's/^Signature=//p' <<<"$codesign_out" | head -1)" "${team:-absent}"
  [[ -n "$team" && "$team" != 'not set' && "$team" != '(null)' ]]; check finder-bundle-signe "$?" \
    "TeamIdentifier=${team:-absent} : bundle sans identité stable, chaque reconstruction est une application différente pour macOS — le chemin Finder n'est pas prouvé"
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
  # `ps`/`pgrep` rapportent le chemin CANONIQUE (`/private/var/…`) là où le script a construit un
  # chemin symlinké (`/var/…`) : chercher le chemin du script rendait ce contrôle rouge sur le
  # bundle CORRECT (mesuré), et c'est aussi pour cela qu'une correspondance par simple nom
  # (`Murmure`) serait fausse — l'app stable de Louis tourne en même temps (mesuré).
  local app_real
  app_real=$(cd "$app" 2>/dev/null && pwd -P || printf '%s' "$app")
  printf 'FINDER ouverture=LaunchServices commande="/usr/bin/open -gj --env CFFIXED_USER_HOME=%s %s"\n' \
    "$home" "$app"
  if [[ -n "${FINDER_MUTANT_HARNESS:-}" ]]; then
    # THE MUTANT, reproduced for real (measured: the previous version only skipped `open` and wrote
    # `launched=0`, variable que le contrôle relisait ensuite — une capture tautologique, et
    # `open_rc` n'était jamais testé). Ici un processus ÉTRANGER sert réellement le socket du
    # contrat : c'est ce que « un harnais qui pilote start() » produit — un socket qui existe, que
    # le CLI peut joindre, et qui ne prouve absolutely nothing du chemin Finder. Le contrôle qui
    # doit tomber est alors `finder-launched-by-launchservices`, mesuré sur le processus réel.
    printf 'FINDER MUTANT un processus étranger sert le socket du contrat (harnais start())\n'
    ( nc -lU "$socket" >/dev/null 2>&1 & echo $! >"$work/harness.pid" )
    sleep 0.5
    HARNESS_PID=$(cat "$work/harness.pid" 2>/dev/null || true)
    printf 'FINDER MUTANT pid_harnais=%s\n' "${HARNESS_PID:-inconnu}"
  else
    /usr/bin/open -gj --env CFFIXED_USER_HOME="$home" "$app" >/dev/null 2>&1
    open_rc=$?
    printf 'FINDER open rc=%s\n' "$open_rc"
  fi
  # Le témoin est l'ETAT DU MONDE, jamais une variable que le mutant écrit : `open` a rendu 0 ET le
  # processus du bundle construit est réellement vivant. Un `open` en échec laisse donc ce contrôle
  # ROUGE (mesuré : `open_rc` n'était pas testé, un échec laissait `finder-launched-by-launchservices`
  # vert), et un socket servi par un tiers ne le rend pas vert non plus.
  local app_proc=0 app_pid=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    app_pid=$(pgrep -f "$app_real/Contents/MacOS/Murmure" 2>/dev/null | head -1)
    if [[ -n "$app_pid" ]]; then app_proc=1; break; fi
    sleep 0.5
  done
  printf 'FINDER processus_bundle pid=%s (attendu sous %s)\n' "${app_pid:-aucun}" "$app_real"
  [[ "${open_rc:-1}" -eq 0 && "$app_proc" -eq 1 ]]; check finder-launched-by-launchservices "$?" \
    "le bundle n'a pas été ouvert par LaunchServices (open rc=${open_rc:-non exécuté}, processus du bundle vivant=$app_proc) : rien ne prouve le chemin Finder réel"

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
    # correct (mesuré). Les deux côtés sont donc canonicalisés avant d'être comparés — `app_real`
    # l'est déjà, calculé une seule fois avant l'`open`.
    [[ -n "$owner_exe" ]] && owner_app=$(cd "$(dirname "$owner_exe")/../.." 2>/dev/null && pwd -P || true)
    [[ "$owner_app" == "$app_real" ]]; check finder-socket-served-by-bundle "$?" \
      "le socket est servi par « ${owner_app:-inconnu} », pas par le bundle ouvert ($app_real)"
    # Le socket doit être servi par LE PROCESSUS OUVERT PAR LE FINDER, pas par un homonyme.
    [[ -n "$app_pid" && "$owner" == "$app_pid" ]]; check finder-socket-owner-is-opened-bundle "$?" \
      "le socket est tenu par le pid ${owner:-inconnu}, pas par le processus ${app_pid:-inconnu} ouvert par LaunchServices"
    printf 'FINDER socket_appeared_after=%ss owner_pid=%s\n' "$elapsed" "${owner:-inconnu}"
    [[ "$(awk "BEGIN{print ($elapsed <= $SOCKET_WINDOW) ? 0 : 1}")" -eq 0 ]]; check finder-socket-in-window "$?" \
      "le socket a mis ${elapsed}s à apparaître (fenêtre du §2.5 : ${SOCKET_WINDOW}s)"
    if [[ -n "${FINDER_MUTANT_HARNESS:-}" ]]; then
      # Le verdict du mutant porte sur `finder-launched-by-launchservices`, déjà rouge. Payer une
      # transcription réelle sur un socket servi par `nc` measuringait le harnais, pas le chemin
      # Finder, et coûterait le délai maximal ; la suite est donc déclarée NON EXÉCUTÉE, jamais verte.
      printf 'FINDER MUTANT suite non exécutée (socket servi par un tiers, pas par le bundle)\n'
      FINDER_NO_APP="mutant harnais : le socket est servi par un processus étranger"
      return 1
    fi
  else
    for c in finder-socket-owner-is-app finder-socket-served-by-bundle finder-socket-owner-is-opened-bundle \
             finder-socket-in-window; do
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
  #    the check is a negative on a POSITIVE corpus: the same window must contain lines from THIS
  #    process, or the absence of transcript text proves nothing (an empty log is silent evidence,
  #    never a passing verdict).
  #
  #    DEUX MESURES CORRIGENT CE CONTRÔLE, l'une après l'autre :
  #
  #    * Le prédicat est restreint à `processID == $app_pid`. Sans cela il ramassait le journal de
  #      TOUTES les instances de Murmure — y compris l'app stable de Louis, qui transcrit en
  #      parallèle (mesuré : PID 97743 dans la même fenêtre) : une fuite de transcript de l'app
  #      stable aurait été imputée à CE run, et le témoin positif pouvait venir de l'autre.
  #    * Le témoin positif est la ligne de transcription RÉELLEMENT émise par ce run
  #      (`transcript … written: N unit(s)`, TranscriptJobRunner), pas la ligne
  #      `control: listening on the control socket`. Cette dernière est `.info` et macOS ne la
  #      conserve pas dans le magasin : mesuré sur le run complet du 26/09, `log show` ne la rend
  #      NI avec `--info` NI avec `--debug`, alors que les lignes `.info` de `transcription` sont,
  #      elles, bien là. Exiger cette ligne rendait le contrôle rouge sur une application qui
  #      journalisait — le défaut de contrat que la revue round 1 avait déjà relevé une fois.
  log_out=$(log show --last 45m --predicate "processID == $app_pid AND subsystem == \"com.louiscourcier.Murmure\"" \
    --info --debug --style compact 2>/dev/null || true)
  printf 'FINDER journal_lignes=%s (pid %s)\n' "$(grep -c . <<<"$log_out")" "$app_pid"
  local listening=0 leaked=0
  grep -qE 'transcript .* written: [0-9]+ unit' <<<"$log_out" && listening=1
  grep -qi 'control: listening' <<<"$log_out" && printf 'FINDER journal_ligne_controle=présente\n' \
    || printf 'FINDER journal_ligne_controle=absente du magasin (ligne .info, non conservée — sans effet sur le verdict)\n'
  [[ "$listening" -eq 1 ]]; check log-has-control-activity "$?" \
    "le journal de ce run ne contient pas la ligne de transcription réelle : une absence de transcript y serait une preuve muette"
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
