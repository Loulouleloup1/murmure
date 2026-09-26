#!/usr/bin/env bash
#
# CONTRAT QA — lot 1 du plan identite d'app (« Identité d'app — QA lot 1 », carte t_fe4799ab).
#
# CE QUE CE FICHIER EST, ET CE QU'IL N'EST PAS. C'est un CONTRAT, pas une implementation : il ne
# modifie aucun fichier, ne construit rien, ne lance aucune application et ne signe rien. Il lit
# `project.yml` et `scripts/checks/require-signed-bundle.sh`, il execute la garde sur deux bundles
# REELS deja presents sur cette machine, et il dit pour chaque critere si la regle tient ou pas.
#
# Il est ROUGE sur l'etat d'aujourd'hui. C'est voulu : c'est la preuve que les controles sont
# discriminants, pas la declaration d'un echec.
#
#   C1a  sous `targets.Murmure.settings`, PAS de `CODE_SIGN_IDENTITY: "-"`
#   C1b  sous `targets.Murmure.settings`, OUI `CODE_SIGN_STYLE: Automatic`
#        et `DEVELOPMENT_TEAM: U569JMM3TX`                        (les DEUX moities sont obligatoires)
#   C1c  sous `targets.murmure-cli.settings`, il y a TOUJOURS `CODE_SIGN_IDENTITY: "-"`
#   C2   `configs:` declare Debug (debug), Release (release) et Beta (release)
#   C3   identifiants resolus : Beta = com.louiscourcier.Murmure.beta,
#        Debug = Release = com.louiscourcier.Murmure
#   C4   la garde rend 1 sur le bundle ad-hoc et 0 sur le bundle signe a l'equipe
#   C5   la garde rend 1 sur le bundle SIGNE quand on lui demande l'identifiant de la beta
#   C6   la source de la garde n'accepte ni `--force` ni variable d'environnement qui la desarme
#   C7   `--verify --strict` n'est PAS le critere d'identite : il sort 0 sur l'ad-hoc (mesure ici),
#        donc la garde doit le refuser quand meme, et citer TeamIdentifier
#   C8   la garde n'ecrit rien (avant/apres sur les deux bundles) et refuse `--force`
#
# USAGE
#   scripts/checks/identity-contract.sh [--project CHEMIN] [--guard CHEMIN]
#
# Les deux options servent a rejouer le contrat sur une COPIE (mutants, base verte). Elles ne
# desactivent aucun controle : elles ne changent que le fichier lu. Sans option, le contrat lit
# l'arbre qui le contient.
#
# Codes de sortie : 0 = tous les controles verts ; 1 = au moins un controle rouge ; 2 = le contrat
# n'a pas pu s'executer (fichier absent, outil manquant). distinct de 1, comme pour la garde.

set -uo pipefail

# --- Les deux bundles reels. Chemins absolus, cites tels quels par la carte et par le plan, parce
# --- qu'un controle d'identite sur un bundle fabrique ne controle rien (risque 7 du plan).
ADHOC_BUNDLE="/Users/louiscourcier/Projects/murmure/.worktrees/t_aeb3aea0/.assemblage-11s/.build/dd/Build/Products/Release/Murmure.app"
SIGNED_BUNDLE="/Users/louiscourcier/Projects/murmure/.worktrees/t_d1dbdc77/.build/xcode-dev/rev13/Build/Products/Release/Murmure.app"
STABLE_ID="com.louiscourcier.Murmure"
BETA_ID="com.louiscourcier.Murmure.beta"
TEAM="U569JMM3TX"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
PROJECT="${DEFAULT_ROOT}/project.yml"
GUARD="${DEFAULT_ROOT}/scripts/checks/require-signed-bundle.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --guard)   GUARD="${2:-}";   shift 2 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "identity-contract: usage inconnu « $1 » (--project | --guard)" >&2
      exit 2
      ;;
  esac
done

RED=0
CANNOT_RUN=0

# Couleur seulement si un terminal ET pas NO_COLOR : un log de CI n'a pas de terminal, et la
# couleur rendrait les controles illisibles a `grep` — c'est ce qui a fait echouer un premier
# rejeu automatise, en annonçant a tort des controles verts.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SKIP=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_KO=''; C_SKIP=''; C_OFF=''
fi

ok()   { printf '  %svert%s  %-4s %s\n'  "${C_OK}" "${C_OFF}" "$1" "$2"; }
ko()   { printf '  %sROUGE%s %-4s %s\n'  "${C_KO}" "${C_OFF}" "$1" "$2"; RED=1; }
skip() { printf '  %sabsent%s %-4s %s\n' "${C_SKIP}" "${C_OFF}" "$1" "$2"; CANNOT_RUN=1; }

# --- Analyse YAML par indentation. On n'a pas besoin d'un parseur complet : il faut savoir, pour
# --- un chemin de cles (`targets,Murmure,settings`), quelles lignes sont dessous, y compris les
# --- sous-blocs arbitrairement profonds. Pas de dependance, pas de `yq` suppose present.
yaml_block() {
  awk -v TARGET="$1" '
    BEGIN { n = split(TARGET, T, ","); m = (n == 0) }
    {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
        if (m && n > 0) print
        next
      }
      match($0, /^[[:space:]]*/)
      ind = RLENGTH
      text = substr($0, ind + 1)
      if (text !~ /^[A-Za-z0-9_.-]+:/) next
      key = text
      sub(/:.*$/, "", key)
      while (nstack > 0 && IND[nstack] >= ind) nstack--
      nstack++
      IND[nstack] = ind
      KEY[nstack] = key
      depth = nstack
      if (depth < n) { m = 0; next }
      if (depth == n) {
        m = 1
        for (i = 1; i <= n; i++) if (KEY[i] != T[i]) m = 0
        if (m) print
        next
      }
      if (m) print
    }
  ' "$2"
}

# Valeur d'un `CLE: valeur` directement sous le bloc demande (premiere occurrence).
setting_in() { # setting_in <chemin-yaml> <cle> [fichier]
  local path="$1" key="$2" file="${3:-$PROJECT}"
  # Chemin vide = racine du fichier : seules les cles de la colonne 0 comptent, sinon `name:` de
  # la phase post-build (`- name: Copy the murmure CLI ...`) passerait pour le nom de l'app.
  local anchor='[[:space:]]*'
  [ -n "${path}" ] || anchor=''
  yaml_block "$path" "$file" \
    | sed -n "s/^${anchor}${key}:[[:space:]]*\(.*\)\$/\1/p" \
    | sed 's/[[:space:]]*#.*$//' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/' \
    | head -n 1
}

have() { [ -n "$1" ]; }

echo "== Contrat identite d'app — lot 1 (t_fe4799ab)"
echo "   project.yml : ${PROJECT}"
echo "   garde       : ${GUARD}"
echo

# ================================================================================ C1
echo "-- C1  la regle de signature dans project.yml"

if [ ! -f "${PROJECT}" ] || [ ! -r "${PROJECT}" ]; then
  skip C1a "project.yml illisible : ${PROJECT}"
  skip C1b "project.yml illisible : ${PROJECT}"
  skip C1c "project.yml illisible : ${PROJECT}"
else
  MURMURE_SETTINGS="$(yaml_block targets,Murmure,settings "${PROJECT}")"
  CLI_SETTINGS="$(yaml_block targets,murmure-cli,settings "${PROJECT}")"

  # Moitie 1 — pas de signature ad-hoc forcee sur l'application.
  if printf '%s\n' "${MURMURE_SETTINGS}" | grep -Eq '^[[:space:]]*CODE_SIGN_IDENTITY:[[:space:]]*"?-"?[[:space:]]*$'; then
    ko C1a 'targets.Murmure.settings porte encore CODE_SIGN_IDENTITY: "-"'
  else
    ok C1a 'targets.Murmure.settings ne porte plus CODE_SIGN_IDENTITY: "-"'
  fi

  # Moitie 2 — une equipe declaree. C'est CELLE-LA qui compte : mesure au plan §1.7 (V1) que le
  # seul retrait de la ligne '-' laisse xcodebuild produire un ad-hoc, en silence, meme code de
  # sortie. Un contrat que le mutant (d) satisfait sans rien changer ne controle rien.
  style="$(setting_in targets,Murmure,settings CODE_SIGN_STYLE)"
  team="$(setting_in targets,Murmure,settings DEVELOPMENT_TEAM)"
  missing=""
  [ "${style}" = "Automatic" ] || missing="${missing} CODE_SIGN_STYLE:Automatic(lu: «${style}»)"
  [ "${team}" = "${TEAM}" ]     || missing="${missing} DEVELOPMENT_TEAM:${TEAM}(lu: «${team}»)"
  if [ -n "${missing}" ]; then
    ko C1b "targets.Murmure.settings ne declare pas une equipe :${missing}"
  else
    ok C1b "CODE_SIGN_STYLE: Automatic + DEVELOPMENT_TEAM: ${TEAM}"
  fi

  # Le mutant negatif du « fichier entier » : si ce controle passait en « project.yml entier »,
  # il serait rouge ici, et c'est le seul endroit ou les deux moities se distinguent.
  if printf '%s\n' "${CLI_SETTINGS}" | grep -Eq '^[[:space:]]*CODE_SIGN_IDENTITY:[[:space:]]*"?-"?[[:space:]]*$'; then
    ok C1c 'targets.murmure-cli.settings garde CODE_SIGN_IDENTITY: "-"'
  else
    ko C1c 'targets.murmure-cli.settings a perdu son CODE_SIGN_IDENTITY: "-" (le CLI doit rester ad-hoc)'
  fi
fi
echo

# ================================================================================ C2
echo "-- C2  la configuration Beta existe et est de type release"

if [ ! -f "${PROJECT}" ] || [ ! -r "${PROJECT}" ]; then
  skip C2 "project.yml illisible : ${PROJECT}"
else
  # `[[:space:]]*` (et non `\+`) : le `sed` de BSD ne connait pas `\+` en BRE. Un motif qui ne
  # rattrape rien ne « detecte » rien — il fait rougir le controle sur une base correcte, ce qui
  # est pire que de ne rien controler : on croyait avoir mesure.
  declared="$(yaml_block configs "${PROJECT}" | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.-]*\):[[:space:]]*$/\1/p' | tr -d ' ')"
  bad=""
  for cfg in Debug Release Beta; do
    printf '%s\n' "${declared}" | grep -qx "${cfg}" || bad="${bad} ${cfg}:absente"
  done
  for pair in "Debug:debug" "Release:release" "Beta:release"; do
    cfg="${pair%%:*}"; want="${pair##*:}"
    got="$(setting_in "configs,${cfg}" type)"
    [ "${got}" = "${want}" ] || bad="${bad} ${cfg}:type=«${got}»(voulu ${want})"
  done
  if [ -n "${bad}" ]; then
    ko C2 "configs: incomplet ou faux ->${bad}"
  else
    ok C2 "configs: Debug(debug), Release(release), Beta(release)"
  fi
fi
echo

# ================================================================================ C3
echo "-- C3  les identifiants de bundle, par configuration"

if [ ! -f "${PROJECT}" ] || [ ! -r "${PROJECT}" ]; then
  skip C3 "project.yml illisible : ${PROJECT}"
else
  # Resolution de la valeur REELLEMENT effective pour une configuration : par-configuration, sinon
  # `settings.base`, sinon `options.bundleIdPrefix` + `name`. On resout au lieu de relire, parce
  # qu'un « il n'y a pas de surcharge, donc c'est bon » ne controle rien.
  prefix="$(setting_in options bundleIdPrefix)"
  appname="$(setting_in '' name)"
  [ -n "${appname}" ] || appname="Murmure"
  fallback="${prefix}.${appname}"
  [ -n "${prefix}" ] || fallback=""

  resolve_id() { # resolve_id <config>
    local v
    v="$(setting_in "targets,Murmure,settings,configs,$1" PRODUCT_BUNDLE_IDENTIFIER)"
    [ -n "${v}" ] || v="$(setting_in targets,Murmure,settings,base PRODUCT_BUNDLE_IDENTIFIER)"
    [ -n "${v}" ] || v="${fallback}"
    printf '%s' "${v}"
  }

  beta_id="$(resolve_id Beta)"
  debug_id="$(resolve_id Debug)"
  release_id="$(resolve_id Release)"

  if [ "${beta_id}" = "${BETA_ID}" ]; then
    ok C3a "Beta resolue a ${beta_id}"
  else
    ko C3a "Beta resolue a « ${beta_id} », attendu ${BETA_ID}"
  fi

  bad=""
  [ "${debug_id}" = "${STABLE_ID}" ]   || bad="${bad} Debug=«${debug_id}»"
  [ "${release_id}" = "${STABLE_ID}" ] || bad="${bad} Release=«${release_id}»"
  if [ -n "${bad}" ]; then
    ko C3b "la stable a bouge ->${bad} (attendu ${STABLE_ID})"
  else
    ok C3b "Debug et Release resolues a ${STABLE_ID}"
  fi
fi
echo

# ================================================================================ C4 / C5
echo "-- C4/C5  la garde require-signed-bundle.sh sur deux bundles reels"

# La garde est lancee sous `perl`-free timeout via un sous-shell : macOS n'a pas `timeout(1)` dans
# le PATH de base, et une garde qui boucle ne doit pas pouvoir faire penduler le contrat — un
# contrat qui ne finit pas ne controle rien, il décale.
GUARD_TIMEOUT=100   # en pas de 0.2 s, donc 20 s reelles
guard_rc() { # guard_rc <args...>
  ( bash "${GUARD}" "$@" >/dev/null 2>&1 ) &
  local pid=$!
  local waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${GUARD_TIMEOUT}" ]; then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      printf '124'
      return 0
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "${pid}" 2>/dev/null
  printf '%s' "$?"
}

if [ ! -f "${GUARD}" ]; then
  skip C4 "la garde n'existe pas encore : ${GUARD}"
  skip C5 "la garde n'existe pas encore : ${GUARD}"
  skip C6 "la garde n'existe pas encore : ${GUARD}"
  skip C7 "la garde n'existe pas encore : ${GUARD}"
  skip C8 "la garde n'existe pas encore : ${GUARD}"
  echo
  echo "== VERDICT : ROUGE — la regle et la garde ne sont pas ecrites."
  exit 1
fi

for b in "${ADHOC_BUNDLE}" "${SIGNED_BUNDLE}"; do
  if [ ! -d "${b}" ]; then
    skip C4 "bundle attendu absent : ${b}"
    skip C5 "bundle attendu absent : ${b}"
    skip C7 "bundle attendu absent : ${b}"
    skip C8 "bundle attendu absent : ${b}"
    missing_bundle=1
  fi
done
if [ "${missing_bundle:-0}" = "1" ]; then
  echo
  echo "== VERDICT : ROUGE — un bundle reel attendu est absent, la discrimination n'est pas jouable."
  exit 2
fi

# Temoin mesure, dans le MEME controle : que vaut vraiment `codesign --verify --strict` sur le
# bundle ad-hoc ? Si reponse 0, alors verifier n'apporte rien sur l'identite et le seul critere
# possible est TeamIdentifier. Ce temoin rend C7 falsifiable au lieu d'etre une mise en garde.
verify_adhoc_rc=0
codesign --verify --strict "${ADHOC_BUNDLE}" >/dev/null 2>&1 || verify_adhoc_rc=$?
echo "   (temoin mesure) codesign --verify --strict sur l'ad-hoc  -> rc=${verify_adhoc_rc}"

rc_adhoc="$(guard_rc "${ADHOC_BUNDLE}")"
if [ "${rc_adhoc}" = "1" ]; then
  ok C4a "la garde refuse le bundle ad-hoc (rc=1)"
else
  ko C4a "la garde a rendu ${rc_adhoc} sur le bundle ad-hoc, attendu 1"
fi

rc_signed="$(guard_rc "${SIGNED_BUNDLE}")"
if [ "${rc_signed}" = "0" ]; then
  ok C4b "la garde accepte le bundle signe ${TEAM} (rc=0)"
else
  ko C4b "la garde a rendu ${rc_signed} sur le bundle signe a l'equipe, attendu 0"
fi

rc_expect="$(guard_rc "${SIGNED_BUNDLE}" --expect-id "${BETA_ID}")"
if [ "${rc_expect}" = "1" ]; then
  ok C5 "la garde dit « signe mais pas le bon » sur le bundle signe (rc=1)"
else
  ko C5 "la garde a rendu ${rc_expect} en face de --expect-id ${BETA_ID}, attendu 1"
fi
echo

# ================================================================================ C6
echo "-- C6  la source de la garde ne se laisse pas desarmer"

guard_src="$(cat "${GUARD}")"
bad=""

# (1) Variable d'environnement de desarme : la grep suffit, un nom comme ALLOW_ADHOC ne peut pas
#     apparaitre innocemment. On exige la forme « expansion », sinon un commentaire qui *parle* de
#     desarmement ne ferait pas rougir — et ici on veut l'inverse du grep naive sur `--force`.
printf '%s\n' "${guard_src}" | grep -Eq '\$\{?[A-Za-z_][A-Za-z0-9_]*(ALLOW|SKIP|IGNORE|DISABLE|BYPASS|OVERRIDE)[A-Za-z0-9_]*' \
  && bad="${bad} variable-desarme"

# (2) `--force` : une grep sur la seule chaine est IMPOSSIBLE a ecrire correctement. Mesure : une
#     garde qui *refuse* `--force` doit inevitablement nommer `--force` (pour le reconnaitre et
#     rendre 2) ; une grep « contient --force » rougit donc sur la garde correcte. Ce qu'il faut
#     verifier, c'est le CORPS de la branche : s'il sort avec un code non nul, l'option est
#     refusee ; s'il ne fait que poser une variable, l'option est acceptee.
force_branch="$(printf '%s\n' "${guard_src}" | awk '
    /--force\)/ { grab = 1 }
    grab { print }
    grab && /;;/ { grab = 0 }
  ')"
if [ -z "${force_branch}" ]; then
  # Aucune branche --force du tout : l'option n'existe pas, donc pas de `--force` a desactiver.
  :
elif printf '%s\n' "${force_branch}" | grep -Eq 'exit[[:space:]]+[1-9]'; then
  : # la branche sort avec un code non nul -> --force est refuse
else
  bad="${bad} --force-accepte"
fi

if [ -n "${bad}" ]; then
  ko C6 "la garde se laisse desactiver :${bad}"
else
  ok C6 "ni variable de desarme, ni --force accepte (branche --force : $(printf '%s' "${force_branch}" | tr '\n' ' ' | tr -s ' ' | cut -c1-60))"
fi
echo

# ================================================================================ C7
echo "-- C7  le critere d'identite est TeamIdentifier, pas --verify"

bad=""
# Citer ne suffit pas : une garde peut ne nommer `TeamIdentifier` que dans un commentaire tout en
# ne decidant que sur `--verify`. On exige donc la FORMLE de l'extraction — le nom est lu dans la
# sortie de `codesign` puis compare. C'est mesuré : le mutant « verify-seulement » (TeamIdentifier
# remplace par une chaine vide) cite encore le mot dans son message d'erreur et ne passe que si
# l'on se contente de la citation.
printf '%s\n' "${guard_src}" | grep -Eq 'TeamIdentifier=' \
  || bad="${bad} TeamIdentifier-non-extrait"
printf '%s\n' "${guard_src}" | grep -Eq '(not set)' \
  || bad="${bad} TeamIdentifier-absent-non-traite"
if [ "${verify_adhoc_rc}" = "0" ] && [ "${rc_adhoc}" = "1" ]; then
  :
else
  bad="${bad} ad-hoc-non-refuse-malgre-verify-rc-${verify_adhoc_rc}"
fi
if [ -n "${bad}" ]; then
  ko C7 "le critere d'identite n'est pas etabli ->${bad}"
else
  ok C7 "TeamIdentifier est le critere : verify --strict rc=${verify_adhoc_rc} sur l'ad-hoc, refus porte quand meme"
fi
echo

# ================================================================================ C8
echo "-- C8  la garde n'ecrit rien et refuse --force"

manifest() { find "$1" -type f -exec stat -f '%N %z %m %Lp' {} + 2>/dev/null | LC_ALL=C sort; }
before_adhoc="$(manifest "${ADHOC_BUNDLE}")"
before_signed="$(manifest "${SIGNED_BUNDLE}")"
guard_rc "${ADHOC_BUNDLE}" >/dev/null 2>&1
guard_rc "${SIGNED_BUNDLE}" --expect-id "${BETA_ID}" >/dev/null 2>&1
after_adhoc="$(manifest "${ADHOC_BUNDLE}")"
after_signed="$(manifest "${SIGNED_BUNDLE}")"

bad=""
[ "${before_adhoc}"  = "${after_adhoc}" ]  || bad="${bad} ad-hoc-modifie"
[ "${before_signed}" = "${after_signed}" ] || bad="${bad} signe-modifie"
rc_force="$(guard_rc "${ADHOC_BUNDLE}" --force)"
if [ "${rc_force}" = "0" ]; then
  bad="${bad} --force-accepte-sur-ad-hoc"
fi
if [ -n "${bad}" ]; then
  ko C8 "la garde n'est pas inerte ->${bad}"
else
  ok C8 "bundles inchanges apres execution ; --force refuse (rc=${rc_force})"
fi
echo

# ================================================================================ verdict
if [ "${CANNOT_RUN}" = "1" ]; then
  echo "== VERDICT : ROUGE — au moins un controle n'a pas pu s'executer."
  exit 2
fi
if [ "${RED}" = "1" ]; then
  echo "== VERDICT : ROUGE — la regle d'identite ne tient pas encore."
  exit 1
fi
echo "== VERDICT : VERT"
exit 0
