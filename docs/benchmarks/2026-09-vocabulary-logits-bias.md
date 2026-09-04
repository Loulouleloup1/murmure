# Un biais de logits répare ce que le prompt rate — et les deux mécanismes composent, ils n'entrent pas en concurrence

Date : 2026-09-04 · Corpus : la MÊME sélection de 109 dictées que la campagne prompt
(`jobs-arms2.local.meta.local.json`, 106 occurrences abîmées), jamais commitée · Résultats :
`benchmark/results-boost.local.jsonl`, jamais commité · Harnais : `benchmark/vocabprobe/`
(SwiftPM, filtre ajouté) + `benchmark/vocab_boost*.py`, commités · Modèle : `large-v3-turbo`,
`DecodingOptions(language: "fr")` identique à la campagne prompt · **872 décodages, 8 bras,
44 min 20 s.**

La question : WhisperKit expose un second mécanisme, `LogitsFiltering`, appliqué à chaque
token décodé sur tout l'historique, hors du budget de 111 tokens qui plafonne
`promptTokens` à 20 termes. Un biais construit sur ce mécanisme répare-t-il du vocabulaire
mal entendu, à quel coût, et permet-il ce que le prompt ne peut pas — une liste longue ?

**Réponse : le biais seul répare peu (45 sur 106 au mieux, pour un coût quasiment nul),
mais combiné au prompt il atteint 103 sur 106 — le meilleur résultat des deux campagnes.
Porté à trente termes il ne répare rien de plus (43, dans le bruit de 45) et rate la seule
occurrence mesurable au-delà des trois termes déjà connus. Le contrôle d'injection, une
fois une erreur de sélection corrigée, ne montre aucune fausse insertion à la force la plus
agressive testée.**

---

## 1. Le plancher se reproduit avant tout le reste

Le bras `baseline` de cette campagne n'a ni prompt ni filtre — c'est exactement le bras
`baseline` de la campagne prompt, rejoué dans le harnais modifié. S'il ne reproduit pas les
106 occurrences abîmées établies dans `2026-09-vocabulary-prompt.md`, rien de ce qui suit
n'est interprétable.

| | Claude Code | WeeFin | Trucost | Superwhisper | total |
|---|---:|---:|---:|---:|---:|
| campagne prompt (référence) | 60 | 10 | 35 | 1 | 106 |
| cette campagne, bras `baseline` | 60 | 10 | 35 | 1 | 106 |

**Reproduction exacte, terme par terme.** Le bras `prompt` de cette campagne rejoue aussi
`n03sf` (` Murmure, Claude Code, Trucost, WeeFin.`, importé octet pour octet de
`vocab_order.py`, pas retapé) et retombe sur 92/106 (58 + 24 + 10), le chiffre exact de la
campagne précédente pour ce bras. Le harnais modifié — filtre en plus, mais chemin du
prompt inchangé — mesure donc la même chose qu'avant.

## 2. La table complète

`CC`/`WF`/`TC`/`SW` = réparations par terme (`mangled` au baseline → orthographe correcte
dans le bras). `mots` = variation du nombre de mots par rapport au baseline (161,4
mots/fichier). `sim` = similarité au baseline, texte entier. `régr` = régressions (terme
correct au baseline, cassé par le bras). `decodeS`/`filterS` = médianes, secondes.

| bras | CC | WF | TC | SW | total /106 | mots | sim | régr | decodeS | filterS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `baseline` | 0 | 0 | 0 | 0 | 0 | 0,0 % | 1,000 | 0 | 1,951 | 0,0095 |
| `prompt` (= `n03sf`) | 58 | 10 | 24 | 0 | **92** | −2,1 % | 0,980 | 0 | 2,150 | 0,0001 |
| `boost02` (cont=2) | 2 | 0 | 0 | 0 | 2 | 0,0 % | 1,000 | 0 | 1,947 | 0,0100 |
| `boost05` (cont=5) | 8 | 2 | 1 | 0 | 11 | +0,1 % | 1,000 | 0 | 1,937 | 0,0097 |
| `boost10` (cont=10) | 31 | 9 | 5 | 0 | 45 | +0,2 % | 1,000 | 0 | 1,937 | 0,0098 |
| **`promptboost10`** | **60** | 10 | **33** | 0 | **103** | −1,7 % | 0,981 | 0 | 2,137 | 0,0013 |
| `boost30x10` (30 termes) | 29 | 9 | 5 | 0 | 43 | −0,6 % | 0,994 | 0 | 2,004 | 0,0117 |
| `boostabsent10` (contrôle) | 0 | 0 | 0 | 0 | 0 | 0,0 % | 1,000 | 0 | 1,937 | 0,0103 |

Trois termes mesurés seulement (`Claude Code` 60, `Trucost` 35, `WeeFin` 10) portent
l'essentiel de la table, exactement comme dans la campagne prompt — voir §5.

**Ladder de force, presque gratuit.** `boost02` → `boost05` → `boost10` monte de 2 à 45
réparations à mesure que la force augmente, pour un coût en mots qui reste à 0,0–0,2 % —
sans commune mesure avec le coût du prompt (−2,1 %). Le biais n'occupe aucun token de
`promptTokens`, donc rien ici ne se paie en troncature ni en conditionnement du modèle sur
une liste de mots.

## 3. Le biais seul plafonne loin sous le prompt, mais les deux composent

À force égale, `boost10` seul (45/106) reste loin derrière `prompt` seul (92/106) — le
prompt reste le mécanisme le plus puissant des deux, pris isolément. La question qui
compte est ce qui se passe quand on les superpose.

`promptboost10` atteint 103/106, strictement supérieur aux deux pris séparément. Ce n'est
pas juste "le meilleur des deux mécanismes" — la décomposition paire par paire le montre :

| | nombre de paires (fichier, terme) |
|---|---:|
| réparées par le prompt ET le biais, chacun seul | 43 |
| réparées par le prompt seul, pas le biais | 49 |
| réparées par le biais seul, pas le prompt | 2 |
| réparées par NI L'UN NI L'AUTRE seul | 12 |
| … dont réparées par la COMBINAISON | 9 |
| … dont toujours pas réparées, même combinées | 3 |

**9 des 12 paires qu'aucun des deux mécanismes ne répare seul se réparent quand on les
combine.** `Trucost` en particulier passe de 24/35 (prompt seul) à 33/35 (combiné) — un
gain que ni le prompt ni le biais, chacun isolé, n'atteint. Les deux mécanismes composent,
ils n'interfèrent pas : aucune régression n'apparaît dans aucun bras de toute cette
campagne (colonne `régr`, zéro partout).

**103/106 est le meilleur résultat des deux campagnes.** Le précédent record était `n03sf`
à 92/106 (`2026-09-vocabulary-prompt.md` §5 bis).

## 4. La question de Louis : trente termes, verdict honnête

`boost30x10` porte les mêmes force et paramètres que `boost10`, mais sur les 30 termes de
`vocab_dose.ORDER[:30]` — la même liste que l'ancien bras `n30`/`n30r` — au lieu des 3
mesurables. Le biais n'a pas de budget à respecter, donc rien ne devrait a priori
l'empêcher de porter 30 termes sans pénalité de troncature.

**Résultat : 43/106, contre 45/106 à 3 termes.** Un écart de 2 sur 106 paires est dans le
bruit déjà mesuré par la campagne prompt (§2 : 2 bascules de verdict sur 112 paires
identiques). **Ajouter 27 termes de plus ne répare rien de plus.**

Le seul test direct de cette question sur ce corpus est le terme `Superwhisper`, mesuré
une seule fois (1 occurrence abîmée) et absent des 3 termes du bras `prompt`/`boost10` mais
présent dans les 30 de `boost30x10` :

| bras | verdict sur l'occurrence `Superwhisper` |
|---|---|
| `baseline` | mangled |
| `boost02` / `boost05` / `boost10` | mangled (inchangé, terme non présent dans le filtre) |
| `boost30x10` (terme présent dans le filtre) | **mangled, inchangé** |
| `prompt` / `promptboost10` | absent (change de forme, mais jamais la bonne orthographe) |

**0 réparation sur 1 possible, alors que `Superwhisper` fait partie des 30 termes boostés.**
C'est peu — une seule occurrence dans tout le corpus — mais c'est le seul chiffre que ce
corpus permette de produire sur "un terme ajouté au-delà des trois déjà connus profite-t-il
du mécanisme", et la réponse mesurée est non.

**Le coût, lui, bouge dans le mauvais sens.** `boost30x10` coûte −0,6 % de mots et une
similarité de 0,994 (contre 1,000 à 3 termes) : porter 30 termes au lieu de 3 n'est plus
strictement gratuit, pour zéro réparation supplémentaire mesurée.

**Verdict sur les 30 termes : non établi comme un gain, et le seul test direct disponible
est négatif.** Le mécanisme lève bien la contrainte structurelle du prompt (aucune
troncature, aucun ordre à respecter), mais rien ici ne montre qu'une liste plus longue
répare davantage — ce que la campagne prompt avait déjà établi pour `promptTokens`
(§1 : "la taille de la liste n'est pas le levier") reste vrai pour ce second mécanisme.

## 5. Le contrôle qui compte le plus — et une erreur corrigée en cours de route

`boostabsent10` porte 5 termes inventés (`Meridian`, `Obsidian`, `Fenwick`, `Calyx`,
`Vertex`), choisis pour ne jamais apparaître dans ce corpus, à la force la plus agressive
testée. Le risque mesuré : le biais met-il dans la transcription un mot que Louis n'a
jamais prononcé.

**Premier passage, faux positif.** Une recherche brute du mot dans la sortie du bras donne
4 occurrences de `Obsidian`, sur 109 fichiers — un chiffre qui, lu tel quel, aurait dit "le
mécanisme injecte". **C'est faux : les 4 occurrences existent DÉJÀ dans le baseline, sans
aucun filtre.** `Obsidian` est une application de prise de notes réelle, et Louis en parle
apparemment dans son corpus — mauvais choix de terme "absent" de ma part, découvert
seulement en vérifiant chaque occurrence contre le baseline correspondant plutôt que de
prendre le compte brut pour argent comptant.

| | occurrences brutes | injections réelles (absentes du baseline du même fichier) |
|---|---:|---:|
| `Meridian` / `Fenwick` / `Calyx` / `Vertex` | 0 | 0 |
| `Obsidian` | 4 | **0** (déjà présent au baseline dans les 4 cas) |
| **total** | 4 | **0** |

**Une fois la correction faite : 0 injection réelle sur 109 fichiers, à la force la plus
agressive testée.** C'est un résultat rassurant, mais il porte sur 5 candidats et un seul
niveau de force — voir §6 pour ce que ce chiffre ne dit pas.

## 6. Les coûts, en un coup d'œil

- **Décodage (mur du temps).** Médianes entre 1,937 et 2,150 s selon le bras, contre 1,951 s
  au baseline — aucun bras de biais seul ne dépasse le baseline de façon lisible ; le bras
  `prompt` (2,150 s) et `promptboost10` (2,137 s) sont un peu plus lents, cohérent avec le
  traitement de 11–15 tokens de prompt en plus, pas avec le filtre.
- **Filtrage (`timings.decodingFiltering`).** Sous 12 ms dans tous les bras, contre
  1,9–2,1 s de décodage total — sous 1 % partout. Le baseline lui-même paie déjà ~9,5 ms
  (les filtres intégrés de WhisperKit tournent toujours). Ce chiffre est bruité d'un bras à
  l'autre (voir §7) ; ne pas y lire plus qu'"indétectable à cette échelle".
- **Mots perdus.** Le biais seul coûte 0,0 à 0,2 % à 3 termes, −0,6 % à 30 termes — sans
  commune mesure avec le prompt (−2,1 % à 3 termes, −5,0 % à 30 dans la campagne
  précédente). C'est la conséquence directe de ne consommer aucun token de `promptTokens`.

## 7. Ce qui n'est PAS établi

- **`boostabsent10` ne teste que 5 candidats à une seule force.** Un mot dont le début de
  tokenisation ressemble à un mot français fréquent pourrait injecter à une force plus
  agressive que 10 ; rien ici ne borne le pire cas.
- **`decodingFiltering` n'est pas une mesure fiable du coût du filtre lui-même.**
  `promptboost10` affiche 1,3 ms quand `boost10` seul affiche 9,8 ms, pour le MÊME filtre à
  la MÊME force — l'écart n'a pas d'explication trouvée (probablement lié au mécanisme
  interne de repli en température de WhisperKit, qui peut ne renvoyer que les timings de la
  tentative finale). Le mur du temps (`decodeSeconds`) est la comparaison robuste ; le détail
  interne ne l'est pas.
- **La correction Obsidian était nécessaire parce que je n'ai vérifié le corpus qu'après
  coup, pas avant de choisir les termes.** Le protocole correct — vérifier chaque candidat
  "absent" contre les transcriptions baseline AVANT de lancer le bras — n'a pas été suivi ;
  il l'a été après, en observant un chiffre suspect. Un candidat different aurait pu passer
  inaperçu si son terme était moins reconnaissable qu'`Obsidian`.
- **`Superwhisper` porte tout le "au-delà des trois termes" sur ce corpus.** Une seule
  occurrence mesurable ; `Cursor`, également suivi, en a zéro. Le verdict "30 termes ne
  répare rien de plus" repose sur cette seule paire côté réparation, même si le total (43
  contre 45) est une comparaison bien plus large.
- **Aucun bras n'a été répété.** Le plancher de bruit (1,8 % de bascules de verdict) vient
  de la campagne précédente et est appliqué ici par extension, pas remesuré dans ce
  harnais modifié.
- **La force testée s'arrête à `continuation=10`.** Rien ne dit ce qui se passe à 20 ou 50 —
  ni pour les réparations, ni pour le risque d'injection au-delà des 5 candidats testés.
- **Le filtre ne regarde jamais l'audio.** Il boost un token sur la base du seul historique
  de tokens déjà décodés, jamais du signal — c'est une propriété du mécanisme, pas un
  defaut de cette implémentation, et c'est exactement pourquoi `boostabsent10` existe. Le
  fait qu'il ne montre aucune injection ici ne prouve pas qu'il ne peut jamais en produire.

## 8. Reproduire

```
swift build -c release --package-path benchmark/vocabprobe

python3 benchmark/vocab_boost.py jobs-boost.local.json jobs-arms2.local.meta.local.json

benchmark/vocabprobe/.build/release/vocabprobe jobs-boost.local.json results-boost.local.jsonl

python3 benchmark/vocab_boost_report.py
```

Un bras à la fois, un seul processus : le probe garde le modèle résident et bascule
`kit.textDecoder.logitsFilters` entre tâches plutôt que de recharger `WhisperKit` — aucune
recompilation ANE entre bras (chargement mesuré à 1,3–1,4 s dans cette campagne). Les
décodages ne lisent que `~/Documents/superwhisper/recordings` et n'écrivent que dans
`benchmark/*.local.*` — aucun benchmark n'écrit jamais dans
`~/Library/Application Support/Murmure/`.
