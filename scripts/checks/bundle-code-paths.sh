#!/usr/bin/env bash
#
# scripts/checks/bundle-code-paths.sh — garde de construction (plan §2.5, révision 13).
#
# POURQUOI CE CONTRÔLE EXISTE. Le bundle d'une application macOS range ses fichiers à des
# emplacements dont le nom est **déclaré** par la construction : `Contents/MacOS/` pour l'exécutable
# de l'application, `Contents/Helpers/` pour les outils auxiliaires, `Contents/Resources/` pour les
# ressources. Sur tout Mac le volume est **insensible à la casse** (APFS par défaut) : deux chemins
# déclarés qui ne diffèrent que par la casse désignent **un seul et même fichier**, et la phase qui
# en écrit un **écrase** l'autre sans que la construction le dise. C'est le défaut mesuré du lot 11 :
# le CLI copié en `Contents/MacOS/murmure` recouvrait l'exécutable de l'application
# (`Contents/MacOS/Murmure`), et `xcodebuild` rendait `** BUILD SUCCEEDED **` sur un bundle qui
# lançait le CLI — une bêta corrompue en silence.
#
# CE QUE CE SCRIPT CONTRÔLE : il reçoit les chemins **déclarés** du bundle (absolus, ou relatifs à
# une même racine) et échoue si deux d'entre eux sont égaux **casse ignorée**. La comparaison est en
# POSIX (`tr`), jamais `${var,,}` : le shell des phases de construction d'Xcode est bash 3.2.
#
# CE QU'IL NE FAIT PAS, ET C'EST DÉLIBÉRÉ : il ne lit pas le disque. Sur un volume **sensible** à la
# casse, écrire à deux chemins qui ne diffèrent que par la casse ne détruit rien — c'est ainsi que
# le défaut a traversé les constructions précédentes, et aucun contrôle de fichier ne l'aurait vu.
# Appelé par la phase post-build de `project.yml`, il se rejoue aussi à la main sur un bundle
# construit, avec les chemins tels que la construction les déclare.
#
# Usage  : bundle-code-paths.sh <chemin> <chemin> [<chemin> ...]
# Sortie : 0 si aucun chemin ne recouvre un autre ; 1 sinon, les deux chemins fautifs étant nommés
#          sur la sortie d'erreur ; 2 si l'appel lui-même ne peut pas conclure (moins de deux
#          chemins à comparer : il n'y aurait alors rien à prouver).

set -eu

if [ "$#" -lt 2 ]; then
  echo "error: bundle-code-paths.sh compares two bundle paths or more, got $#" >&2
  exit 2
fi

# La casse est la seule dimension comparée : le chemin est mis en minuscules par un outil POSIX,
# sans toucher au reste (un chemin qui contient déjà des minuscules doit rester tel quel).
enMinuscules() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

rang=0
for chemin in "$@"; do
  rang=$((rang + 1))
  if [ -z "$chemin" ]; then
    echo "error: an empty bundle path was declared, nothing can be compared (§2.5)" >&2
    exit 2
  fi
  rang_autre=0
  for autre in "$@"; do
    rang_autre=$((rang_autre + 1))
    if [ "$rang_autre" -le "$rang" ]; then
      continue
    fi
    if [ "$(enMinuscules "$chemin")" = "$(enMinuscules "$autre")" ]; then
      echo "error: two declared bundle paths are the same file, case ignored:" >&2
      echo "error:   « $chemin »" >&2
      echo "error:   « $autre »" >&2
      echo "error: on a case-insensitive volume (every Mac by default) the second write overwrites the first" >&2
      exit 1
    fi
  done
done

exit 0
