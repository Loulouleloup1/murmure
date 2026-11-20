---
name: verify
description: Recette de vérification de Murmure à lancer avant tout commit de livraison et avant de dire « terminé » ; ne prouve que le cœur testable, jamais l'écran, le micro ni le collage.
---

# Vérifier Murmure

Une seule recette : les tests de `MurmureCore` (`swift test`). Les règles de fond (interdits, modèles, vie privée) sont dans `RESUME.md` §5 et §6 : ne pas les redoubler ici.

## Quand
Avant tout commit de livraison et avant d'écrire « terminé ». Si le changement touche seulement `Murmure/` (vues, câblage), la recette passe quand même, mais elle ne prouve presque rien de ce changement : voir « Ce qu'elle ne prouve pas ».

## Commande
Depuis la racine de la copie de travail (remplacer `<chantier>`) :

```
mkdir -p ~/StudioRun/preuves/murmure/<chantier>
cd MurmureCore
swift test > ~/StudioRun/preuves/murmure/<chantier>/verify-$(date +%Y%m%d-%H%M).log 2>&1; echo "code=$?"
grep -E "Executed [0-9]+ tests" ~/StudioRun/preuves/murmure/<chantier>/verify-*.log | tail -1
```

- Première fois dans une copie neuve : SwiftPM télécharge GRDB 7.11.1 depuis GitHub (dépendance du projet, déjà épinglée) ; c'est compris dans la durée à froid ci-dessous.
- Durée mesurée le 20/11/2026 : environ 46 s à froid (copie neuve, GRDB téléchargé), environ 4 s à chaud. Au-delà de 2 minutes, lancer en arrière-plan.

## Ce qui compte comme preuve
- `code=0`, ET la ligne `Executed 1392 tests, with 0 failures (0 unexpected)` (le nombre grandit quand on ajoute des tests ; zéro échec est le critère).
- Le journal complet est déposé dans `~/StudioRun/preuves/murmure/<chantier>/`, nom daté. Citer ce chemin dans le rapport de livraison.
- Un changement de comportement du cœur s'accompagne d'un test écrit d'abord, vu rouge, puis vu vert.

## Ce que la recette ne prouve PAS
Le dossier `Murmure/` n'a aucun test. Rien de ce qui se voit ou s'entend n'est vérifié : fenêtre, encoche, carte de chaleur, collage dans une autre application, micro, vraie transcription Whisper, nettoyage par Ollama, autorisation Accessibilité, raccourci clavier. L'application elle-même n'est même pas compilée par cette recette (`xcodebuild` n'en fait pas partie : il télécharge WhisperKit et produit un très gros build ; à ne faire qu'avec l'accord de Louis).

Une livraison qui touche ces points s'annonce : « vérifié par les tests du cœur, essai à l'écran non fait : à faire par Louis ». Joindre la liste courte de ce qu'il doit essayer, en mots simples (par exemple : maintenir le raccourci, parler, relâcher, voir si le texte arrive ; ouvrir la fenêtre et regarder l'écran concerné ; essayer Échap en cours de dictée).

## Interdits
Sans personne devant le Mac, ne jamais lancer Murmure (ni `open`, ni le binaire, ni `--prepare-model`), ne pas cliquer, ne pas utiliser le micro ni `NSPasteboard.general`, ne pas lancer `scripts/install.sh` (il quitte l'application de Louis), ne rien télécharger d'autre, ne pas démarrer Ollama. Les tests du cœur sont sûrs : ils n'utilisent qu'un presse-papiers privé, des dossiers temporaires et des fichiers audio fictifs.

## En cas d'échec
Lire le premier message `error:` du journal, corriger la cause. Ne jamais relancer jusqu'à ce que ça passe, ne jamais `--skip` pour faire passer. Un test qui échoue une fois sur deux est un défaut à signaler, pas à relancer. Après trois tours sans réussite, s'arrêter et remonter au chef de projet avec le journal.

## Ménage
Rien ne reste en marche (`swift test` sort seul). Le dossier de build `MurmureCore/.build/` pèse environ 730 Mo, est ignoré par git, et se jette avec la copie de travail.
