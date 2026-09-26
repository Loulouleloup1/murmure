#!/usr/bin/env bash
# Contrat du critère 20 — le CLI `murmure` (plan §2.5, §4 lot 11).
#
# POURQUOI CE CONTRÔLE EXISTE. Le plan promet un binaire que « tout agent peut appeler » : trois
# commandes qui répondent **application fermée** (`list`, `read`, `version`), deux qui ont besoin de
# l'application (`transcribe`, `status`), des codes de sortie qui distinguent « usage »,
# « injoignable » et « échec du travail », et un protocole fait d'**une ligne JSON par message**.
# Aucun de ces faits ne s'observe dans une compilation : ils s'observent en lançant le binaire.
#
# CE QUE CE SCRIPT CONTRÔLE :
#   1/7 le binaire se construit (`swift build --product murmure`) ;
#   2/7 `version` répond application fermée, sans socket ;
#   3/7 `list` **dit la vérité sur le disque** : les transcripts lisibles sont nommés avec le chemin
#       absolu de leur JSON, le `.json` tronqué est **compté** comme illisible, et le fichier de
#       `work/` est ignoré (le dossier de travail n'est pas la bibliothèque) ;
#   4/7 `read` résout un id, une tige, un nom de fichier, un chemin — et refuse : un inconnu et un
#       document illisible sortent en **1** (« la demande est bien formée, la chose demandée
#       n'existe pas » — `ControlProtocolTests` le gèle noir sur blanc), un préfixe ambigu et un
#       chemin hors de la racine en **2** (la requête elle-même ne désigne pas un transcript unique
#       et légal) ;
#   5/7 `transcribe` et `status` sans application rendent **3**, avec la raison sur la sortie
#       d'erreur et rien sur la sortie standard — jamais 0, jamais un silence ;
#   6/7 avec une **doublure** de serveur : `transcribe` et `status` rendent 0 et affichent la
#       réponse ; `--json` sort une ligne qui se relit ;
#   7/7 la doublure **refuse** : ligne tronquée et ligne illisible rendent 2, une réponse qui dit
#       l'échec rend 1 et la raison sur la sortie d'erreur. C'est la raison d'être de la doublure :
#       elle ne ressemble pas à l'application, donc un « ça a marché » de complaisance ne passe pas.
#   8/8 `--output` **ne réécrit jamais le code de la réponse** : une réponse qui dit l'échec (1) ou
#       l'application injoignable (3) sort avec **ce** code et ne copie rien — le défaut corrigé
#       après la revue round 1 (F1), un `--output` qui rendait 2 au-dessus de tout et ajoutait
#       « `--output` needs `--wait` » alors que `--wait` avait été demandé. Un succès sans document
#       reste un usage (2), et un succès avec document copie réellement les deux fichiers.
#
# CE QU'IL NE FAIT PAS, ET C'EST DÉLIBÉRÉ : il ne lance pas l'application, n'ouvre pas
# `Murmure.app`, ne touche ni à `~/Library/Application Support/Murmure` ni aux transcripts réels
# (AGENTS.md) — la racine lue est un dossier temporaire (`MURMURE_TRANSCRIPTS_DIR`), le socket visé
# est un socket temporaire (`MURMURE_CONTROL_SOCKET`) et le lancement de l'application est désarmé
# (`MURMURE_NO_APP_LAUNCH`). Il ne vérifie donc **pas** `Murmure/TranscriptControlServer.swift`, qui
# demande une session graphique : ce qui est vérifié ici est ce que le CLI fait du socket, et les
# deux côtés partagent le **même** `ControlProtocol` (dont les tables sont sous `swift test`).
#
# CE QU'IL N'EXÉCUTE PAS, ET POURQUOI (règle 11 : déclaré, jamais contourné).
#
#   1. Les trois contrôles du critère 12 **côté document** — langue forcée écrite dans le document,
#      invalidation d'une reprise par un `--language` explicite *différent*, reprise sans option qui
#      conserve la langue — demandent une transcription réelle : application lancée, modèle chargé,
#      ffmpeg embarqué. Ni ce script ni une gate ne les exécutent (AGENTS.md : aucun modèle, aucune
#      installation dans une gate) : ils sont rattachés à la gate humaine. Ce qui **est** prouvé ici
#      est la **transmission** de l'option — le champ `language` tel qu'il part sur le fil, validé
#      par le pair (6/7). Le reste de la chaîne est au lot 8 (document écrit sans option, relecture
#      de la langue à la reprise) et la décision d'invalidation vit chez le serveur
#      (`Murmure/TranscriptControlServer.swift`, `invaliderRepriseSiBesoin`).
#   2. « socket absent → le CLI démarre l'application puis réussit » (critère 20, §2.5) : ce script
#      **coupe** le lancement (`MURMURE_NO_APP_LAUNCH`) et vérifie le code 3 qui le précède, parce
#      qu'ouvrir `Murmure.app` depuis une gate est précisément ce qu'AGENTS.md interdit. Le
#      démarrage réel, l'insertion et la dictée appartiennent à la gate humaine.
#   3. Le diagnostic de l'application (critère 7) : la surface de diagnostic **du CLI** est le code
#      de sortie et la raison sur la sortie d'erreur, et c'est ce que 5/7 et 7/7 contrôlent (code 3
#      avec sa raison, troncature refusée, raison du serveur relayée telle quelle). `scripts/doctor.sh`,
#      le panneau Problèmes et le journal sont portés par les lots 4 et 6, hors de ce script.
#
# Usage : bash scripts/checks/cli-end-to-end.sh
set -u -o pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COEUR="$RACINE/MurmureCore"
BIN="${MURMURE_CLI:-$COEUR/.build/debug/murmure}"

failures=0
not_run=0
FAIL_LIST=""
SKIP_LIST=""
CHECK_TOTAL=8

ok() { printf '  [OK]          %s\n' "$1"; }
echec() {
    failures=$((failures + 1))
    FAIL_LIST="$FAIL_LIST    - $1\n"
    printf '  [ÉCHEC]       %s\n' "$1"
}
non_execute() {
    not_run=$((not_run + 1))
    SKIP_LIST="$SKIP_LIST    - $1\n"
    printf '  [NON EXÉCUTÉ] %s\n' "$1"
}

BAC="$(mktemp -d "${TMPDIR:-/tmp}/murmure-cli-e2e-XXXXXX")"
nettoyer() { [ -n "${BAC:-}" ] && [ -d "$BAC" ] && rm -rf "$BAC"; }
trap nettoyer EXIT

# Le lanceur : trois variables d'environnement, et rien d'autre.
#   - `MURMURE_TRANSCRIPTS_DIR` : la racine lue — jamais `Application Support` ;
#   - `MURMURE_CONTROL_SOCKET`  : le socket visé — jamais celui de l'application ;
#   - `MURMURE_NO_APP_LAUNCH`   : le lancement de l'application est désarmé. Sans lui, chaque
#     contrôle « application fermée » ouvrirait `Murmure.app` et attendrait 10 s.
SORTIE=""
ERREUR=""
CODE=0

cli() {
    local bac_err="$BAC/stderr.txt"
    SORTIE="$(env MURMURE_TRANSCRIPTS_DIR="$BIB" MURMURE_CONTROL_SOCKET="$SOCKET" \
        MURMURE_NO_APP_LAUNCH=1 "$BIN" "$@" 2>"$bac_err")"
    CODE=$?
    ERREUR="$(cat "$bac_err")"
}

# lancer <description> <code attendu> <argument...> : lance, imprime la commande et le code, et
# décide. Le code attendu est écrit noir sur blanc dans l'appel : aucun contrôle ne « constate » un
# code qu'il n'avait pas annoncé.
lancer() {
    local description="$1" attendu="$2"
    shift 2
    cli "$@"
    printf '    commande : « murmure %s »  -> code %s (attendu %s)\n' "$*" "$CODE" "$attendu"
    if [ "$CODE" -ne "$attendu" ]; then
        echec "$description : code $CODE au lieu de $attendu — sortie « $(
            printf '%s' "$SORTIE" | head -1
        ) » erreur « $(printf '%s' "$ERREUR" | head -1) »"
        return 1
    fi
    ok "$description"
    return 0
}

printf 'CLI contrôlé : %s\n' "$BIN"

# ---------------------------------------------------------------------------------------------
# 1/7 — le binaire se construit.
# ---------------------------------------------------------------------------------------------
printf '1/%s construction du binaire\n' "$CHECK_TOTAL"
BUILD_OUT="$(cd "$COEUR" && swift build --product murmure 2>&1)"
BUILD_RC=$?
if [ "$BUILD_RC" -ne 0 ]; then
    echec "« swift build --product murmure » sort en $BUILD_RC — $(
        printf '%s' "$BUILD_OUT" | grep -m1 -e 'error:' || printf 'aucune ligne error:'
    )"
elif [ ! -x "$BIN" ]; then
    echec "« swift build --product murmure » a réussi mais $BIN n'est pas un exécutable"
else
    ok "construit, exécutable ($(printf '%s' "$BUILD_OUT" | grep -c -e 'error:' | tr -d ' ') erreur(s) dans le journal de construction)"
fi

if [ ! -x "$BIN" ]; then
    for reste in 2 3 4 5 6 7 8; do
        non_execute "contrôle $reste/$CHECK_TOTAL : pas de binaire à lancer"
    done
    printf '\nROUGE — %s manque(s), %s contrôle(s) non exécuté(s) sur %s : le CLI ne se construit pas.\n' \
        "$failures" "$not_run" "$CHECK_TOTAL"
    printf '  manques :\n%s' "$FAIL_LIST"
    exit 1
fi

# ---------------------------------------------------------------------------------------------
# Le bac à sable : une bibliothèque qui dit la vérité sur le disque.
#
# Trois documents lisibles, un Markdown (qui n'est **pas** un document : l'énumération ne compte que
# les `.json`), un `.json` tronqué (à compter comme illisible, jamais comme absent), et un intrus :
# `work/0000.wav`, que le dossier de travail met là où un `ls` naïf le trouverait.
# ---------------------------------------------------------------------------------------------
BIB="$BAC/Transcripts"
SOCKET="$BAC/control.sock"
mkdir -p "$BIB/work"

TIGE_A="entrevue-2026-09-20-aaaaaaaa"
TIGE_B="agenda-2026-09-21-bbbbbbbb"
TIGE_CASSEE="casse-2026-09-21-cccccccc"

cat >"$BIB/$TIGE_A.json" <<'JSON'
{"schemaVersion":1,"id":"entrevue-2026-09-20-aaaaaaaa","title":"Entrevue","source":{"kind":"file","path":"/tmp/source.wav","identity":"aaaaaaaa"},"duration":90.0,"language":"fr","languageWasForced":false,"model":"large-v3","createdAt":"2026-09-20T10:00:00Z","completedAt":"2026-09-20T10:05:00Z","status":"complete","segments":[{"start":0.0,"end":4.0,"text":"Bonjour."}],"coverage":{"coveredSeconds":4.0,"ratio":0.044},"boundaries":[]}
JSON
cat >"$BIB/$TIGE_B.json" <<'JSON'
{"schemaVersion":1,"id":"agenda-2026-09-21-bbbbbbbb","title":"Agenda","source":{"kind":"youtube","url":"https://www.youtube.com/watch?v=bbbbbbbb","identity":"bbbbbbbb"},"duration":600.0,"language":"fr","languageWasForced":true,"model":"large-v3","createdAt":"2026-09-21T09:00:00Z","status":"inProgress","segments":[{"start":0.0,"end":30.0,"text":"Première unité."}],"coverage":{"coveredSeconds":30.0,"ratio":0.05},"boundaries":[{"start":0.0,"duration":30.0,"quality":"forced"}]}
JSON
cat >"$BIB/entrevue-2026-09-22-dddddddd.json" <<'JSON'
{"schemaVersion":1,"id":"entrevue-2026-09-22-dddddddd","title":"Entrevue, deuxième","source":{"kind":"file","path":"/tmp/source2.wav","identity":"dddddddd"},"duration":120.0,"language":"fr","languageWasForced":false,"model":"large-v3","createdAt":"2026-09-22T08:00:00Z","completedAt":"2026-09-22T08:10:00Z","status":"complete","segments":[{"start":0.0,"end":6.0,"text":"Deuxième."}],"coverage":{"coveredSeconds":6.0,"ratio":0.05},"boundaries":[]}
JSON
printf '# Entrevue\n\nBonjour.\n' >"$BIB/$TIGE_A.md"
printf '{"schemaVersion":1,"id":"casse-2026-09-21-cccccccc","title":"Tronqué"\n' >"$BIB/$TIGE_CASSEE.json"
printf 'audio' >"$BIB/work/0000.wav"
# ---------------------------------------------------------------------------------------------
# 2/7 — `version`, application fermée. Le socket n'existe pas encore : c'est le contrôle de la
# promesse « trois commandes marchent application fermée ».
# ---------------------------------------------------------------------------------------------
printf '2/%s version, application fermée\n' "$CHECK_TOTAL"
printf '    (aucun fichier à %s)\n' "$SOCKET"
if [ -e "$SOCKET" ]; then
    echec "le socket $SOCKET existe déjà : le contrôle « application fermée » ne prouverait rien"
    non_execute "version : préalable non tenu (un socket occupe le chemin)"
elif lancer "« version » répond 0 sans application" 0 version; then
    if [ -z "$SORTIE" ]; then
        echec "« version » n'écrit rien sur la sortie standard"
    else
        ok "« version » écrit « $(printf '%s' "$SORTIE" | head -1) »"
    fi
fi

# ---------------------------------------------------------------------------------------------
# 3/7 — `list` dit la vérité sur le disque : ce que la bibliothèque porte, et ce qu'elle ne porte
# pas. Le chemin absolu du JSON compte autant que les noms : c'est lui qui rend un transcript
# ouvrable par un agent.
# ---------------------------------------------------------------------------------------------
printf '3/%s list dit la vérité sur le disque\n' "$CHECK_TOTAL"
if lancer "« list » répond 0 sans application" 0 list; then
    for tige in "$TIGE_A" "$TIGE_B"; do
        if printf '%s' "$SORTIE" | grep -q -- "$tige"; then
            ok "la sortie nomme $tige"
        else
            echec "la sortie ne nomme pas $tige (un transcript lisible a disparu de l'énumération)"
        fi
    done
    if printf '%s' "$SORTIE" | grep -q -- "$BIB/$TIGE_A.json"; then
        ok "la sortie porte le chemin absolu du JSON ($BIB/$TIGE_A.json)"
    else
        echec "la sortie ne porte pas le chemin absolu du JSON : un agent ne peut pas ouvrir le fichier"
    fi
    if printf '%s' "$SORTIE" | grep -q 'unreadable: 1'; then
        ok "le JSON tronqué est compté (« unreadable: 1 ») et non passé sous silence"
    else
        echec "le JSON tronqué n'est pas compté : « unreadable: 1 » est absent de la sortie"
    fi
    if printf '%s' "$SORTIE" | grep -q -- '0000.wav'; then
        echec "la sortie parle de work/0000.wav : le dossier de travail n'est pas la bibliothèque"
    else
        ok "work/0000.wav est ignoré (le dossier de travail n'est pas la bibliothèque)"
    fi
fi
# ---------------------------------------------------------------------------------------------
# 4/7 — `read` : les façons de nommer un transcript, et les refus. Les refus comptent autant que
# les résolutions : un inconnu qui rendrait 0 ferait d'un agent un menteur, un préfixe ambigu qui
# choisirait tout seul ferait lire le mauvais transcript, et un chemin hors de la racine qui
# rendrait 0 ferait lire n'importe quoi du disque.
#
# **Deux refus, deux codes, et ce n'est pas un détail.** `ControlProtocol.exitCode(for:)` (gelé par
# `ControlProtocolTests.testCritere20_ReadDUnTranscriptSupprimeEchoueProprement`) distingue :
#   - introuvable → **1** : « la demande est bien formée, la chose demandée n'existe pas » — un
#     `read` d'un transcript supprimé n'est pas une faute d'usage ;
#   - ambigu ou hors de la racine → **2** : la requête ne désigne pas un transcript unique et légal.
# ---------------------------------------------------------------------------------------------
printf '4/%s read résout et refuse\n' "$CHECK_TOTAL"
if lancer "« read <id> » répond 0" 0 read "$TIGE_A"; then
    if printf '%s' "$SORTIE" | grep -q -- '"id"'; then
        ok "la sortie est le document (JSON lisible, clé « id » présente)"
    else
        echec "la sortie n'est pas le document JSON : « id » est absent"
    fi
fi
lancer "« read <tige>.json » répond 0 (nom de fichier)" 0 read "$TIGE_A.json"
lancer "« read <chemin absolu> » répond 0" 0 read "$BIB/$TIGE_A.json"
lancer "« read work/../<tige>.json » répond 0 (chemin interne normalisé)" 0 read "work/../$TIGE_A.json"
lancer "« read <préfixe unique> » répond 0" 0 read "agenda"
lancer "« read --format md <id> » répond 0" 0 read --format md "$TIGE_A"
if printf '%s' "$SORTIE" | grep -q '# Entrevue'; then
    ok "« --format md » imprime le Markdown du fichier"
else
    echec "« --format md » n'imprime pas le Markdown du fichier"
fi
lancer "« read <id absent> » rend 1 (travail en échec), pas 0 ni 2" 1 read "disparu-2026-09-22-dddddddd"
lancer "« read <json tronqué> » rend 1 : illisible n'est pas un document" 1 read "$TIGE_CASSEE"
lancer "« read <préfixe ambigu> » rend 2 : il ne devine pas lequel des deux" 2 read "entrevue"
lancer "« read ../hors.json » rend 2 (hors de la racine)" 2 read "../hors.json"
lancer "« read » sans opérande rend 2" 2 read
lancer "« read --format xml <id> » rend 2 (valeur hors des valeurs admises)" 2 read --format xml "$TIGE_A"
lancer "« read --bidule <id> » rend 2 (option inconnue)" 2 read --bidule "$TIGE_A"
lancer "« list <opérande> » rend 2 (opérande inattendu)" 2 list "$TIGE_A"
lancer "« glorbf » rend 2 (commande hors table)" 2 glorbf

# ---------------------------------------------------------------------------------------------
# 5/7 — `transcribe` et `status` sans application : le code 3, et rien d'autre. C'est la promesse
# que le plan nomme « app injoignable » : ni 0 (qui ferait croire au travail), ni 1 (qui accuserait
# la source), ni un silence.
# ---------------------------------------------------------------------------------------------
printf '5/%s transcribe et status sans application\n' "$CHECK_TOTAL"
printf '    (aucun socket à %s, lancement de l.application désarmé)\n' "$SOCKET"
if lancer "« status » rend 3 (application injoignable)" 3 status; then
    if [ -n "$ERREUR" ]; then
        ok "la raison est sur la sortie d'erreur : « $(printf '%s' "$ERREUR" | head -1) »"
    else
        echec "« status » rend 3 mais n'écrit aucune raison : l'échec est muet"
    fi
    if [ -z "$SORTIE" ]; then
        ok "la sortie standard reste vide (un code 3 ne livre rien)"
    else
        echec "« status » a écrit « $(printf '%s' "$SORTIE" | head -1) » malgré le code 3"
    fi
fi
lancer "« transcribe <fichier local> » rend 3" 3 transcribe "$BIB/$TIGE_A.md"
lancer "« transcribe --wait <fichier> » rend 3" 3 transcribe --wait "$BIB/$TIGE_A.md"
lancer "« transcribe <URL youtube> » rend 3 (l'application est seule à acquérir)" 3 \
    transcribe "https://www.youtube.com/watch?v=aaaaaaaa"
# ---------------------------------------------------------------------------------------------
# 6/7 — avec une doublure : le CLI parle au socket, et rapporte ce qu'il a reçu.
#
# La doublure **lit** la requête (elle la journalise et la valide : `version` et `command` d'un
# message réel), donc un « ça a marché » ne peut pas venir d'une réponse que le CLI se serait
# inventée. Elle n'a rien de l'application : ni file d'attente, ni modèle, ni fichier — c'est ce qui
# en fait un contrôle du **transport**.
# ---------------------------------------------------------------------------------------------
printf '6/%s avec une doublure de serveur\n' "$CHECK_TOTAL"
cat >"$BAC/doublure.py" <<'PYTHON'
#!/usr/bin/env python3
"""Doublure du serveur de contrôle : elle répond ce qu'on lui dit, et rien d'autre.

Usage : doublure.py <socket> <scénario>... (un scénario par connexion, dans l'ordre).
  ok          -> {"version":1,"exitCode":0,"text":"doublure : <commande>"}
  tronque     -> la même ligne privée de son dernier octet, puis fermeture (jamais de saut de ligne)
  illisible   -> « pas du JSON du tout » puis saut de ligne
  echec       -> {"version":1,"exitCode":1,"error":"la doublure dit que le travail a échoué"}
  injoignable -> {"version":1,"exitCode":3,"error":"Murmure is not running."} (ce que l'application
                 répond quand elle n'est pas là ; c'est une **réponse**, pas un socket muet)
  document    -> {"version":1,"exitCode":0,"document":<le JSON de DOUBLURE_DOCUMENT>} : un succès
                 qui porte un document, donc une copie de sortie à faire pour de vrai.
Chaque requête reçue est ajoutée au fichier désigné par DOUBLURE_JOURNAL.
"""
import json
import os
import socket
import sys

chemin, scenarios = sys.argv[1], sys.argv[2:]
journal = os.environ.get("DOUBLURE_JOURNAL")
if os.path.exists(chemin):
    os.unlink(chemin)
serveur = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
serveur.bind(chemin)
serveur.listen(4)
print("prête", flush=True)
for scenario in scenarios:
    connexion, _ = serveur.accept()
    with connexion:
        tampon = b""
        while not tampon.endswith(b"\n"):
            bloc = connexion.recv(4096)
            if not bloc:
                break
            tampon += bloc
        if not tampon:
            continue
        if journal:
            with open(journal, "a") as fichier:
                fichier.write(tampon.decode("utf-8"))
        requete = json.loads(tampon.decode("utf-8"))
        assert requete["version"] == 1, requete
        assert isinstance(requete["command"], str), requete
        if scenario == "ok":
            reponse = {"version": 1, "exitCode": 0, "text": "doublure : %s" % requete["command"]}
            connexion.sendall(json.dumps(reponse).encode() + b"\n")
        elif scenario == "tronque":
            ligne = json.dumps({"version": 1, "exitCode": 0, "text": "doublure tronquée"}).encode()
            connexion.sendall(ligne[:-1])
        elif scenario == "illisible":
            connexion.sendall(b"pas du JSON du tout\n")
        elif scenario == "echec":
            reponse = {
                "version": 1,
                "exitCode": 1,
                "error": "la doublure dit que le travail a échoué",
            }
            connexion.sendall(json.dumps(reponse).encode() + b"\n")
        elif scenario == "injoignable":
            reponse = {
                "version": 1,
                "exitCode": 3,
                "error": "Murmure is not running.",
            }
            connexion.sendall(json.dumps(reponse).encode() + b"\n")
        elif scenario == "document":
            with open(os.environ["DOUBLURE_DOCUMENT"], "r") as fichier:
                document = json.load(fichier)
            reponse = {"version": 1, "exitCode": 0, "document": document}
            connexion.sendall(json.dumps(reponse).encode() + b"\n")
        else:
            raise SystemExit("scénario inconnu : %s" % scenario)
serveur.close()
os.unlink(chemin)
PYTHON

# demarrer_doublure <scénario...> : pose la doublure et attend son socket.
# `DOUBLURE_DOCUMENT` désigne le document que le scénario « document » sert dans sa réponse : c'est
# le transcript lisible du bac (`$BIB/$TIGE_A.json`), donc un document réel du schéma — la copie de
# sortie du contrôle 8/8 porte sur de vrais fichiers.
DOUBLURE_PID=""
demarrer_doublure() {
    DOUBLURE_JOURNAL="$BAC/requetes.txt" DOUBLURE_DOCUMENT="$BIB/$TIGE_A.json" \
        python3 "$BAC/doublure.py" "$SOCKET" "$@" \
        >"$BAC/doublure.log" 2>&1 &
    DOUBLURE_PID=$!
    for _ in $(seq 1 100); do
        [ -e "$SOCKET" ] && return 0
        sleep 0.1
    done
    return 1
}

# arreter_doublure : la doublure s'arrête après son dernier scénario ; on la tue si elle attend
# encore (un contrôle en échec a pu ne pas se connecter).
arreter_doublure() {
    [ -n "$DOUBLURE_PID" ] || return 0
    for _ in $(seq 1 50); do
        kill -0 "$DOUBLURE_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill "$DOUBLURE_PID" 2>/dev/null
    wait "$DOUBLURE_PID" 2>/dev/null
    DOUBLURE_PID=""
}

trap 'arreter_doublure; nettoyer' EXIT
if ! demarrer_doublure ok ok ok ok; then
    echec "la doublure n'a pas posé son socket à $SOCKET"
    non_execute "6/$CHECK_TOTAL : pas de doublure"
else
    printf '    doublure prête (4 réponses : transcribe, status, transcribe --json, transcribe --language)\n'
    lancer "« transcribe <fichier> » rend 0 avec la doublure" 0 transcribe "$BIB/$TIGE_A.md"
    if printf '%s' "$SORTIE" | grep -q 'doublure : transcribe'; then
        ok "le CLI imprime la réponse du serveur, telle quelle"
    else
        echec "le CLI n'imprime pas la réponse du serveur : « $(printf '%s' "$SORTIE" | head -1) »"
    fi
    lancer "« status » rend 0 avec la doublure" 0 status
    lancer "« transcribe --json <fichier> » rend 0" 0 transcribe --json "$BIB/$TIGE_A.md"
    if printf '%s' "$SORTIE" | grep -q '"exitCode":0'; then
        ok "« --json » sort la réponse du protocole (« exitCode » présent)"
    else
        echec "« --json » ne sort pas la réponse du protocole : « $(printf '%s' "$SORTIE" | head -1) »"
    fi
    lancer "« transcribe --language xx <fichier> » rend 0" 0 transcribe --language xx "$BIB/$TIGE_A.md"
    if grep -q '"language":"xx"' "$BAC/requetes.txt" 2>/dev/null; then
        ok "la requête porte la langue explicite (« language » sur le fil, transmise telle quelle)"
    else
        echec "la langue explicite n'est pas sur le fil : l'option ne va pas plus loin que le CLI"
    fi
    if grep -q '"command":"transcribe"' "$BAC/requetes.txt" 2>/dev/null; then
        ok "le pair a reçu des requêtes « transcribe » sur le fil (journalisées par la doublure)"
    else
        echec "aucune requête « transcribe » reçue par la doublure : le CLI n'a rien envoyé"
    fi
    if grep -q '"source":"' "$BAC/requetes.txt" 2>/dev/null; then
        ok "la requête porte la source (« source » présent sur le fil)"
    else
        echec "la requête ne porte pas la source : la doublure n'a rien vu à transmettre à l'application"
    fi
    if grep -q '"command":"status"' "$BAC/requetes.txt" 2>/dev/null; then
        ok "« status » passe bien par le socket (et non par une réponse locale)"
    else
        echec "« status » n'est pas passé par le socket : la commande a été servie comme une locale"
    fi
    arreter_doublure
fi

# ---------------------------------------------------------------------------------------------
# 7/7 — la doublure **refuse**. C'est le contrôle qui empêche le contrôle précédent d'être une
# complaisance : si le CLI acceptait une ligne tronquée ou une ligne qui n'est pas du JSON, le vert
# du 6/7 ne vaudrait rien. Et si une réponse disant l'échec rendait 0, un agent croirait au travail.
# ---------------------------------------------------------------------------------------------
printf '7/%s la doublure refuse\n' "$CHECK_TOTAL"
if ! demarrer_doublure tronque illisible echec; then
    echec "la doublure n'a pas posé son socket à $SOCKET"
    non_execute "7/$CHECK_TOTAL : pas de doublure"
else
    if lancer "ligne tronquée (pas de saut de ligne) : rend 2, jamais 0" 2 transcribe "$BIB/$TIGE_A.md"; then
        if [ -n "$ERREUR" ]; then
            ok "la troncature est dite sur la sortie d'erreur : « $(printf '%s' "$ERREUR" | head -1) »"
        else
            echec "« tronquée » rend 2 sans rien dire : un refus muet n'est pas diagnosticable"
        fi
        if [ -z "$SORTIE" ]; then
            ok "rien n'est livré sur la sortie standard (aucun document inventé)"
        else
            echec "une ligne tronquée a produit « $(printf '%s' "$SORTIE" | head -1) » sur la sortie"
        fi
    fi
    lancer "ligne illisible (pas du JSON) : rend 2" 2 status
    if lancer "réponse qui dit l'échec : rend 1, jamais 0" 1 transcribe "$BIB/$TIGE_A.md"; then
        if printf '%s' "$ERREUR" | grep -q 'la doublure dit que le travail a échoué'; then
            ok "la raison du serveur est relayée telle quelle (le CLI ne la réécrit pas)"
        else
            echec "la raison du serveur n'est pas relayée : « $(printf '%s' "$ERREUR" | head -1) »"
        fi
    fi
    arreter_doublure
fi

# ---------------------------------------------------------------------------------------------
# 8/8 — `--output` ne réécrit jamais le code de la réponse (défaut F1 de la revue round 1).
#
# Deux cas que le CLI confondait : une réponse **non-succès** (1 travail en échec, 3 application
# injoignable) et un **succès sans document** (pas de `--wait`). Le premier doit sortir avec le code
# de la réponse et ne rien copier ; seul le second est un usage (2). Le contrôle exige donc aussi
# que la phrase « needs `--wait` » n'apparaisse pas dans le premier cas, et que le chemin nominal
# (succès **avec** document) copie réellement les deux fichiers du transcript.
# ---------------------------------------------------------------------------------------------
printf '8/%s --output ne change pas le code de la réponse\n' "$CHECK_TOTAL"
SORTIE_DIR="$BAC/sorties"
if ! demarrer_doublure injoignable echec injoignable ok document; then
    echec "la doublure n'a pas posé son socket à $SOCKET"
    non_execute "8/$CHECK_TOTAL : pas de doublure"
else
    printf '    doublure prête (5 réponses : 3, 1, 3, succès sans document, succès avec document)\n'
    if lancer "réponse 3 (application injoignable) + --output --wait : rend 3, jamais 2" 3 \
        transcribe --wait --output "$SORTIE_DIR" "$BIB/$TIGE_A.md"; then
        if printf '%s' "$ERREUR" | grep -q 'Murmure is not running.'; then
            ok "la raison de la réponse est relayée telle quelle"
        else
            echec "la raison relayée n'est pas celle de la réponse : « $(printf '%s' "$ERREUR" | head -1) »"
        fi
        if printf '%s' "$ERREUR" | grep -q 'needs `--wait`'; then
            echec "« --output needs --wait » est ajouté alors que --wait a été demandé : deux raisons contradictoires"
        else
            ok "aucune phrase « needs --wait » ajoutée (elle ne vaut que pour un succès sans document)"
        fi
    fi
    lancer "réponse 1 (travail en échec) + --output : rend 1, jamais 2" 1 \
        transcribe --wait --output "$SORTIE_DIR" "$BIB/$TIGE_A.md"
    lancer "réponse 3 + --output sur « status » : rend 3" 3 status --output "$SORTIE_DIR"
    if [ -e "$SORTIE_DIR" ]; then
        echec "une réponse refusée a copié quelque chose dans $SORTIE_DIR : rien ne se copie hors succès"
    else
        ok "aucune copie posée pour les réponses refusées ($SORTIE_DIR n'existe pas)"
    fi
    # Le seul cas où « --output exige un document » est vrai : succès sans document, donc sans `--wait`.
    if lancer "succès sans document (sans --wait) : rend 2, l'usage est dit" 2 \
        transcribe --output "$SORTIE_DIR" "$BIB/$TIGE_A.md"; then
        if printf '%s' "$ERREUR" | grep -q 'nothing to copy'; then
            ok "« --output » sans --wait dit pourquoi il refuse (« nothing to copy … needs --wait »)"
        else
            echec "« --output » sans --wait rend 2 sans dire pourquoi : « $(printf '%s' "$ERREUR" | head -1) »"
        fi
    fi
    # Et le chemin nominal : une réponse de succès **avec** document copie les deux fichiers.
    if lancer "succès avec document + --output : rend 0" 0 \
        transcribe --wait --output "$SORTIE_DIR" "$BIB/$TIGE_A.md"; then
        if [ -f "$SORTIE_DIR/$TIGE_A.json" ] && [ -f "$SORTIE_DIR/$TIGE_A.md" ]; then
            ok "les deux sorties du transcript sont copiées ($TIGE_A.json et $TIGE_A.md)"
        else
            echec "« --output » n'a pas copié les fichiers du transcript dans $SORTIE_DIR"
        fi
    fi
    arreter_doublure
fi

# ---------------------------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------------------------
printf '\n'
if [ "$failures" -eq 0 ] && [ "$not_run" -eq 0 ]; then
    printf 'VERT — %s/%s contrôles passent : « %s » se construit, sert `version`, `list` et `read`\n' \
        "$CHECK_TOTAL" "$CHECK_TOTAL" "$BIN"
    printf '        application fermée (énumération et chemins conformes au disque), rend 3 sur les\n'
    printf '        deux commandes qui ont besoin de l’application, et parle le protocole — refus,\n'
    printf '        troncature et échec compris. `--output` ne réécrit jamais le code de la réponse.\n'
    exit 0
fi

printf 'ROUGE — le CLI n’est pas certifiable : %s manque(s), %s contrôle(s) non exécuté(s) sur %s.\n' \
    "$failures" "$not_run" "$CHECK_TOTAL"
if [ "$failures" -gt 0 ]; then
    printf '  manques :\n%s' "$FAIL_LIST"
fi
if [ "$not_run" -gt 0 ]; then
    printf '  contrôles non exécutés :\n%s' "$SKIP_LIST"
fi
printf '\n  attendu : plan §2.5, §4 lot 11 — `swift build --product murmure`, `list`/`read`/`version`\n'
printf '            servis par le dossier seul, `transcribe`/`status` par le socket, codes 0/1/2/3,\n'
printf '            une ligne JSON par message et un refus pour tout ce qui n’en est pas une,\n'
printf '            `--output` compris (le code vient de la réponse, jamais d’un défaut).\n'
exit 1
