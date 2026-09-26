#!/usr/bin/env bash
# Contrat observable du lot 8 — moteur de transcription vidéo dans le processus (critères 9, 10, 11,
# 12, 13, 15 et 21 de la SPEC ; plan §2.1, §2.2, §2.4, §4 lot 8, §7.1).
#
# POURQUOI CE CONTRÔLE EXISTE, ET POURQUOI IL EST UN SCRIPT. Le moteur vidéo vit dans la cible
# application (`Murmure/`), qui n'a **pas** de bundle de tests : aucun `swift test` ne peut couvrir
# ces critères, et un contrat rouge dans `MurmureCore` ne les atteindrait jamais. Le plan tranche
# donc pour un contrat **observable** : on regarde ce que la passe a réellement produit (les deux
# fichiers du transcript) et ce que la machine a réellement montré pendant qu'elle tournait (pic
# mémoire, connexions, table des processus, journaux de l'app). Rien n'est déduit du code.
#
# CE QUE CE SCRIPT CONTRÔLE (10 contrôles, un verdict, un code de retour) :
#   1. entrées : transcript JSON, transcript Markdown, bundle de l'app installée ;
#   2. critère 21 — les **deux formats** existent, partagent leur tige, et décrivent le même
#      transcript (au moins un extrait des segments du JSON se retrouve dans le Markdown) ;
#   3. critère 21 — **schéma du document** : les 13 clés du §2.4, leurs types, `status` terminé,
#      `source` cohérente avec son `kind`, `completedAt` présent sur un document terminé, et **aucun
#      texte de segment ne porte de jeton spécial du décodeur** (`<|…|>`) — le Markdown non plus. Un
#      document qui déclare un transcript et livre le préremplissage du modèle (`<|startoftranscript|>`,
#      `<|fr|>`, `<|3.32|>`) est exactement le faux vert que ce contrôle existe pour voir : avec le
#      défaut `DecodingOptions.skipSpecialTokens == false` de WhisperKit v1.1.0, les 707 segments de la
#      passe du 2026-09-22 en portaient 1 438 et ce contrat rendait **VERT 10/10** ;
#   4. critère 9 — **couverture cumulée ≥ 97 %** de la durée audio. La couverture est **recalculée
#      ici** comme l'**union** des intervalles bornée à `[0, durée]` (règle du lot 2) : un
#      transcript qui se recouvre ne couvre pas deux fois la même seconde, et la valeur déclarée
#      dans `coverage` doit correspondre au calcul. La ligne **nomme en plus ses intervalles non
#      couverts ≥ 20 s** — compte, bornes, durée — **sur le vert comme sur le rouge** : c'est ce qui
#      distingue, dans un rouge, une **unité non transcrite** d'une **fenêtre sautée**. Le round 1 du
#      lot 8 a mesuré 97,04 % avec un seul trou de 24,4 s (`[1664,1 → 1688,5)`) : la ligne d'alors
#      disait « ≥ 97 % » sans dire qu'il n'y avait qu'un trou, ni où ;
#   5. critère 9 — **horodatages** : `début < fin` partout, débuts strictement croissants, aucun
#      segment qui commence avant la fin du précédent, et **≥ 1 segment pour 30 s** ;
#   6. critère 12 — **langue** : sans option, `language` non vide et `languageWasForced == false` ;
#      à la **reprise** d'un document `inProgress`, la langue du document est **relue** et non
#      re-détectée (`language`/`languageWasForced` identiques avant et après, en comparant le
#      document d'avant reprise fourni par `--resumed-from`). Ce document doit être un **objet
#      JSON** : un JSON lisible mais non-objet (tableau, chaîne, nombre, booléen, `null`) est un
#      **échec** nommant le critère 12 — sans comparaison possible, il n'y a pas de vert ;
#   7. critère 10 — **pic mémoire < 2 Go** (`/usr/bin/time -l`) sur une passe **de 2 h** ;
#   8. critère 11 — **aucune connexion sortante** pendant la transcription (échantillons `lsof`) ;
#   9. critère 13 — **aucun processus de transcription séparé** (échantillons `ps`) ;
#  10. critère 15 — **le texte transcrit n'apparaît dans aucun journal** de l'app.
#
# CE QU'IL NE FAIT PAS, ET C'EST DÉLIBÉRÉ. Il ne transcrit rien, ne lance aucun moteur, n'installe
# rien, ne télécharge rien, ne signe rien, ne supprime rien et **n'écrit aucun fichier** hors de son
# mode `--self-test` (qui ne travaille que dans un répertoire temporaire, supprimé en sortie). Il
# n'est pas ajouté à `scripts/codex/verify.sh` : la passe qu'il contrôle est un périmètre explicite
# de la carte d'implémentation, pas d'une gate automatique (AGENTS.md). Il **lit**.
#
# CE QU'IL NE PEUT PAS DIRE (déclaré plutôt que caché, règle 11 du §7.1) :
#   - critère 13, seconde clause — « la spécialisation Neural Engine de l'app est réutilisée
#     (< 5 s après un premier usage) » : aucune surface observable par script. **Non couverte ici**,
#     rattachée à la gate humaine (§6 risque 9) ; le script l'affiche en clair à chaque exécution.
#   - critère 15 — le contrôle porte sur le **texte** transcrit ; la présence d'**audio** dans les
#     journaux n'est pas recherchée (aucune empreinte audio exploitable n'existe dans les preuves).
#   - critère 11 — les échantillons viennent de `lsof` pour le PID de l'app : une connexion ouverte
#     par un processus tiers n'est pas attribuée à la transcription.
#   - critère 13 — le contrôle cherche les familles de binaires de transcription documentées
#     ci-dessous ; un auxiliaire dont le nom ne porte aucun de ces motifs lui échapperait.
#   - critère 9 — la couverture se mesure sur la **durée de référence** fournie (durée mesurée de
#     l'audio si `--audio-seconds` est donné, durée déclarée par le document sinon) ; le script dit
#     toujours laquelle il a utilisée.
#   - critère 9 — le diagnostic nomme un par un les intervalles non couverts d'au moins 20 s ; les
#     trous plus courts ne sont pas listés (aucun d'eux ne peut cacher une unité ou une fenêtre de
#     transcription, qui en font 24 à 30). Quand il n'y en a **aucun**, la ligne nomme tout de même
#     le **plus grand** intervalle non couvert, quelle que soit sa durée : « 0 trou ≥ 20 s » sans
#     repère se lirait comme « aucun trou du tout ».
#   - critère 21 — la recherche de jetons spéciaux porte sur la forme `<|…|>` du vocabulaire du
#     décodeur (le délimiteur `<|` n'appartient pas au texte transcrit) : un texte pollué par d'autres
#     marqueurs, sans ce délimiteur, lui échappe. Elle porte sur les `text` de segment et sur le
#     Markdown ; ni le titre, ni `source.identity`, ni `model` ne sont balayés.
#
# ÉVIDENCE ATTENDUE (`--evidence DIR`), produite par la passe de la carte d'implémentation :
#   memoire-2h.time.txt   sortie brute de « /usr/bin/time -l » autour de la passe de 2 h
#   memoire-2h.duree.txt  durée de l'audio de cette passe, en secondes (doit être ≥ 7200)
#   processus.txt         échantillons de processus pendant la transcription
#   reseau.txt            échantillons de connexions de l'app pendant la transcription
#   logs/                 journaux de l'app capturés pendant la transcription
# Les commandes exactes qui produisent ces cinq entrées (à exécuter par la carte `dev`, jamais par
# ce script) sont celles-ci, `APP_PID` étant le PID du processus `Murmure` de la passe :
#
#   { while kill -0 "$APP_PID" 2>/dev/null; do printf '# SAMPLE %s %s\n' "$(date +%s)" "$APP_PID";
#       lsof -nP -a -p "$APP_PID" -i 2>/dev/null; sleep 2; done; } > reseau.txt
#   { while kill -0 "$APP_PID" 2>/dev/null; do printf '# SAMPLE %s\n' "$(date +%s)";
#       ps -Ao pid,ppid,args | grep -Ei 'whisper|murmure' | grep -v grep; sleep 2; done; } > processus.txt
#   log show --style syslog --info --debug --start "$T0" --end "$T1" \
#       --predicate 'subsystem == "com.louiscourcier.Murmure"' > logs/murmure-unified.log
#   /usr/bin/time -l <la passe de 2 h> 2> memoire-2h.time.txt ; echo 7203.5 > memoire-2h.duree.txt
#
# Familles de binaires interdites pendant la passe (critère 13) : `whisper`, `ctranslate`,
# `faster-whisper`, `whisperkit` (insensible à la casse). `ffmpeg` n'en fait pas partie : c'est un
# décodeur légitime, appelé en sous-processus par le lot 7.
#
# Usage :
#   bash scripts/checks/transcription-contract.sh <transcript.json> <transcript.md> <app.app>
#       [--evidence DIR] [--audio-seconds SEC] [--resumed-from JSON] [--logs DIR]
#   bash scripts/checks/transcription-contract.sh --self-test
#   bash scripts/checks/transcription-contract.sh --help
#
#   --evidence DIR      répertoire des cinq preuves ci-dessus (défaut : aucun, les contrôles 7 à 10
#                       sortent alors « non exécuté », jamais verts)
#   --audio-seconds SEC durée mesurée de l'audio source, référence du contrôle de couverture
#   --resumed-from JSON document `status: "inProgress"` tel qu'il était sur disque AVANT la reprise
#                       (critère 12, seconde clause : sans lui, le contrôle n'est pas exécuté)
#   --logs DIR          journaux de l'app (défaut : <evidence>/logs)
#   --self-test         exerce les dix contrôles sur des fixtures fabriquées en répertoire
#                       temporaire : un jeu complet qui doit passer, puis une mutation par contrôle
#                       qui doit échouer en nommant son critère, et un document **vert** dont la
#                       ligne du critère 9 doit nommer son trou de 24 s (le diagnostic se prouve sur
#                       un vert, pas seulement sur un rouge). C'est la preuve que ce contrat
#                       n'est pas vide (règle 11) ; il ne touche à rien du dépôt.
#
# Sortie : 0 si les 10 contrôles passent ; 1 si au moins un manque ou si un contrôle a dû être
#          laissé non exécuté ; 2 si l'usage est invalide. Chaque contrôle affiche le fait mesuré,
#          la valeur attendue et le critère qu'il porte : un rouge se lit sans relire ce fichier.
#          Le texte du transcript n'est jamais imprimé (AGENTS.md : aucun contenu de transcript
#          dans un journal) — un extrait fautif est nommé par les 12 premiers caractères de son
#          empreinte sha256.

set -uo pipefail

NOM="transcription-contract"
CHECK_TOTAL=10
USAGE="usage: bash scripts/checks/transcription-contract.sh <transcript.json> <transcript.md> <app.app> [options]
       bash scripts/checks/transcription-contract.sh --self-test
       options : [--evidence DIR] [--audio-seconds SEC] [--resumed-from JSON] [--logs DIR]
                 -h, --help, --self-test"

JSON=""
MD=""
APP=""
EVIDENCE=""
AUDIO_SECONDS=""
RESUMED=""
LOGS=""
MODE="run"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            printf '%s\n' "$USAGE"
            exit 0
            ;;
        --self-test)
            MODE="self-test"
            shift
            ;;
        --evidence|--audio-seconds|--resumed-from|--logs)
            if [ "$#" -lt 2 ]; then
                printf "%s: « %s » attend une valeur\n" "$NOM" "$1" >&2
                printf '%s\n' "$USAGE" >&2
                exit 2
            fi
            case "$1" in
                --evidence)      EVIDENCE="$2" ;;
                --audio-seconds) AUDIO_SECONDS="$2" ;;
                --resumed-from)  RESUMED="$2" ;;
                --logs)          LOGS="$2" ;;
            esac
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            printf "%s: option inconnue « %s »\n" "$NOM" "$1" >&2
            printf '%s\n' "$USAGE" >&2
            exit 2
            ;;
        *)
            if [ -z "$JSON" ]; then
                JSON="$1"
            elif [ -z "$MD" ]; then
                MD="$1"
            elif [ -z "$APP" ]; then
                APP="$1"
            else
                printf "%s: trop d'arguments positionnels (« %s »)\n" "$NOM" "$1" >&2
                printf '%s\n' "$USAGE" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SELF="${BASH_SOURCE[0]}"

if [ "$MODE" = "run" ] && { [ -z "$JSON" ] || [ -z "$MD" ] || [ -z "$APP" ]; }; then
    printf "%s: trois chemins sont attendus : transcript JSON, transcript Markdown, app installée\n" "$NOM" >&2
    printf '%s\n' "$USAGE" >&2
    exit 2
fi

failures=0
not_run=0
FAIL_LIST=""
SKIP_LIST=""

ok() { printf '  [OK]          %s\n' "$1"; }
echec() {
    printf '  [ECHEC]       %s\n' "$1"
    failures=$((failures + 1))
    # printf -v : une substitution de commande mangerait le saut de ligne final
    # et collerait deux manques sur la même ligne du compte rendu.
    printf -v FAIL_LIST '%s    - %s\n' "$FAIL_LIST" "$1"
}
# Un contrôle non exécuté n'est jamais un vert : il rend la sortie rouge aussi.
non_execute() {
    printf '  [NON EXÉCUTÉ] %s\n' "$1"
    not_run=$((not_run + 1))
    printf -v SKIP_LIST '%s    - %s\n' "$SKIP_LIST" "$1"
}
# Ni un manque ni un vert : une clause de critère déclarée hors de portée de ce contrat.
# Elle est imprimée à chaque exécution, dans les deux verdicts.
non_couvert() { printf '  [NON COUVERT] %s\n' "$1"; }

# ---------------------------------------------------------------------------------------------
# Analyse : un seul programme Python rend les 10 contrôles, une ligne par contrôle, séparée par des
# tabulations — « numéro, titre, critère, verdict, message ». Les verdicts et la mise en forme
# restent ici, à un seul endroit ; l'analyse (JSON, mesures, échantillons, journaux) est en
# Python parce qu'aucun outil en ligne de commande livré avec macOS ne lit ce JSON sans être
# réécrit. `python3` est donc requis ; s'il manque ou s'il échoue, la sortie est rouge, jamais
# verte par défaut.
# ---------------------------------------------------------------------------------------------
analyser() {
    python3 - "$JSON" "$MD" "$APP" "$EVIDENCE" "$AUDIO_SECONDS" "$RESUMED" "$LOGS" <<'PY'
import glob
import hashlib
import json
import math
import os
import re
import sys

json_path, md_path, app_path, ev, audio_seconds_arg, resumed_path, logs_arg = sys.argv[1:8]

TITRES = [
    ("entrées : transcript JSON, transcript Markdown, app installée", "précondition"),
    ("les deux formats, et le même transcript dans les deux", "critère 21"),
    ("schéma du document (plan §2.4)", "critère 21"),
    ("couverture cumulée ≥ 97 % de la durée audio", "critère 9"),
    ("horodatages strictement croissants et ≥ 1 segment / 30 s", "critère 9"),
    ("langue détectée sans option, relue à la reprise", "critère 12"),
    ("pic mémoire < 2 Go sur un audio de 2 h", "critère 10"),
    ("aucune connexion sortante pendant la transcription", "critère 11"),
    ("aucun processus de transcription séparé", "critère 13"),
    ("le texte transcrit n'apparaît dans aucun journal de l'app", "critère 15"),
]
NOMBRE = len(TITRES)
TAILLE_EXTRAIT = 24
MOTIFS_INTERDITS = r"whisper|ctranslate|faster-whisper|whisperkit"
# Délimiteur des jetons spéciaux du décodeur (`<|startoftranscript|>`, `<|fr|>`, `<|3.32|>`). Il
# n'appartient à aucun texte transcrit : WhisperKit le laissait passer dans `text` tant que
# `DecodingOptions.skipSpecialTokens` valait son défaut (`false`) — mesuré le 2026-09-22.
DELIMITEUR_JETON = "<|"
# Seuil du **diagnostic** des intervalles non couverts (critère 9), et non du verdict : la
# couverture reste jugée à 97 % du §2.1. Une fenêtre de transcription sautée fait 24 à 30 s et une
# unité non transcrite ≈ 300 s : 20 s nomme les deux causes sans nommer le bruit des silences.
SEUIL_TROU = 20.0
GO = 1024 ** 3

sortie = []


def ligne(numero, verdict, message):
    titre, critere = TITRES[numero - 1]
    propre = " ".join(str(message).split())
    sortie.append("\t".join([str(numero), titre, critere, verdict, propre]))


def restants(premier, raison):
    for numero in range(premier, NOMBRE + 1):
        ligne(numero, "NON_EXECUTE", raison)


def declaration(critere, message):
    sortie.append("\t".join(["", "", critere, "NON_COUVERT", " ".join(str(message).split())]))


def nb(valeur, decimales=3):
    return (("%%.%df" % decimales) % valeur).replace(".", ",")


def lire(chemin):
    with open(chemin, "r", encoding="utf-8", errors="replace") as fichier:
        return fichier.read()


def empreinte(texte):
    return hashlib.sha256(texte.encode("utf-8", "replace")).hexdigest()[:12]


def normaliser(texte):
    return re.sub(r"\s+", " ", texte).strip()


def est_nombre(valeur):
    return isinstance(valeur, (int, float)) and not isinstance(valeur, bool) and math.isfinite(valeur)


def intervalles_couverts(segments, borne):
    """Union des intervalles de segments, bornée à `[0, borne]`, en intervalles **fusionnés**.
    Un segment non-objet, ou dont les horodatages ne sont pas numériques, n'a pas d'intervalle : il
    est écarté ici sans faire tomber le lecteur sur un traceback — le contrôle 3 (schéma) et le
    contrôle 5 (horodatages) le nomment, eux. C'est la seule définition de « couverture » de ce
    script : le total et le diagnostic des trous sortent de ces mêmes intervalles."""
    intervalles = []
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        debut = segment.get("start")
        fin = segment.get("end")
        if not est_nombre(debut) or not est_nombre(fin):
            continue
        debut, fin = max(float(debut), 0.0), min(float(fin), borne)
        if debut < fin:
            intervalles.append((debut, fin))
    intervalles.sort()
    fusionnes = []
    for debut, fin in intervalles:
        if fusionnes and debut <= fusionnes[-1][1]:
            fusionnes[-1][1] = max(fusionnes[-1][1], fin)
        else:
            fusionnes.append([debut, fin])
    return fusionnes


def union_couverte(segments, borne):
    """Secondes couvertes : un transcript qui se recouvre ne compte pas deux fois la même seconde."""
    return sum(fin - debut for debut, fin in intervalles_couverts(segments, borne))


def trous(segments, borne, seuil=SEUIL_TROU):
    """Intervalles que l'union ne recouvre **pas**, d'au moins `seuil` secondes : bornes et durée.
    Le trou de fin (des derniers segments jusqu'à la borne) en fait partie : une passe interrompue
    avant la fin de l'audio ne se lit pas autrement."""
    trouves = []
    curseur = 0.0
    for debut, fin in intervalles_couverts(segments, borne):
        if debut > curseur:
            trouves.append((curseur, debut, debut - curseur))
        curseur = max(curseur, fin)
    if curseur < borne:
        trouves.append((curseur, float(borne), float(borne) - curseur))
    return [trouve for trouve in trouves if trouve[2] >= seuil]


def diagnostic_trous(segments, borne):
    """Le diagnostic des intervalles non couverts, tel que la ligne du critère 9 le porte — sur le
    vert **comme** sur le rouge. Il nomme le **compte** des trous ≥ SEUIL_TROU secondes et, pour
    chacun, ses bornes et sa durée ; sans trou d'au moins 20 s, il nomme le plus grand trou, quelle
    que soit sa durée (un « 0 trou ≥ 20 s » seul se lirait comme « aucun trou du tout »). C'est ce
    qui départage les deux causes d'un rouge de couverture : une **unité non transcrite** (≈ 300 s, à
    une frontière du plan) et une **fenêtre sautée** (24 à 30 s)."""
    tous = trous(segments, borne, seuil=0.0)
    if not tous:
        return "0 trou(s) ≥ 20 s (aucun intervalle non couvert)"
    plus_grand = max(tous, key=lambda trouve: trouve[2])
    majeurs = [trouve for trouve in tous if trouve[2] >= SEUIL_TROU]
    if not majeurs:
        return "0 trou(s) ≥ 20 s (plus grand trou [%s → %s) %s s)" % (
            nb(plus_grand[0], 1),
            nb(plus_grand[1], 1),
            nb(plus_grand[2], 1),
        )
    return "%d trou(s) ≥ 20 s : %s" % (
        len(majeurs),
        " ; ".join("[%s → %s) %s s" % (nb(debut, 1), nb(fin, 1), nb(duree, 1)) for debut, fin, duree in majeurs),
    )


def extraits(segments, taille=TAILLE_EXTRAIT, maximum=8):
    """Extraits de texte du transcript, assez longs pour qu'une coïncidence soit improbable.
    Les segments sont pris **répartis sur tout le document** (et non les huit premiers) : un
    journal qui ne reprendrait qu'un passage doit pouvoir être attrapé n'importe où. La fenêtre est
    décalée d'un segment à l'autre pour que deux segments qui se ressemblent ne produisent pas deux
    fois le même extrait. Le texte n'est jamais imprimé : seule son empreinte le nomme."""
    textes = []
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        texte = normaliser(str(segment.get("text", "")))
        if len(texte) >= taille + 8:
            textes.append(texte)
    if not textes:
        return []
    pas = max(1, len(textes) // maximum)
    trouves = []
    for position in range(0, len(textes), pas):
        texte = textes[position]
        marge = len(texte) - taille
        offset = (position * 7) % marge if marge > 0 else 0
        extrait = texte[offset:offset + taille]
        if extrait not in trouves:
            trouves.append(extrait)
        if len(trouves) >= maximum:
            break
    return trouves


def echantillons(contenu):
    """Découpe un journal d'échantillons en [(entête, lignes)] sur les lignes « # SAMPLE … »."""
    blocs = []
    for bloc in re.split(r"^# SAMPLE ", contenu, flags=re.M)[1:]:
        entete, _, reste = bloc.partition("\n")
        blocs.append((entete.strip(), [l for l in reste.splitlines() if l.strip()]))
    return blocs


# --------------------------------------------------------------------------------------------
# 1. Entrées
# --------------------------------------------------------------------------------------------
manques = []
if not os.path.isfile(json_path):
    manques.append("transcript JSON : « %s » n'existe pas (test -f)" % json_path)
if not os.path.isfile(md_path):
    manques.append("transcript Markdown : « %s » n'existe pas (test -f)" % md_path)
binaire_app = os.path.join(app_path, "Contents", "MacOS", "Murmure")
if not os.path.isdir(app_path):
    manques.append("app installée : « %s » n'est pas un bundle (test -d)" % app_path)
elif not os.path.isfile(binaire_app):
    manques.append("app installée : « %s » n'expose pas Contents/MacOS/Murmure (test -f)" % binaire_app)

if manques:
    ligne(
        1,
        "ECHEC",
        "; ".join(manques)
        + " — critères 9, 10, 11, 12, 13, 15 et 21 non vérifiables : la passe vidéo n'a rien produit à contrôler",
    )
    restants(2, "entrée manquante : la passe vidéo n'a rien produit à contrôler (voir 1/%d)" % NOMBRE)
    print("\n".join(sortie))
    sys.exit(0)

doc = None
try:
    doc = json.loads(lire(json_path))
except Exception as erreur:  # JSON illisible : rien d'autre ne peut être mesuré
    ligne(1, "ECHEC", "transcript JSON : « %s » n'est pas un document JSON lisible (%s)" % (json_path, erreur))
    restants(2, "le document JSON est illisible (voir 1/%d)" % NOMBRE)
    print("\n".join(sortie))
    sys.exit(0)

if not isinstance(doc, dict):
    # JSON parsable mais non-objet : les dix contrôles lisent ce document, aucun ne peut être rendu.
    # Sans cette garde (mesuré le 2026-09-21, fixture `[]`) le lecteur tombait sur un traceback —
    # « ROUGE — le lecteur du contrat a échoué … AttributeError: 'list' object has no attribute get »
    # — soit un rouge muet qui ne nomme rien : la doctrine de ce script est qu'un rouge doit nommer
    # ce qui manque. Même traitement que la précondition 1 : un manque nommé, aucun contrôle rendu,
    # donc rien de certifié.
    ligne(
        1,
        "ECHEC",
        "transcript JSON : « %s » est un %s, pas un objet JSON — les clés du schéma du §2.4 ne peuvent pas être lues (critère 21)"
        % (json_path, type(doc).__name__),
    )
    restants(2, "le document JSON n'est pas un objet (voir 1/%d)" % NOMBRE)
    print("\n".join(sortie))
    sys.exit(0)

ligne(1, "OK", "transcript JSON « %s », transcript Markdown « %s », app « %s » présents" % (json_path, md_path, app_path))

segments = doc.get("segments") if isinstance(doc, dict) else None
if not isinstance(segments, list):
    segments = []

# --------------------------------------------------------------------------------------------
# 2. Critère 21 — les deux formats, et le même transcript dans les deux
# --------------------------------------------------------------------------------------------
probs = []
souche_json = os.path.splitext(os.path.basename(json_path))[0]
souche_md = os.path.splitext(os.path.basename(md_path))[0]
if souche_json != souche_md:
    probs.append(
        "les deux fichiers ne partagent pas leur tige (« %s » contre « %s ») : un agent qui trouve l'un ne trouve plus l'autre (plan §2.4)"
        % (souche_json, souche_md)
    )
texte_md = lire(md_path)
lignes_md = [l for l in texte_md.splitlines() if l.strip()]
if not texte_md.strip():
    probs.append("le Markdown « %s » est vide : le critère 21 demande les deux formats, pas deux fichiers" % md_path)
elif len(lignes_md) < 2:
    probs.append("le Markdown « %s » ne porte qu'une ligne non vide : ce n'est pas un transcript rendu" % md_path)
candidats = extraits(segments)
if not candidats and not probs:
    ligne(
        2,
        "NON_EXECUTE",
        "aucun segment du JSON n'est assez long pour un extrait de %d caractères : la cohérence des deux formats ne peut pas être éprouvée" % TAILLE_EXTRAIT,
    )
else:
    if candidats and not probs:
        md_normalise = normaliser(texte_md)
        trouves = [c for c in candidats if c in texte_md or c in md_normalise]
        if not trouves:
            probs.append(
                "%d extraits du JSON (de %d caractères chacun, pris au milieu de segments) introuvables dans le Markdown : les deux fichiers ne décrivent pas le même transcript"
                % (len(candidats), TAILLE_EXTRAIT)
            )
    if probs:
        ligne(2, "ECHEC", "plan §2.4 — " + " ; ".join(probs))
    else:
        ligne(
            2,
            "OK",
            "deux formats de même tige « %s » : Markdown de %d lignes non vides, %d extraits de segments retrouvés dedans"
            % (souche_json, len(lignes_md), len(candidats)),
        )

# --------------------------------------------------------------------------------------------
# 3. Critère 21 — schéma du document
# --------------------------------------------------------------------------------------------
probs = []
CHAMPS = [
    ("schemaVersion", "entier"),
    ("id", "chaine"),
    ("title", "chaine"),
    ("source", "dict"),
    ("duration", "nombre"),
    ("language", "chaine"),
    ("languageWasForced", "booleen"),
    ("model", "chaine"),
    ("createdAt", "chaine"),
    ("status", "chaine"),
    ("segments", "liste"),
    ("coverage", "dict"),
    ("boundaries", "liste"),
]
if not isinstance(doc, dict):
    probs.append("le document JSON n'est pas un objet")
else:
    for nom, attendu in CHAMPS:
        if nom not in doc:
            probs.append("champ `%s` absent" % nom)
            continue
        valeur = doc[nom]
        if attendu == "nombre" and not est_nombre(valeur):
            probs.append("champ `%s` n'est pas un nombre (%s)" % (nom, type(valeur).__name__))
        elif attendu == "entier" and (not isinstance(valeur, int) or isinstance(valeur, bool)):
            probs.append("champ `%s` n'est pas un entier (%s)" % (nom, type(valeur).__name__))
        elif attendu == "chaine" and not isinstance(valeur, str):
            probs.append("champ `%s` n'est pas une chaîne (%s)" % (nom, type(valeur).__name__))
        elif attendu == "booleen" and not isinstance(valeur, bool):
            probs.append("champ `%s` n'est pas un booléen (%s)" % (nom, type(valeur).__name__))
        elif attendu == "dict" and not isinstance(valeur, dict):
            probs.append("champ `%s` n'est pas un objet (%s)" % (nom, type(valeur).__name__))
        elif attendu == "liste" and not isinstance(valeur, list):
            probs.append("champ `%s` n'est pas un tableau (%s)" % (nom, type(valeur).__name__))

    if doc.get("schemaVersion") != 1:
        probs.append("`schemaVersion` vaut %r au lieu de 1 (version gelée du §2.4)" % doc.get("schemaVersion"))
    for nom in ("id", "title", "model"):
        if isinstance(doc.get(nom), str) and not doc[nom].strip():
            probs.append("champ `%s` vide" % nom)
    if isinstance(doc.get("createdAt"), str) and not re.match(
        r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", doc["createdAt"]
    ):
        probs.append("`createdAt` n'est pas une date ISO 8601 (« %s »)" % doc["createdAt"])

    statut = doc.get("status")
    if statut not in ("inProgress", "complete", "failed"):
        probs.append("`status` vaut %r, hors de l'énumération inProgress/complete/failed" % statut)
    elif statut != "complete":
        probs.append(
            "`status` vaut « %s » : un travail non terminé ne certifie ni la couverture du critère 9 ni les deux formats du critère 21"
            % statut
        )
    if statut == "complete" and doc.get("completedAt") is None:
        probs.append("champ `completedAt` absent alors que le document est terminé (plan §2.4)")

    source = doc.get("source")
    if isinstance(source, dict):
        genre = source.get("kind")
        if genre not in ("youtube", "x", "file"):
            probs.append("`source.kind` vaut %r, hors de l'énumération youtube/x/file" % genre)
        if not isinstance(source.get("identity"), str) or not source.get("identity", "").strip():
            probs.append("`source.identity` vide")
        if genre in ("youtube", "x") and not str(source.get("url") or "").strip():
            probs.append("`source.url` absente pour un `kind` « %s »" % genre)
        if genre == "file" and not str(source.get("path") or "").strip():
            probs.append("`source.path` absente pour un `kind` « file »")

    couverture = doc.get("coverage")
    if isinstance(couverture, dict):
        for nom in ("coveredSeconds", "ratio"):
            if not est_nombre(couverture.get(nom)):
                probs.append("`coverage.%s` n'est pas un nombre" % nom)
    frontières = doc.get("boundaries")
    if isinstance(frontières, list):
        for index, frontière in enumerate(frontières):
            if not isinstance(frontière, dict):
                probs.append("`boundaries[%d]` n'est pas un objet" % index)
                continue
            if not est_nombre(frontière.get("start")) or not est_nombre(frontière.get("duration")):
                probs.append("`boundaries[%d]` : `start`/`duration` ne sont pas des nombres" % index)
            elif frontière.get("quality") not in ("silence", "forced"):
                probs.append(
                    "`boundaries[%d].quality` vaut %r, hors de l'énumération silence/forced"
                    % (index, frontière.get("quality"))
                )
    if isinstance(segments, list):
        if not segments:
            probs.append("`segments` est vide : aucun texte transcrit")
        for index, segment in enumerate(segments):
            if not isinstance(segment, dict):
                probs.append("`segments[%d]` n'est pas un objet" % index)
                continue
            if not est_nombre(segment.get("start")) or not est_nombre(segment.get("end")):
                probs.append("`segments[%d]` : `start`/`end` ne sont pas des nombres" % index)
            if not isinstance(segment.get("text"), str) or not segment.get("text", "").strip():
                probs.append("`segments[%d].text` vide" % index)
            if len(probs) >= 6:
                break

    # Défaut mesuré le 2026-09-22 (`DecodingOptions.skipSpecialTokens` valait `false`, son défaut dans
    # WhisperKit v1.1.0) : `TranscriptionSegment.text` sortait **pollué** du préremplissage du décodeur
    # — `<|startoftranscript|><|fr|><|transcribe|>` en tête d'unité, `<|3.32|> … <|5.32|>` autour de
    # chaque segment. Le §2.4 dit que `text` porte le texte transcrit : un document qui déclare un
    # transcript et livre les jetons du modèle est exactement le faux vert que ce contrôle existe pour
    # voir — la passe de 707 segments mesurée ce jour-là en portait 1 438, et ce contrat rendait alors
    # VERT 10/10 (contrôles 2, 3 et 5 ne regardaient jamais le **contenu** du texte).
    # Le balayage est fait **hors** de la boucle ci-dessus, qui s'arrête à six problèmes de schéma : un
    # texte pollué est donc constaté même quand la boucle s'est arrêtée tôt. Son constat est **placé en
    # tête** de la liste, parce que le message n'affiche que les six premiers : un document à la fois
    # pollué et malformé doit d'abord dire qu'il ne porte pas du texte transcrit. Aucun texte n'est
    # imprimé : les segments fautifs sont nommés par leur index, comme le contrôle 10 nomme ses extraits
    # par leur empreinte.
    pollues = [
        index
        for index, segment in enumerate(segments)
        if isinstance(segment, dict) and DELIMITEUR_JETON in str(segment.get("text") or "")
    ]
    caracteres_segments = sum(
        len(str(segment.get("text") or "")) for segment in segments if isinstance(segment, dict)
    )
    occurrences = sum(
        str(segment.get("text") or "").count(DELIMITEUR_JETON)
        for segment in segments
        if isinstance(segment, dict)
    )
    occurrences_md = texte_md.count(DELIMITEUR_JETON)
    if pollues or occurrences_md:
        constats = []
        if pollues:
            constats.append(
                "`segments[i].text` porte un jeton spécial du décodeur (`<|…|>`) dans %d segment(s) sur %d"
                " (premier : `segments[%d]`), soit %d occurrence(s) de « <| » : ce n'est pas le texte transcrit"
                % (len(pollues), len(segments), pollues[0], occurrences)
            )
        if occurrences_md:
            constats.append(
                "le Markdown porte %d occurrence(s) de « <| » : les deux formats livrent le même texte pollué"
                % occurrences_md
            )
        probs.insert(0, " ; ".join(constats))

if probs:
    ligne(3, "ECHEC", "plan §2.4 — " + " ; ".join(probs[:6]) + (" (et %d autre(s))" % (len(probs) - 6) if len(probs) > 6 else ""))
else:
    ligne(
        3,
        "OK",
        "schéma §2.4 complet : 13 clés, `status` « %s », %d segment(s), %d frontière(s), schemaVersion %s"
        " — et aucun jeton spécial du décodeur (`<|…|>`) : 0 occurrence de « <| » dans les %d caractère(s)"
        " des `text` de segment ni dans les %d caractère(s) du Markdown"
        % (doc["status"], len(segments), len(doc["boundaries"]), doc["schemaVersion"], caracteres_segments, len(texte_md)),
    )

# --------------------------------------------------------------------------------------------
# 4. Critère 9 — couverture cumulée
# --------------------------------------------------------------------------------------------
duree_declaree = doc.get("duration") if isinstance(doc.get("duration"), (int, float)) else None
if audio_seconds_arg.strip():
    try:
        duree_reference = float(audio_seconds_arg)
        origine_reference = "durée mesurée de l'audio (--audio-seconds)"
    except ValueError:
        duree_reference = None
        origine_reference = "durée mesurée de l'audio (--audio-seconds) illisible : %r" % audio_seconds_arg
elif isinstance(duree_declaree, (int, float)):
    duree_reference = float(duree_declaree)
    origine_reference = "durée déclarée par le document (`duration`)"
else:
    duree_reference = None
    origine_reference = "aucune durée de référence (ni `--audio-seconds`, ni `duration`)"

if duree_reference is None or duree_reference <= 0:
    ligne(4, "NON_EXECUTE", "référence de couverture inutilisable — %s" % origine_reference)
else:
    couvert = union_couverte(segments, duree_reference)
    ratio = min(max(couvert / duree_reference, 0.0), 1.0)
    probs = []
    if ratio < 0.97:
        probs.append(
            "couverture cumulée %s %% < 97 %% (%s s couvertes sur %s s ; union des intervalles bornée à [0, durée] ; référence : %s)"
            % (nb(ratio * 100, 2), nb(couvert, 1), nb(duree_reference, 3), origine_reference)
        )
    if isinstance(duree_declaree, (int, float)) and duree_declaree > 0:
        # La valeur rangée dans le document doit être le résultat du même calcul : un document qui
        # déclare 99,3 % et couvre 96 % est exactement le faux vert que ce contrôle existe pour voir.
        recalcule = union_couverte(segments, float(duree_declaree))
        declare = doc.get("coverage") if isinstance(doc.get("coverage"), dict) else {}
        if est_nombre(declare.get("ratio")) and abs(float(declare["ratio"]) - recalcule / float(duree_declaree)) > 0.001:
            probs.append(
                "`coverage.ratio` déclare %s alors que le calcul d'union donne %s (écart > 0,1 %%)"
                % (nb(float(declare["ratio"]), 4), nb(recalcule / float(duree_declaree), 4))
            )
        if est_nombre(declare.get("coveredSeconds")) and abs(
            float(declare["coveredSeconds"]) - recalcule
        ) > max(0.5, 0.001 * float(duree_declaree)):
            probs.append(
                "`coverage.coveredSeconds` déclare %s s alors que le calcul d'union donne %s s"
                % (nb(float(declare["coveredSeconds"]), 1), nb(recalcule, 1))
            )
    # Le diagnostic des trous est porté par la ligne dans les deux verdicts : sur un rouge, il dit
    # *où* et *combien* la couverture manque (unité non transcrite / fenêtre sautée) ; sur un vert,
    # il dit ce qui a été regardé — un vert sans repère se lirait comme « rien à signaler ».
    diagnostic = diagnostic_trous(segments, duree_reference)
    if probs:
        probs.append(diagnostic)
        ligne(4, "ECHEC", " ; ".join(probs))
    else:
        ligne(
            4,
            "OK",
            "couverture cumulée %s %% ≥ 97 %% (%s s couvertes sur %s s ; référence : %s) ; %s"
            % (nb(ratio * 100, 2), nb(couvert, 1), nb(duree_reference, 3), origine_reference, diagnostic),
        )

# --------------------------------------------------------------------------------------------
# 5. Critère 9 — horodatages et densité de segments
# --------------------------------------------------------------------------------------------
probs = []
precedente_fin = -math.inf
precedent_debut = -math.inf
for index, segment in enumerate(segments):
    if not isinstance(segment, dict):
        # Pendant du finding F1 sur ce contrôle : un segment illisible ne doit pas être « sauté »
        # pour laisser la ligne s'imprimer « début < fin partout ». Ce qui n'a pas pu être vérifié
        # est nommé (le contrôle 3 le nomme aussi, de son côté).
        probs.append(
            "segment %d : un %s au lieu d'un objet — ses horodatages n'ont pas pu être vérifiés" % (index, type(segment).__name__)
        )
        continue
    debut = segment.get("start")
    fin = segment.get("end")
    if not est_nombre(debut) or not est_nombre(fin):
        probs.append("segment %d : horodatages non numériques" % index)
        continue
    debut, fin = float(debut), float(fin)
    if debut < 0:
        probs.append("segment %d : début négatif (%s s)" % (index, nb(debut)))
    if debut >= fin:
        probs.append("segment %d : début %s s >= fin %s s" % (index, nb(debut), nb(fin)))
    elif debut <= precedent_debut:
        probs.append("segments %d et %d : débuts non strictement croissants (%s s puis %s s)" % (index - 1, index, nb(precedent_debut), nb(debut)))
    elif debut < precedente_fin - 1e-6:
        probs.append(
            "segment %d : commence à %s s avant la fin du précédent (%s s) — recouvrement/régression"
            % (index, nb(debut), nb(precedente_fin))
        )
    precedent_debut = debut
    precedente_fin = max(precedente_fin, fin)
    if len(probs) >= 5:
        break

reference = duree_reference if (duree_reference is not None and duree_reference > 0) else None
if reference is None:
    probs.append("aucune durée de référence pour la densité de segments")
elif not segments:
    probs.append("aucun segment : 0 segment par 30 s (≥ 1 attendu)")
else:
    par_30s = len(segments) / (reference / 30.0)
    if par_30s < 1.0:
        probs.append(
            "%s segment(s) pour 30 s (< 1) : %d segments sur %s s — il en faut au moins %d"
            % (nb(par_30s, 2), len(segments), nb(reference, 3), math.ceil(reference / 30.0))
        )
if probs:
    ligne(5, "ECHEC", " ; ".join(probs[:6]))
else:
    ligne(
        5,
        "OK",
        "%d segments, début < fin partout, débuts strictement croissants, aucun recouvrement, %s segment(s) par 30 s (≥ 1)"
        % (len(segments), nb(par_30s, 2)),
    )

# --------------------------------------------------------------------------------------------
# 6. Critère 12 — langue détectée, et relue à la reprise
# --------------------------------------------------------------------------------------------
probs = []
langue = doc.get("language") if isinstance(doc.get("language"), str) else None
forcee = doc.get("languageWasForced")
if langue is None or not langue.strip():
    probs.append("`language` est vide : sans option, la langue doit avoir été détectée automatiquement (critère 12)")
if forcee is not False:
    probs.append(
        "`languageWasForced` vaut %r : un document produit sans option de langue doit porter false (critère 12)" % forcee
    )
if not resumed_path:
    ligne(
        6,
        "NON_EXECUTE",
        "`--resumed-from` absent : la relecture de la langue à la reprise n'a pas été éprouvée. "
        "Recette : interrompre une passe (le document reste `status: \"inProgress\"`), la relancer, puis "
        "passer ici le document d'avant reprise — `language`/`languageWasForced` doivent être identiques avant et après "
        "(obligation de conception du lot 8, plan §2.1)",
    )
else:
    if not os.path.isfile(resumed_path):
        probs.append("document d'avant reprise : « %s » n'existe pas (test -f)" % resumed_path)
    else:
        # Sentinelle distincte de `None` : « je n'ai pas pu lire » et « j'ai lu, la valeur est
        # `null` » sont deux états différents (`json.loads("null")` **réussit** et rend `None`).
        # Les confondre faisait sortir ce contrôle `OK` — « relue à la reprise » — sans qu'aucune
        # comparaison ait eu lieu : un document d'avant reprise valant `null` n'entrait ni dans la
        # branche objet ni dans la branche « type inattendu » (finding R2-F1 de la revue du round 2,
        # même famille que F1 du round 1). Un contrôle qui n'a rien comparé n'est jamais un vert.
        ILLISIBLE = object()
        try:
            avant = json.loads(lire(resumed_path))
        except Exception as erreur:
            avant = ILLISIBLE
            probs.append("document d'avant reprise illisible (%s)" % erreur)
        if isinstance(avant, dict):
            if avant.get("status") != "inProgress":
                probs.append(
                    "le document d'avant reprise porte `status` %r au lieu de « inProgress » : ce n'est pas une reprise"
                    % avant.get("status")
                )
            if avant.get("language") != doc.get("language") or avant.get("languageWasForced") != doc.get("languageWasForced"):
                probs.append(
                    "reprise : la langue a changé entre le document interrompu (`%s`/`%s`) et le document final (`%s`/`%s`) — "
                    "la langue du document doit être relue, jamais re-détectée"
                    % (
                        avant.get("language"),
                        avant.get("languageWasForced"),
                        doc.get("language"),
                        doc.get("languageWasForced"),
                    )
                )
        elif avant is not ILLISIBLE:
            # Le document d'avant reprise est un JSON valide mais pas un objet : `json.loads` a
            # réussi, la comparaison n'a pas eu lieu. Sans cette branche, `probs` restait vide et le
            # contrôle s'imprimait `OK` — « je n'ai pas pu comparer » rendu « j'ai comparé, c'est
            # identique ». Un contrôle qui n'exécute rien n'est jamais un vert (doctrine de ce
            # script, §en-tête) : c'est donc un ECHEC, nommant le critère 12. Le type est nommé
            # littéralement pour `null` : `type(None).__name__` (« NoneType ») ne dit pas au lecteur
            # que c'est bien la valeur JSON `null` qui a été lue.
            probs.append(
                "document d'avant reprise : un JSON de type %s au lieu d'un objet — la langue relue à la reprise "
                "n'a pas pu être comparée (critère 12), et un contrôle qui n'a rien comparé n'est jamais un vert"
                % ("null (NoneType)" if avant is None else type(avant).__name__)
            )
    if probs:
        ligne(6, "ECHEC", " ; ".join(probs))
    else:
        ligne(
            6,
            "OK",
            "langue « %s » détectée sans option (`languageWasForced` false) et **relue** à la reprise : identique dans le document interrompu et dans le document final"
            % doc.get("language"),
        )

# --------------------------------------------------------------------------------------------
# 7. Critère 10 — pic mémoire sur une passe de 2 h
# --------------------------------------------------------------------------------------------
if not ev:
    ligne(7, "NON_EXECUTE", "`--evidence` absent : la mesure « /usr/bin/time -l » de la passe de 2 h n'est pas fournie")
else:
    fichier_temps = os.path.join(ev, "memoire-2h.time.txt")
    fichier_duree = os.path.join(ev, "memoire-2h.duree.txt")
    if not os.path.isfile(fichier_temps):
        ligne(7, "NON_EXECUTE", "« %s » absent : la mesure de pic mémoire n'a pas été fournie" % fichier_temps)
    elif not os.path.isfile(fichier_duree):
        ligne(7, "NON_EXECUTE", "« %s » absent : la durée de l'audio passé n'est pas déclarée" % fichier_duree)
    else:
        contenu_temps = lire(fichier_temps)
        try:
            duree_passe = float(lire(fichier_duree).strip().split()[0])
        except (ValueError, IndexError):
            duree_passe = None
        trouves = re.findall(r"^\s*(\d+)\s+maximum resident set size\s*$", contenu_temps, flags=re.M)
        marqueurs = re.search(r"^\s*[\d.]+\s+real\s", contenu_temps, flags=re.M)
        if not trouves:
            ligne(
                7,
                "NON_EXECUTE",
                "« %s » ne porte pas de ligne « maximum resident set size » : ce n'est pas une sortie de « /usr/bin/time -l » (en-tête attendu : « <octets> maximum resident set size »)"
                % fichier_temps,
            )
        elif not marqueurs:
            ligne(
                7,
                "NON_EXECUTE",
                "« %s » ne porte pas de ligne « <secondes> real » : sortie de « /usr/bin/time -l » incomplète" % fichier_temps,
            )
        elif duree_passe is None:
            ligne(7, "ECHEC", "« %s » ne porte pas de durée lisible (« %s »)" % (fichier_duree, lire(fichier_duree).strip()))
        elif duree_passe < 7200:
            ligne(
                7,
                "NON_EXECUTE",
                "la passe mémoire a duré %s s (< 7200 s) : la borne de 2 Go ne se prouve que sur un audio de 2 h (critère 10)"
                % nb(duree_passe, 1),
            )
        else:
            pic = max(int(valeur) for valeur in trouves)
            if pic >= 2 * GO:
                ligne(
                    7,
                    "ECHEC",
                    "pic mémoire %s Go (≥ 2 Go) sur une passe de %s s — attendu < 2 Go, l'audio n'a pas été transcrit en mode incrémental (critère 10, plan §2.1)"
                    % (nb(pic / GO, 2), nb(duree_passe, 1)),
                )
            else:
                ligne(
                    7,
                    "OK",
                    "pic mémoire %s Go < 2 Go (mesure « /usr/bin/time -l » sur une passe de %s s)" % (nb(pic / GO, 2), nb(duree_passe, 1)),
                )

# --------------------------------------------------------------------------------------------
# 8. Critère 11 — aucune connexion sortante
# --------------------------------------------------------------------------------------------
echantillons_processus = []
if ev and os.path.isfile(os.path.join(ev, "processus.txt")):
    echantillons_processus = echantillons(lire(os.path.join(ev, "processus.txt")))

if not ev:
    ligne(8, "NON_EXECUTE", "`--evidence` absent : les échantillons de connexions de la passe ne sont pas fournis")
else:
    fichier_reseau = os.path.join(ev, "reseau.txt")
    if not os.path.isfile(fichier_reseau):
        ligne(8, "NON_EXECUTE", "« %s » absent : aucune capture de connexions pendant la transcription" % fichier_reseau)
    else:
        blocs = echantillons(lire(fichier_reseau))
        probs = []
        if len(blocs) < 2:
            ligne(
                8,
                "NON_EXECUTE",
                "« %s » ne porte que %d échantillon(s) (« # SAMPLE <epoch> <pid> ») : la capture n'a pas couvert la passe"
                % (fichier_reseau, len(blocs)),
            )
        else:
            pids = sorted({b[0].split()[1] for b in blocs if len(b[0].split()) > 1})
            if len(pids) != 1:
                probs.append(
                    "les %d échantillons portent %d PID différents (%s) : on ne sait pas de quel processus on a regardé les connexions"
                    % (len(blocs), len(pids), ", ".join(pids[:4]))
                )
            sortantes = []
            for entete, lignes in blocs:
                for ligne_lsof in lignes:
                    if "->" not in ligne_lsof:
                        continue
                    distante = ligne_lsof.split("->", 1)[1].strip().split()[0]
                    hote = distante.split(":")[0].strip("[]")
                    if hote in ("127.0.0.1", "localhost", "::1"):
                        continue
                    if distante not in sortantes:
                        sortantes.append(distante)
            if sortantes:
                probs.append(
                    "%d connexion(s) sortante(s) non locales pendant la transcription (ex. %s) : le critère 11 exige la transcription réseau coupé"
                    % (len(sortantes), ", ".join(sortantes[:3]))
                )
            if len(pids) == 1 and echantillons_processus:
                pid = pids[0]
                vu = any(
                    any(pid in ligne_processus and "Murmure" in ligne_processus for ligne_processus in lignes)
                    for _, lignes in echantillons_processus
                )
                if not vu:
                    probs.append(
                        "le PID %s des échantillons de connexions n'apparaît dans aucun échantillon de processus avec « Murmure » : ces connexions ne sont pas attribuables à l'app" % pid
                    )
            if probs:
                ligne(8, "ECHEC", " ; ".join(probs))
            else:
                ligne(
                    8,
                    "OK",
                    "%d échantillons « lsof » du PID %s pendant la transcription : aucune connexion sortante (seules les adresses locales sont admises)"
                    % (len(blocs), pids[0]),
                )

# --------------------------------------------------------------------------------------------
# 9. Critère 13 — aucun processus de transcription séparé
# --------------------------------------------------------------------------------------------
if not ev:
    ligne(9, "NON_EXECUTE", "`--evidence` absent : les échantillons de processus de la passe ne sont pas fournis")
elif not os.path.isfile(os.path.join(ev, "processus.txt")):
    ligne(9, "NON_EXECUTE", "« %s » absent : aucun échantillon de processus pendant la transcription" % os.path.join(ev, "processus.txt"))
else:
    blocs = echantillons_processus
    probs = []
    if len(blocs) < 2:
        ligne(
            9,
            "NON_EXECUTE",
            "« %s » ne porte que %d échantillon(s) (« # SAMPLE <epoch> ») : la capture n'a pas couvert la passe"
            % (os.path.join(ev, "processus.txt"), len(blocs)),
        )
    else:
        app_vue = sum(
            1
            for _, lignes in blocs
            if any("Murmure" in ligne_processus for ligne_processus in lignes)
        )
        if app_vue == 0:
            probs.append(
                "aucun échantillon ne montre l'app en cours d'exécution : rien ne prouve que ces échantillons couvrent la passe (attendu : une ligne « Murmure »)"
            )
        interdits = []
        for entete, lignes in blocs:
            for ligne_processus in lignes:
                if re.search(MOTIFS_INTERDITS, ligne_processus, flags=re.I):
                    extrait = normaliser(ligne_processus)[:120]
                    if extrait not in interdits:
                        interdits.append(extrait)
        if interdits:
            probs.append(
                "processus de transcription séparé lancé pendant la passe (motifs %s) : %s"
                % (MOTIFS_INTERDITS.replace("|", ", "), " | ".join(interdits[:2]))
            )
        if probs:
            ligne(9, "ECHEC", " ; ".join(probs))
        else:
            ligne(
                9,
                "OK",
                "%d échantillons de processus pendant la transcription, l'app vue dans %d d'entre eux, aucun processus des motifs « %s » — limites : un auxiliaire dont le nom ne porte aucun de ces motifs échapperait à ce contrôle"
                % (len(blocs), app_vue, MOTIFS_INTERDITS.replace("|", ", ")),
            )

# --------------------------------------------------------------------------------------------
# 10. Critère 15 — le texte transcrit n'apparaît dans aucun journal
# --------------------------------------------------------------------------------------------
dossier_journaux = logs_arg or (os.path.join(ev, "logs") if ev else "")
if not dossier_journaux:
    ligne(10, "NON_EXECUTE", "`--logs` (ou `--evidence`) absent : aucun journal de l'app à fouiller")
elif not os.path.isdir(dossier_journaux):
    ligne(10, "NON_EXECUTE", "« %s » n'est pas un répertoire de journaux (test -d)" % dossier_journaux)
else:
    fichiers = [
        f
        for f in sorted(glob.glob(os.path.join(dossier_journaux, "**", "*"), recursive=True))
        if os.path.isfile(f) and os.path.getsize(f) > 0
    ]
    candidats = extraits(segments)
    if not fichiers:
        ligne(
            10,
            "NON_EXECUTE",
            "aucun journal non vide dans « %s » : la recherche « 0 occurrence » n'a rien dans quoi chercher (critère 15)" % dossier_journaux,
        )
    elif not candidats:
        ligne(
            10,
            "NON_EXECUTE",
            "aucun segment du JSON n'est assez long pour un extrait de %d caractères : la recherche du texte dans les journaux ne peut pas être éprouvée" % TAILLE_EXTRAIT,
        )
    else:
        occurrences = []
        for chemin in fichiers:
            contenu = lire(chemin)
            contenu_normalise = normaliser(contenu)
            for candidat in candidats:
                if candidat in contenu or candidat in contenu_normalise:
                    occurrences.append((os.path.basename(chemin), empreinte(candidat)))
        if occurrences:
            vues = sorted({nom for nom, _ in occurrences})
            ligne(
                10,
                "ECHEC",
                "%d occurrence(s) du texte transcrit dans les journaux (%s ; extraits nommés par leur empreinte sha256 : %s) — le critère 15 exige 0"
                % (
                    len(occurrences),
                    ", ".join(vues[:3]),
                    ", ".join(sorted({e for _, e in occurrences})[:3]),
                ),
            )
        else:
            ligne(
                10,
                "OK",
                "%d extraits de %d caractères du transcript recherchés dans %d journal(aux) non vide(s) de « %s » : 0 occurrence — limite : la recherche porte sur le texte, pas sur l'audio"
                % (len(candidats), TAILLE_EXTRAIT, len(fichiers), dossier_journaux),
            )

# Clauses déclarées hors de portée de ce contrat (règle 11 : un contrôle qui n'exécute rien n'est
# pas un contrôle, mais une clause sans surface observable doit être nommée, pas passée sous silence).
declaration(
    "critère 13 — clause ANE",
    "« la spécialisation Neural Engine de l'app est réutilisée (< 5 s après un premier usage) » : hors de portée de ce contrat (aucune surface observable par script) — rattachée à la gate humaine (plan §6 risque 9)",
)

print("\n".join(sortie))
PY
}

# ---------------------------------------------------------------------------------------------
# Mode « self-test » : la preuve que les dix contrôles discriminent.
#
# Un contrat qui n'a jamais rien vu échouer n'est pas un contrat. Ce mode fabrique, dans un
# répertoire temporaire, un jeu de preuves complet et cohérent (qui doit passer), puis une
# mutation par contrôle (qui doit échouer en nommant son critère) **et un document vert qui doit
# nommer son trou de 24 s** (le diagnostic du critère 9 se prouve là où il est le plus facile à
# perdre : sur un document qui passe), et il laisse le script se contredire lui-même : 31 exécutions
# réelles, aucun fichier du dépôt touché.
# ---------------------------------------------------------------------------------------------
self_test() {
    local temporaire
    temporaire="$(mktemp -d "${TMPDIR:-/tmp}/transcription-contract-XXXXXX")"
    # TRANSCRIPTION_CONTRACT_KEEP=1 conserve les fixtures : c'est ce qui permet de rejouer un cas
    # à la main quand le self-test en signale un.
    if [ "${TRANSCRIPTION_CONTRACT_KEEP:-}" = "1" ]; then
        printf 'fixtures conservées : %s\n' "$temporaire"
    else
        # shellcheck disable=SC2064
        trap "rm -rf '$temporaire'" EXIT
    fi

    local base="$temporaire/bon"
    if ! python3 - "$base" <<'PY'
import json, os, sys

base = sys.argv[1]
duree = 2292.599
nombre = 115
pas = duree / nombre

def segments(count=nombre, longueur=None):
    out = []
    for index in range(count):
        debut = index * pas
        fin = debut + (pas - 0.35 if longueur is None else longueur)
        fin = min(fin, duree)
        texte = (
            "Le segment %03d rappelle que la couverture se mesure et ne se declare pas, "
            "avec %d secondes transcrites dans cette passe de controle." % (index, int(fin))
        )
        out.append({"start": round(debut, 3), "end": round(fin, 3), "text": texte})
    return out

def document(segs, statut="complete", langue="fr", forcee=False):
    couvert = sum(s["end"] - s["start"] for s in segs)
    return {
        "schemaVersion": 1,
        "id": "video-a-2026-09-22-ab12cd34",
        "title": "Video A de controle",
        "source": {"kind": "youtube", "url": "https://example.invalid/watch?v=ab12cd34", "identity": "ab12cd34"},
        "duration": duree,
        "language": langue,
        "languageWasForced": forcee,
        "model": "large-v3-turbo",
        "createdAt": "2026-09-22T10:00:00Z",
        "status": statut,
        "segments": segs,
        "coverage": {"coveredSeconds": round(couvert, 3), "ratio": round(couvert / duree, 5)},
        "boundaries": [
            {"start": round(i * 300.0, 3), "duration": 300.0, "quality": "forced"} for i in range(1, 7)
        ],
    }

segs = segments()
doc = document(segs)
doc["completedAt"] = "2026-09-22T10:41:00Z"
paragraphes = []
courant = []
longueur = 0
for segment in segs:
    courant.append(segment["text"])
    longueur += len(segment["text"]) + 1
    if longueur >= 400:
        paragraphes.append(" ".join(courant))
        courant, longueur = [], 0
if courant:
    paragraphes.append(" ".join(courant))
markdown = "# Video A de controle\n\nSource : https://example.invalid/watch?v=ab12cd34\n\n" + "\n\n".join(paragraphes) + "\n"

os.makedirs(base, exist_ok=True)
os.makedirs(os.path.join(base, "ev", "logs"), exist_ok=True)
os.makedirs(os.path.join(base, "app", "Contents", "MacOS"), exist_ok=True)
with open(os.path.join(base, "app", "Contents", "MacOS", "Murmure"), "w") as f:
    f.write("#!/bin/sh\nexit 0\n")
with open(os.path.join(base, "transcript.json"), "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
with open(os.path.join(base, "transcript.md"), "w") as f:
    f.write(markdown)
avant = document(segs, statut="inProgress")
avant.pop("completedAt", None)
with open(os.path.join(base, "reprise.json"), "w") as f:
    json.dump(avant, f, ensure_ascii=False, indent=2)
with open(os.path.join(base, "ev", "memoire-2h.time.txt"), "w") as f:
    f.write("     1450.00 real       900.00 user        12.00 sys\n          1468006400  maximum resident set size\n")
with open(os.path.join(base, "ev", "memoire-2h.duree.txt"), "w") as f:
    f.write("7203.5\n")
with open(os.path.join(base, "ev", "reseau.txt"), "w") as f:
    for epoch, corps in (
        (1790000000, ["COMMAND  PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n", "Murmure 4242 louis 23u IPv4 0x1 0t0 TCP 127.0.0.1:52344->127.0.0.1:11434 (ESTABLISHED)\n"]),
        (1790000005, ["Murmure 4242 louis 23u IPv4 0x1 0t0 TCP 127.0.0.1:52344->127.0.0.1:11434 (ESTABLISHED)\n"]),
        (1790000010, []),
    ):
        f.write("# SAMPLE %d 4242\n" % epoch)
        f.writelines(corps)
with open(os.path.join(base, "ev", "processus.txt"), "w") as f:
    for epoch in (1790000000, 1790000005, 1790000010):
        f.write("# SAMPLE %d\n" % epoch)
        f.write(" 4242     1 /Users/louiscourcier/Applications/Murmure.app/Contents/MacOS/Murmure\n")
with open(os.path.join(base, "ev", "logs", "murmure-unified.log"), "w") as f:
    f.write("2026-09-22 10:00:01.000000+0200 0x1 Default 0x0 4242 0 murmure: [transcription] modele charge\n")
    f.write("2026-09-22 10:41:00.000000+0200 0x2 Default 0x0 4242 0 murmure: [transcription] transcript ecrit\n")
print("fixture de base : %s" % base)
PY
    then
        printf 'self-test : la fabrication du jeu de base a échoué\n' >&2
        return 1
    fi

    local cas mutation_rc
    for cas in \
        md-absent md-vide json-illisible champ-manquant statut-incomplet couverture-basse couverture-avec-duree-mesuree \
        horodatage-regression debut-egal-fin segments-trop-rares langue-vide langue-forcee \
        memoire-depassee memoire-duree-courte memoire-pas-un-time-l reseau-sortant reseau-sans-echantillons \
        processus-separe processus-sans-app journaux-avec-texte journaux-vides reprise-langue-differente \
        reprise-non-objet reprise-null segment-non-objet document-non-objet jeton-special-dans-le-texte \
        trou-de-24-s
    do
        # Le code de retour de la mutation est contrôlé : une fixture qui n'a pas été mutée ferait
        # passer un cas pour vert alors qu'il n'a rien éprouvé (mesuré : un `else: raise` manquant
        # laissait le cas « JSON illisible » vert). Le heredoc n'est jamais placé dans une
        # substitution de commande : bash 3.2 (celui de macOS) y lit le corps comme du texte de
        # shell et se perd sur une apostrophe.
        python3 - "$base" "$temporaire/$cas" "$cas" <<'PY'
import json, os, shutil, sys

base, cible, cas = sys.argv[1], sys.argv[2], sys.argv[3]
shutil.copytree(base, cible)
chemin = os.path.join(cible, "transcript.json")
doc = json.load(open(chemin))
segs = doc["segments"]
pas = doc["duration"] / len(segs)

def couverture(segs):
    return sum(s["end"] - s["start"] for s in segs)

def reecrire(doc, segs):
    doc["segments"] = segs
    couvert = couverture(segs)
    doc["coverage"] = {"coveredSeconds": round(couvert, 3), "ratio": round(couvert / doc["duration"], 5)}

if cas == "md-absent":
    os.remove(os.path.join(cible, "transcript.md"))
elif cas == "md-vide":
    open(os.path.join(cible, "transcript.md"), "w").close()
elif cas == "champ-manquant":
    doc.pop("model")
elif cas == "statut-incomplet":
    doc["status"] = "inProgress"
    doc.pop("completedAt", None)
elif cas == "couverture-basse":
    garde = []
    for segment in segs:
        if couverture(garde + [segment]) / doc["duration"] <= 0.90:
            garde.append(segment)
    reecrire(doc, garde)
elif cas == "couverture-avec-duree-mesuree":
    garde = []
    for segment in segs:
        if couverture(garde + [segment]) / doc["duration"] <= 0.975:
            garde.append(segment)
    reecrire(doc, garde)
elif cas == "horodatage-regression":
    segs[20]["start"] = round(segs[19]["end"] - 2.0, 3)
    reecrire(doc, segs)
elif cas == "debut-egal-fin":
    segs[30]["end"] = segs[30]["start"]
    reecrire(doc, segs)
elif cas == "segments-trop-rares":
    seuls = []
    index = 0
    while index < len(segs):
        seuls.append(segs[index])
        index += 3
    for index, segment in enumerate(seuls):
        segment["start"] = round(index * (doc["duration"] / len(seuls)), 3)
        segment["end"] = round(min(segs[-1]["end"], segment["start"] + 58.3), 3)
    reecrire(doc, seuls)
elif cas == "langue-vide":
    doc["language"] = ""
elif cas == "langue-forcee":
    doc["languageWasForced"] = True
elif cas == "memoire-depassee":
    with open(os.path.join(cible, "ev", "memoire-2h.time.txt"), "w") as f:
        f.write("     3100.00 real      2400.00 user        30.00 sys\n          2684354560  maximum resident set size\n")
elif cas == "memoire-duree-courte":
    with open(os.path.join(cible, "ev", "memoire-2h.duree.txt"), "w") as f:
        f.write("2292.599\n")
elif cas == "memoire-pas-un-time-l":
    with open(os.path.join(cible, "ev", "memoire-2h.time.txt"), "w") as f:
        f.write("passe terminee, 1468006400 octets de pic (note manuscrite)\n")
elif cas == "reseau-sortant":
    with open(os.path.join(cible, "ev", "reseau.txt"), "a") as f:
        f.write("# SAMPLE 1790000015 4242\n")
        f.write("Murmure 4242 louis 24u IPv4 0x2 0t0 TCP 192.168.1.10:53422->142.250.75.238:443 (ESTABLISHED)\n")
elif cas == "reseau-sans-echantillons":
    contenu = open(os.path.join(cible, "ev", "reseau.txt")).read()
    tete = contenu.split("# SAMPLE")[0]
    open(os.path.join(cible, "ev", "reseau.txt"), "w").write(tete + "# SAMPLE 1790000000 4242\n")
elif cas == "processus-separe":
    with open(os.path.join(cible, "ev", "processus.txt"), "a") as f:
        f.write("# SAMPLE 1790000015\n")
        f.write(" 4242     1 /Users/louiscourcier/Applications/Murmure.app/Contents/MacOS/Murmure\n")
        f.write(" 9001     1 /opt/homebrew/bin/whisper-cli -m /models/ggml-large-v3.bin -f unit.wav\n")
elif cas == "processus-sans-app":
    with open(os.path.join(cible, "ev", "processus.txt"), "w") as f:
        for epoch in (1790000000, 1790000005, 1790000010):
            f.write("# SAMPLE %d\n" % epoch)
            f.write("  501     1 /usr/libexec/configd\n")
elif cas == "journaux-avec-texte":
    # Le mode de défaillance visé : l'implémentation journalise le texte transcrit (une unité, ou
    # tout le transcript). Les trente premiers segments sont écrits tels qu'une application
    # bavarde les écrirait.
    with open(os.path.join(cible, "ev", "logs", "murmure-unified.log"), "a") as f:
        for segment in segs[:30]:
            f.write(
                "2026-09-22 10:20:00.000000+0200 0x3 Default 0x0 4242 0 murmure: [transcription] %s\n"
                % " ".join(segment["text"].split())
            )
elif cas == "journaux-vides":
    for nom in os.listdir(os.path.join(cible, "ev", "logs")):
        os.remove(os.path.join(cible, "ev", "logs", nom))
elif cas == "reprise-langue-differente":
    avant = json.load(open(os.path.join(cible, "reprise.json")))
    avant["language"] = "en"
    json.dump(avant, open(os.path.join(cible, "reprise.json"), "w"))
elif cas == "reprise-non-objet":
    # Mode de défaillance visé (finding F1 de la revue du round 1) : `json.loads` réussit, le
    # document d'avant reprise n'est pas un objet, donc aucune comparaison de langue n'a lieu — le
    # contrôle 6 ne doit pas pour autant s'imprimer « OK, relue à la reprise ».
    json.dump([], open(os.path.join(cible, "reprise.json"), "w"))
elif cas == "reprise-null":
    # Pendant du cas précédent, une valeur plus loin (finding R2-F1 de la revue du round 2) :
    # `json.loads("null")` réussit et rend `None`. La sentinelle du chemin « fichier illisible »
    # valant elle-même `None`, ce document n'entrait dans aucune branche et le contrôle 6 sortait
    # `OK` sans rien comparer. Une valeur `null` est un JSON **lu**, pas une lecture en échec.
    open(os.path.join(cible, "reprise.json"), "w").write("null\n")
elif cas == "segment-non-objet":
    # Même famille, sur les horodatages : un segment qui n'est pas un objet ne peut pas être
    # horodaté. La couverture déclarée est recalculée sur les segments lisibles, pour que ce cas
    # n'éprouve que les contrôles qui portent le schéma et les horodatages (le contrôle 4 reste OK).
    segs[0] = "segment sans horodatage"
    lisibles = [s for s in segs if isinstance(s, dict)]
    couvert = couverture(lisibles)
    doc["coverage"] = {"coveredSeconds": round(couvert, 3), "ratio": round(couvert / doc["duration"], 5)}
elif cas == "document-non-objet":
    pass  # écrit plus bas : le document doit rester un tableau
elif cas == "jeton-special-dans-le-texte":
    # Défaut mesuré le 2026-09-22 (`DecodingOptions.skipSpecialTokens` valait `false`, son défaut) : le
    # texte de chaque segment sortait du décodeur avec son préremplissage — `<|startoftranscript|>`
    # `<|fr|><|transcribe|>` en tête d'unité, `<|3.32|> … <|5.32|>` autour de chaque segment. Le
    # contrat restait **vert** avec ce texte : le contrôle 2 (un extrait du JSON se retrouve dans le
    # Markdown), le contrôle 3 (textes non vides) et le contrôle 5 (horodatages) ne regardaient jamais
    # le **contenu** du texte, et un transcript entièrement fait de jetons passait les 10 contrôles.
    # La mutation écrit le texte pollué dans le JSON **et** dans le Markdown, comme l'app les écrivait
    # tous les deux depuis les mêmes segments : une paire incohérente éprouverait le contrôle 2 (les
    # extraits du JSON ne seraient plus dans le Markdown), pas le contrôle 3.
    debuts = set()
    for borne in range(0, int(doc["duration"]) + 1, 300):
        for index, segment in enumerate(segs):
            if segment["start"] >= borne:
                debuts.add(index)
                break
    for index, segment in enumerate(segs):
        texte = "<|%.2f|> %s<|%.2f|>" % (segment["start"], segment["text"], segment["end"])
        if index in debuts:
            texte = "<|startoftranscript|><|%s|><|transcribe|>" % doc["language"] + texte
        segment["text"] = texte
    # Markdown réécrit depuis les segments pollués, avec la fusion du §2.4 (pause ≥ 1,2 s ou 480
    # caractères) : la même règle que la fixture de base, sur le texte d'après pollution.
    entete = "# %s\n\nSource : %s\n\n" % (doc["title"], (doc.get("source") or {}).get("url") or "")
    paragraphes, courant, longueur, precedent = [], [], 0, None
    for segment in segs:
        pause = precedent is not None and (segment["start"] - precedent) >= 1.2
        if courant and (pause or longueur >= 480):
            paragraphes.append(" ".join(courant))
            courant, longueur = [], 0
        courant.append(segment["text"])
        longueur += len(segment["text"]) + 1
        precedent = segment["end"]
    if courant:
        paragraphes.append(" ".join(courant))
    with open(os.path.join(cible, "transcript.md"), "w") as fichier:
        fichier.write(entete + "\n\n".join(paragraphes) + "\n")
elif cas == "trou-de-24-s":
    # Le diagnostic du critère 9 (carte QA t_1fe8dd6c) : la ligne doit **nommer** ses intervalles
    # non couverts ≥ 20 s, bornes et durée — et le faire aussi quand le document **passe**. La
    # fixture garde donc une couverture ≥ 97 % : un segment retiré au milieu (index 84) et le
    # suivant commençant 24 s après la fin de son prédécesseur, au lieu des 0,35 s de la trame de
    # base. La couverture tombe à 97,23 %, le seuil de 97 % tient, et le trou vaut exactement 24,0 s
    # — le mode de défaillance mesuré au round 1 du lot 8 (fenêtre de 30 s sautée par WhisperKit :
    # 24,4 s non couvertes sur [1664,1 ; 1688,5), couverture 97,04 %).
    retire = 84
    segs = segs[:retire] + segs[retire + 1:]
    segs[retire]["start"] = round(segs[retire - 1]["end"] + 24.0, 3)
    reecrire(doc, segs)
elif cas == "json-illisible":
    pass  # écrit plus bas : le document doit rester illisible
else:
    raise SystemExit("cas inconnu : %s" % cas)

if cas == "json-illisible":
    # Le lecteur doit refuser un document illisible sans planter : un traceback serait un rouge
    # muet, alors qu'un rouge doit nommer ce qui manque.
    open(chemin, "w").write("{ ceci n'est pas du JSON\n")
elif cas == "document-non-objet":
    # Pendant du cas précédent : parsable, mais pas un objet. Mesuré avant correction : traceback
    # « 'list' object has no attribute get », aucun contrôle rendu, aucun critère nommé.
    json.dump([], open(chemin, "w"))
else:
    json.dump(doc, open(chemin, "w"), ensure_ascii=False, indent=2)
PY
        mutation_rc=$?
        if [ "$mutation_rc" -ne 0 ]; then
            printf '  [ECHEC] self-test : la fabrication de la fixture « %s » a échoué (code %s)\n' "$cas" "$mutation_rc" >&2
            return 1
        fi
    done

    local bons=0 echecs=0
    local nom dossier rc attendu jeton anomalies sortie arguments anomalies_vues
    # $1 nom · $2 répertoire de fixtures · $3 code de retour attendu · $4 jeton attendu dans la
    # sortie (« » = aucun) · $5 nombre de contrôles en anomalie attendu (« - » = non imposé) ·
    # $6… arguments supplémentaires passés au contrat.
    #
    # Le nombre d'anomalies est ce qui rend chaque cas isolant : une mutation doit faire échouer
    # *son* contrôle et rien d'autre — sans cette borne, un rouge pourrait venir d'ailleurs et le
    # self-test ne prouverait plus rien.
    tester_cas() {
        nom="$1"
        dossier="$2"
        attendu="$3"
        jeton="$4"
        anomalies="$5"
        shift 5
        arguments=("$@")
        sortie="$(bash "$SELF" "$dossier/transcript.json" "$dossier/transcript.md" "$dossier/app" \
            --evidence "$dossier/ev" ${arguments[@]+"${arguments[@]}"} 2>&1)"
        rc=$?
        if [ "$rc" -ne "$attendu" ]; then
            printf '  [ECHEC] self-test · %s : code de retour %s, attendu %s\n' "$nom" "$rc" "$attendu"
            printf '%s\n' "$sortie" | sed -n '1,3p' | sed 's/^/          | /'
            echecs=$((echecs + 1))
            return
        fi
        if [ -n "$jeton" ] && ! printf '%s\n' "$sortie" | grep -qF -e "$jeton"; then
            printf '  [ECHEC] self-test · %s : le message attendu « %s » est absent de la sortie\n' "$nom" "$jeton"
            echecs=$((echecs + 1))
            return
        fi
        if [ "$attendu" -ne 0 ]; then
            # Un rouge doit nommer un critère : c'est ce que la carte demande explicitement.
            # Motif en ASCII : un motif accentué n'est pas fiable selon la locale du `grep`.
            if ! printf '%s\n' "$sortie" | grep -Eq 'crit.* (9|10|11|12|13|15|21)'; then
                printf '  [ECHEC] self-test · %s : le rouge ne nomme aucun critère\n' "$nom"
                echecs=$((echecs + 1))
                return
            fi
        fi
        if [ "$anomalies" != "-" ]; then
            # Motif en ASCII, pour la même raison : « [NON ÉXÉCUTÉ] » accentué ne se compte pas
            # de façon fiable sous toutes les locales.
            anomalies_vues="$(printf '%s\n' "$sortie" | grep -c -e '^  \[ECHEC\]' -e '^  \[NON')"
            if [ "$anomalies_vues" -ne "$anomalies" ]; then
                printf '  [ECHEC] self-test · %s : %s contrôle(s) en anomalie, %s attendu(s)\n' "$nom" "$anomalies_vues" "$anomalies"
                printf '%s\n' "$sortie" | grep -e '^  \[ECHEC\]' -e '^  \[NON' | sed -n '1,3p' | sed 's/^/          | /'
                echecs=$((echecs + 1))
                return
            fi
        fi
        printf '  [OK] self-test · %s : code %s, %s anomalie(s) attendue(s)%s\n' \
            "$nom" "$rc" "${anomalies}" "${jeton:+, message « $jeton » présent}"
        bons=$((bons + 1))
    }

    printf '\nself-test — le contrat s’exerce sur des fixtures fabriquées (aucun fichier du dépôt touché)\n'
    printf 'répertoire de travail : %s\n' "$temporaire"

    tester_cas "jeu complet (doit passer)" "$base" 0 "" 0 --resumed-from "$base/reprise.json"
    tester_cas "Markdown absent" "$temporaire/md-absent" 1 "transcript Markdown" - --resumed-from "$temporaire/md-absent/reprise.json"
    tester_cas "Markdown vide" "$temporaire/md-vide" 1 "est vide" 1 --resumed-from "$temporaire/md-vide/reprise.json"
    tester_cas "JSON illisible" "$temporaire/json-illisible" 1 "n'est pas un document JSON lisible" - --resumed-from "$temporaire/json-illisible/reprise.json"
    tester_cas "document JSON non-objet (parsable)" "$temporaire/document-non-objet" 1 "pas un objet JSON" 10 --resumed-from "$temporaire/document-non-objet/reprise.json"
    tester_cas "segment non-objet (parsable)" "$temporaire/segment-non-objet" 1 "au lieu d'un objet" 2 --resumed-from "$temporaire/segment-non-objet/reprise.json"
    tester_cas "champ \`model\` manquant" "$temporaire/champ-manquant" 1 "champ \`model\` absent" 1 --resumed-from "$temporaire/champ-manquant/reprise.json"
    tester_cas "document non terminé" "$temporaire/statut-incomplet" 1 "status" 1 --resumed-from "$temporaire/statut-incomplet/reprise.json"
    tester_cas "jeton spécial du décodeur dans le texte transcrit" "$temporaire/jeton-special-dans-le-texte" 1 "jeton spécial" 1 --resumed-from "$temporaire/jeton-special-dans-le-texte/reprise.json"
    tester_cas "couverture 90 %" "$temporaire/couverture-basse" 1 "couverture cumul" 1 --resumed-from "$temporaire/couverture-basse/reprise.json"
    tester_cas "couverture refusée par la durée mesurée" "$temporaire/couverture-avec-duree-mesuree" 1 "couverture cumul" 1 --audio-seconds 2350 --resumed-from "$temporaire/couverture-avec-duree-mesuree/reprise.json"
    tester_cas "même jeu, durée mesurée conforme (contrôle)" "$temporaire/couverture-avec-duree-mesuree" 0 "" 0 --audio-seconds 2292.599 --resumed-from "$temporaire/couverture-avec-duree-mesuree/reprise.json"
    # Le diagnostic du critère 9 se prouve sur un **vert** : la couverture de cette fixture vaut
    # 97,23 % (≥ 97 %, donc code 0 et zéro anomalie) et elle porte un seul trou, de 24,0 s sur
    # [1674,2 ; 1698,2). Un contrat qui se contenterait de « couverture ≥ 97 % » passerait ce cas
    # sans jamais nommer le trou — c'est exactement le silence mesuré au round 1 du lot 8.
    tester_cas "trou de 24 s nommé sur un document vert" "$temporaire/trou-de-24-s" 0 "1 trou(s) ≥ 20 s : [1674,2 → 1698,2) 24,0 s" 0 --resumed-from "$temporaire/trou-de-24-s/reprise.json"
    tester_cas "horodatage en régression" "$temporaire/horodatage-regression" 1 "recouvrement" 1 --resumed-from "$temporaire/horodatage-regression/reprise.json"
    tester_cas "segment début >= fin" "$temporaire/debut-egal-fin" 1 ">= fin" 1 --resumed-from "$temporaire/debut-egal-fin/reprise.json"
    tester_cas "moins d’un segment par 30 s" "$temporaire/segments-trop-rares" 1 "pour 30 s" 1 --resumed-from "$temporaire/segments-trop-rares/reprise.json"
    tester_cas "langue vide" "$temporaire/langue-vide" 1 "\`language\` est vide" 1 --resumed-from "$temporaire/langue-vide/reprise.json"
    tester_cas "langue marquée forcée sans option" "$temporaire/langue-forcee" 1 "languageWasForced" 1 --resumed-from "$temporaire/langue-forcee/reprise.json"
    tester_cas "pic mémoire 2,5 Go" "$temporaire/memoire-depassee" 1 "attendu < 2 Go" 1 --resumed-from "$temporaire/memoire-depassee/reprise.json"
    tester_cas "passe mémoire trop courte" "$temporaire/memoire-duree-courte" 1 "ne se prouve que sur" 1 --resumed-from "$temporaire/memoire-duree-courte/reprise.json"
    tester_cas "fichier qui n’est pas un « time -l »" "$temporaire/memoire-pas-un-time-l" 1 "time -l" 1 --resumed-from "$temporaire/memoire-pas-un-time-l/reprise.json"
    tester_cas "connexion sortante" "$temporaire/reseau-sortant" 1 "connexion(s) sortante(s)" 1 --resumed-from "$temporaire/reseau-sortant/reprise.json"
    tester_cas "capture réseau trop courte" "$temporaire/reseau-sans-echantillons" 1 "ne porte que" 1 --resumed-from "$temporaire/reseau-sans-echantillons/reprise.json"
    tester_cas "processus whisper-cli" "$temporaire/processus-separe" 1 "processus de transcription s" 1 --resumed-from "$temporaire/processus-separe/reprise.json"
    tester_cas "capture sans l’app" "$temporaire/processus-sans-app" 1 "ne montre l" 2 --resumed-from "$temporaire/processus-sans-app/reprise.json"
    tester_cas "texte transcrit dans les journaux" "$temporaire/journaux-avec-texte" 1 "occurrence(s) du texte transcrit" 1 --resumed-from "$temporaire/journaux-avec-texte/reprise.json"
    tester_cas "journaux vides" "$temporaire/journaux-vides" 1 "aucun journal non vide" 1 --resumed-from "$temporaire/journaux-vides/reprise.json"
    tester_cas "reprise avec langue changée" "$temporaire/reprise-langue-differente" 1 "la langue a chang" 1 --resumed-from "$temporaire/reprise-langue-differente/reprise.json"
    tester_cas "reprise illisible (JSON non-objet)" "$temporaire/reprise-non-objet" 1 "au lieu d'un objet" 1 --resumed-from "$temporaire/reprise-non-objet/reprise.json"
    tester_cas "reprise nulle (JSON null)" "$temporaire/reprise-null" 1 "null (NoneType)" 1 --resumed-from "$temporaire/reprise-null/reprise.json"
    tester_cas "reprise non éprouvée" "$base" 1 "--resumed-from" 1

    printf '\n'
    if [ "$echecs" -eq 0 ]; then
        printf 'VERT — self-test : %s cas conformes sur %s. Les 10 contrôles discriminent : le jeu complet passe, chaque mutation échoue en nommant son critère, et le document vert à trou de 24 s nomme son trou.\n' \
            "$bons" "$((bons + echecs))"
        return 0
    fi
    printf 'ROUGE — self-test : %s cas non conformes sur %s.\n' "$echecs" "$((bons + echecs))"
    return 1
}

if [ "$MODE" = "self-test" ]; then
    self_test
    exit $?
fi

# ---------------------------------------------------------------------------------------------
# Exécution du contrat
# ---------------------------------------------------------------------------------------------
printf '%s — contrat observable du lot 8 : moteur de transcription vidéo (critères 9, 10, 11, 12, 13, 15, 21)\n\n' "$NOM"
printf 'transcript JSON     : %s\n' "$JSON"
printf 'transcript Markdown : %s\n' "$MD"
printf 'app installée       : %s\n' "$APP"
printf 'preuves             : %s\n' "${EVIDENCE:-(aucune : les contrôles 7 à 10 sortiront « non exécuté »)}"
printf 'document d’avant reprise : %s\n' "${RESUMED:-(aucun : le contrôle de reprise du critère 12 sortira « non exécuté »)}"
printf 'journaux            : %s\n' "${LOGS:-${EVIDENCE:+$EVIDENCE/logs}}"
printf 'référence de couverture : %s\n' "${AUDIO_SECONDS:-(durée déclarée par le document)}"
printf 'dépôt               : %s\n' "$REPO_ROOT"

ANALYSE="$(analyser 2>&1)"
analyse_rc=$?

if [ "$analyse_rc" -ne 0 ]; then
    printf '\nROUGE — le lecteur du contrat a échoué (code %s) : %s\n' "$analyse_rc" "$(printf '%s' "$ANALYSE" | head -3)"
    printf '  les 10 contrôles (critères 9, 10, 11, 12, 13, 15, 21) n’ont pas été rendus : rien n’est certifié.\n'
    exit 1
fi

rendus=0
while IFS=$'\t' read -r num titre critere verdict message; do
    [ -z "${verdict:-}" ] && continue
    if [ "$verdict" = "NON_COUVERT" ]; then
        non_couvert "$critere — $message"
        continue
    fi
    rendus=$((rendus + 1))
    printf '\n%s/%s %s\n' "$num" "$CHECK_TOTAL" "$titre"
    case "$verdict" in
        OK)          ok "$critere — $message" ;;
        ECHEC)       echec "$critere — $message" ;;
        NON_EXECUTE) non_execute "$critere — $message" ;;
        *)           echec "$critere — verdict inconnu « $verdict »" ;;
    esac
done <<< "$ANALYSE"

if [ "$rendus" -ne "$CHECK_TOTAL" ]; then
    printf '\nROUGE — %s contrôle(s) rendu(s) sur %s : l’analyse a été tronquée, rien n’est certifié.\n' "$rendus" "$CHECK_TOTAL"
    exit 1
fi

printf '\n'
if [ "$failures" -eq 0 ] && [ "$not_run" -eq 0 ]; then
    printf 'VERT — %s/%s contrôles passent : le transcript porte les deux formats et le schéma du §2.4, sa couverture cumulée est ≥ 97 %%, ses horodatages sont strictement croissants avec ≥ 1 segment par 30 s, sa langue est détectée puis relue à la reprise, et la passe a tenu sous 2 Go de pic mémoire, sans connexion sortante, sans processus de transcription séparé et sans laisser le texte transcrit dans les journaux.\n' \
        "$CHECK_TOTAL" "$CHECK_TOTAL"
    exit 0
fi

printf "ROUGE — le contrat observable du lot 8 n'est pas tenu : %s manque(s) constaté(s), %s contrôle(s) non exécuté(s) sur %s.\n" \
    "$failures" "$not_run" "$CHECK_TOTAL"
if [ "$failures" -gt 0 ]; then
    printf '  manques :\n%s' "$FAIL_LIST"
fi
if [ "$not_run" -gt 0 ]; then
    printf '  contrôles non exécutés :\n%s' "$SKIP_LIST"
fi
printf '\n  attendu : un transcript terminé (`status: "complete"`) produit par le moteur vidéo du lot 8 —\n'
printf '            JSON + Markdown de même tige, schéma du §2.4, couverture ≥ 97 %%, horodatages\n'
printf '            strictement croissants, ≥ 1 segment / 30 s, langue détectée puis relue à la reprise,\n'
printf '            passe de 2 h sous 2 Go de pic mémoire, réseau coupé, aucun processus de transcription\n'
printf '            séparé, aucun texte transcrit dans les journaux (SPEC critères 9, 10, 11, 12, 13, 15, 21).\n'
exit 1
