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

---

# Round 2 — brider le biais : aucune des trois règles ne passe la barre fixée, et `PR` reste dangereux

Date : 2026-09-04 · Corpus : les MÊMES 109 dictées (`jobs-arms2.local.meta.local.json`,
109 fichiers) · `baseline` réutilisé tel quel depuis `results-boost.local.jsonl` (0
redécodage — déterministe, prompt et filtre nuls, déjà vérifié reproductible §1
ci-dessus) · Nouveaux résultats : `benchmark/results-bridle.local.jsonl`,
`results-bridle30.local.jsonl`, `results-bridle-short.local.jsonl`, jamais commités ·
Harnais : `VocabularyBoostFilter.swift` généralisé à un bonus PAR TERME (au lieu d'un
bonus global pour tout le filtre — voir §0) + `benchmark/vocab_bridle.py` · **654
décodages neufs (436 + 109 + 109), ~71 min mur du temps — dont ~44 min portées par un
seul bras qui a fait s'effondrer le décodage (§3).**

La question posée : le premier round a trouvé que `boost30x10` injecte `dbt` — un mot que
Louis n'a jamais dit une seule fois au baseline — dans 9 des 109 fichiers, 23 fois, dès
que le filtre porte 30 termes à force 10. Le contrôle du premier round ne pouvait pas
voir ça : ses 5 candidats inventés étaient tous longs et distinctifs, la forme qui NE
provoque justement pas ce défaut. Quelle règle rend un biais sûr à pointer sur une liste
de vocabulaire libre — et `PR`, l'exemple de Louis (deux caractères, ambigu à l'oreille),
peut-il être rendu sûr ?

**Réponse : aucune des trois règles testées ne passe le critère fixé au départ — garder
les réparations sur `Claude Code`/`Trucost`/`WeeFin` ET ramener les termes courts à leur
taux de baseline. Les deux règles basées sur la longueur (plancher de tokens, force mise
à l'échelle) suppriment `dbt` et ramènent `PR`/`MDI` à zéro, mais tuent la réparation de
`Trucost` (6 → 0-1) et laissent passer 1 injection de `esgc` sur 109 fichiers — parce que
`Trucost` et `dbt`/`MDI` tokenisent à la MÊME longueur, et `esgc` à la même longueur que
`Claude Code`/`WeeFin`. La règle qui retire le bonus de premier token est la seule à
atteindre zéro injection partout, mais elle détruit 45 des 46 réparations — le mécanisme
de réparation dépend du MÊME bonus que le mécanisme de risque. `PR` (1 token) ne montre
aucune injection à force 10 dans ce corpus réel — mais un bras testé à force 30 fait
s'effondrer le décodage lui-même (mots ×2,5 en médiane, jusqu'à ×84, similarité à 0,016),
et le seul cas qui a survécu à ce bras noyait `PR` dans plus de 2 000 occurrences fausses
sur 27 fichiers. « Peut-on booster `PR` sans risque » n'a donc pas de réponse positive
propre : sûr ici, à cette force — pas garanti au-delà, et rien ne dit où la limite est.**

---

## 0. Le changement de harnais : un bonus par terme, pas un bonus par filtre

`VocabularyBoostFilter` du round 1 prenait UN SEUL `firstTokenBonus`/`continuationBonus`
pour tout le filtre, appliqué identiquement à chaque terme de la liste. Aucune règle de
bridage ne peut s'exprimer avec ça — "moins fort pour ce terme-là" suppose un bonus par
terme. Le filtre porte maintenant un tableau `[Term]` (`tokens`, `firstTokenBonus`,
`continuationBonus` propres à chacun) ; la boucle de correspondance n'a pas changé,
seule la provenance du bonus est devenue locale au terme plutôt que globale au filtre.
Confiné à `benchmark/vocabprobe/` (package SwiftPM séparé, jamais importé par l'app) —
aucun code app touché.

Un fait de tokenisation découvert en même temps que ce changement, et qui structure tout
le reste de cette section — `tokencount` sur chaque terme, espace initiale incluse
(exactement l'entrée du filtre) :

| terme | tokens | terme | tokens |
|---|---:|---|---:|
| `Claude Code` | 3 | `PR` | **1** |
| `Trucost` | **2** | `dbt` | **2** |
| `WeeFin` | 3 | `MDI` | **2** |
| `esgc` | 3 | `DCG` | 2 |
| `Superwhisper` | 4 | `Notion` / `Serena` / `Parquet` | 2 |

`PR` est le SEUL terme à 1 token de toute cette liste : sa boucle de correspondance
(`term.tokens.count - 1 == 0`) ne peut jamais atteindre la branche de continuation — il
ne reçoit QUE `firstTokenBonus`, à chaque étape de décodage, sans jamais de confirmation
en deux temps. Mais `Trucost` (un terme qu'on VEUT réparer) partage sa longueur exacte
(2 tokens) avec `dbt` et `MDI` (des injections confirmées au round 1), et `esgc` (3
tokens, injecte quand même) partage la longueur de `Claude Code`/`WeeFin`. **La longueur
de tokenisation ne sépare donc PAS proprement les termes voulus des termes dangereux** —
ce que les trois règles ci-dessous démontrent chacune à leur manière.

## 1. Les quatre bras à force 10, sur une liste volontairement mixte

Sept termes boostés dans chaque bras (sauf `baseline`) : les 3 termes de réparation
connus (`Claude Code`, `Trucost`, `WeeFin`) + 4 termes courts choisis pour casser un
contrôle trop facile — `PR` (la question de Louis), `dbt` (confirmé 100 % injection au
round 1), `MDI` (injection partielle mais aussi vocabulaire réel), `esgc` (petit mais
réel, même longueur que les termes voulus).

| bras | règle |
|---|---|
| `noBridle` | force 10 uniforme sur les 7 termes, mécanisme du round 1 sans changement |
| `floorFilter` | plancher à 3 tokens : seuls `Claude Code`/`WeeFin`/`esgc` gardent un bonus ; `Trucost`/`PR`/`dbt`/`MDI` à 0/0 |
| `noFirstToken` | `firstTokenBonus=0` pour LES 7 TERMES, `continuationBonus=10` inchangée |
| `scaledByTokens` | force = `10 × clamp((tokens-1)/2, 0, 1)` — `PR`→0, `Trucost`/`dbt`/`MDI`→5, le reste→10 |

### Réparations (dénominateur : `Claude Code` 60, `Trucost` 35, `WeeFin` 10 — 105, voir §5)

| bras | Claude Code | Trucost | WeeFin | total /105 | mots | sim | régr |
|---|---:|---:|---:|---:|---:|---:|---:|
| `noBridle` | 31 | 6 | 9 | **46** | −0,1 % | 0,997 | 0 |
| `floorFilter` | 31 | **0** | 9 | 40 | +0,2 % | 1,000 | 0 |
| `noFirstToken` | **1** | 0 | **0** | **1** | −0,0 % | 1,000 | 0 |
| `scaledByTokens` | 31 | 1 | 9 | 41 | +0,1 % | 1,000 | 0 |

`noBridle` retombe sur les mêmes ordres de grandeur que `boost10` du round 1 (CC 31, WF
9, TC 5) malgré 4 termes de plus dans le filtre — les termes n'interfèrent pas entre eux,
cohérent avec la boucle `bonusByToken` qui les traite indépendamment.

### Termes courts (brut / injection réelle = absent du baseline du même fichier)

| bras | PR | dbt | MDI | esgc |
|---|---|---|---|---|
| `baseline` | 4/4 fichiers | 0/0 | 15/5 | 0/0 |
| `noBridle` | 4, **inj=0** | 17, **inj=8** | 16, **inj=1** | 2, **inj=2** |
| `floorFilter` | 4, inj=0 | 0, inj=0 | 15, inj=0 | 2, **inj=1** |
| `noFirstToken` | 4, inj=0 | 0, inj=0 | 15, inj=0 | 0, inj=0 |
| `scaledByTokens` | 4, inj=0 | 0, inj=0 | 15, inj=0 | 2, **inj=1** |

**Aucune des trois règles ne passe le critère fixé au départ.** `floorFilter` et
`scaledByTokens` suppriment `dbt`/`MDI` mais coûtent presque toute la réparation de
`Trucost` (6→0 ou 6→1) et laissent passer 1 injection de `esgc` sur 109 fichiers — le
même défaut que celui prédit en §0 : `esgc` est à la même longueur que les termes qu'on
veut garder intacts, la règle ne peut pas le voir. `noFirstToken` atteint 0 injection
partout (y compris `esgc`) mais détruit 45 des 46 réparations : `Claude Code` retombe de
31 à 1, preuve que le mécanisme de réparation dépend presque entièrement du MÊME bonus de
premier token que celui qui cause le risque — ce n'est pas une coïncidence, c'est
structurel (§0 : sans lui, un terme multi-tokens ne peut être amorcé que si le modèle
émet son premier sous-token tout seul, sans aide).

## 2. La version sélective de la règle 3 — retirer le bonus SEULEMENT sur les termes courts

Le libellé exact du brief était « bonus de premier token retiré pour les termes courts »
— pas pour tous. `noFirstTokenShort` applique donc `firstTokenBonus=0` seulement aux
termes sous le plancher à 3 tokens (`Trucost`, `PR`, `dbt`, `MDI`), en gardant le
mécanisme intact (`firstTokenBonus=10/3`) sur `Claude Code`/`WeeFin`/`esgc` :

| bras | Claude Code | Trucost | WeeFin | total /105 | PR | dbt | MDI | esgc |
|---|---:|---:|---:|---:|---|---|---|---|
| `noFirstTokenShort` | 31 | **0** | 9 | 40 | 4, inj=0 | 0, inj=0 | 15, inj=0 | 2, **inj=1** |

**Identique à `floorFilter` terme pour terme.** `Trucost` retombe à 0 réparation même en
gardant sa `continuationBonus` de 10 intacte — la seule chose qu'on lui retire est le
bonus de premier token, et ça suffit à tuer sa réparation aussi complètement que de
l'exclure du filtre. `Claude Code`/`WeeFin`/`esgc`, eux, gardent leur comportement de
`noBridle` puisqu'ils sont au-dessus du plancher et n'ont rien perdu. **La règle
sélective ne fait donc rien de plus que le plancher pur** sur ce corpus — et hérite du
même défaut sur `esgc` ET du même coût sur `Trucost`, pour la raison énoncée en §0 :
`Trucost` est aussi court que `dbt`/`MDI`, donc indiscernable d'eux par n'importe quelle
règle qui ne regarde que la longueur.

## 3. Force 30 : pas "plus fort", cassé

`noBridle30` reprend les mêmes 7 termes à force 30 (jamais testée avant ce round — le
round 1 s'arrêtait à 10). Ce n'était pas pensé comme un bras de bridage mais comme un
test de robustesse de `PR` à plus haute force ; le résultat dépasse largement la
question posée.

| | mots (ratio bras/baseline) | similarité | injections PR / dbt / MDI / esgc |
|---|---|---|---|
| médiane | **×2,54** | **0,016** | |
| fichiers >2× les mots du baseline | **75/109** | | |
| brut / fichiers / injection réelle | | | PR 2317/27/**27** · dbt 2375/96/**96** · MDI 3077/91/**86** · esgc 1004/92/**92** |

Un fichier sur trois double au moins ses mots, la moitié du corpus dépasse 2×, un cas
extrême atteint 84,5× — et la similarité au texte du baseline tombe à 0,016, contre
0,997–1,000 pour les bras à force 10. Ce n'est pas une injection ponctuelle, c'est un
effondrement du décodage : le décodeur médian passe de 1,97 s à **18,8 s** par fichier
(mesure indicative — la contention CPU documentée dans ce round biaise les temps absolus,
mais un facteur ×9,5 dans le MÊME run n'est pas du bruit de contention). `dbt` apparaît
dans 96 des 109 fichiers, `esgc` dans 92 — des mots absents de tout le reste de la
campagne, dans la quasi-totalité du corpus.

**Conséquence pour la question de Louis : le test « `PR` à plus haute force » n'a pas pu
isoler un risque spécifique à `PR`, parce qu'à force 30 TOUS les termes du filtre
inondent le texte, pas seulement `PR`.** `PR` lui-même passe de 0 injection (force 10) à
27 fichiers sur 109 contaminés (force 30) — mais dans un régime où le décodage entier est
cassé, pas dans un régime où `PR` spécifiquement a franchi un seuil. Rien ici ne dit à
quelle force EXACTEMENT la rupture commence entre 10 et 30 ; ce n'est pas mesuré et ça ne
l'a pas été par choix de proportionnalité (un balayage 15/20/25 aurait triplé le budget
de ce round pour une question secondaire).

## 4. Verdict sur `PR` spécifiquement

**Non établi comme sûr en général ; sûr sur ce corpus à cette seule force testée.** À
force 10, sans aucune règle de bridage, `PR` montre exactement le même compte (4 brut,
0 injection) que le baseline sur les 109 fichiers réels de Louis — alors que `dbt`, un
terme de longueur comparable (2 tokens contre 1), injecte 8 fois dans la même liste à la
même force. Donc à force 10, `PR` ne fait PAS partie des termes qui cassent : c'est
mesuré, pas supposé. Mais :

- Le test à force 30 montre que la force n'est pas un simple curseur "plus" = "mieux" —
  entre 10 et 30 quelque chose casse pour TOUS les termes, `PR` inclus (0 → 27 fichiers
  contaminés). Rien ne garantit que `PR` reste à 0 injection à force 15 ou 20.
- Aucune des trois règles de bridage testées en §1-2 n'a été vérifiée sur `PR` dans un
  régime où `PR` injectait déjà (puisqu'il n'injectait pas à force 10) — donc aucune
  n'est validée comme "la" règle qui rendrait `PR` sûr si jamais il se mettait à
  injecter à une force ou un contexte audio différent.
- Le corpus de 109 fichiers ne contient que 4 occurrences de `pr` au baseline, sur un
  terme de 2 caractères dont le brief note lui-même l'ambiguïté phonétique — l'exposition
  réelle à ce terme précis est plus faible ici que pour `Claude Code` (60) ou `Trucost`
  (35), donc l'absence d'injection mesurée porte moins de poids statistique que les autres
  chiffres de cette campagne.

**Réponse honnête : oui pour ce corpus et cette force ; non garanti au-delà, et ce round
ne dit pas où la garantie s'arrête.**

## 5. Le dénominateur utilisé

Ce round utilise la MÊME méthode que `vocab_boost_report.py` du round 1 : pour chaque
fichier, l'ensemble des termes pertinents vient des dictionnaires `mangled`/`correct`
figés à la sélection (`vocab_select.py`, patterns curés à la main sur le corpus
`small` de Superwhisper), et le plafond de réparations est le nombre de ces paires où
le baseline (`large-v3-turbo`) donne `mangled`. Sur les 3 termes réellement boostés ce
round (`Claude Code`/`Trucost`/`WeeFin`), ça donne **105** (60+35+10) — pas 106, parce que
`Superwhisper` (1 occurrence) n'était pas dans la liste boostée ce round.

J'ai essayé de reproduire le chiffre de 114 avancé dans le brief avec deux méthodes sur
les données du round 1 (aucun redécodage nécessaire) :
- Méthode A (celle du round 1, ci-dessus) : **106** sur les 5 termes suivis.
- Méthode B, plus large : compter `verdict(baseline, terme) == mangled` directement sur
  les 109 fichiers × 5 termes, SANS filtrer par les dictionnaires `mangled`/`correct` de
  sélection : **107** (`WeeFin` passe de 10 à 11 — un fichier sélectionné pour un autre
  terme où `WeeFin` était aussi mangled sans être dans son dictionnaire de sélection).

Ni 106 ni 107 ne font 114. Je n'ai pas reconstruit la méthode exacte du recompte
indépendant (« union-of-arms ») faute de savoir précisément ce qu'elle inclut de plus —
je le signale plutôt que de deviner. Pour ce round, méthode A (105 sur 3 termes) est
utilisée partout par cohérence avec le script déjà en place ; le choix ne change aucune
conclusion qualitative (aucune des règles ne passe le critère, quel que soit le
dénominateur).

## 6. Ce qui n'est PAS établi

- **Aucune règle testée ne satisfait le critère du brief.** Les deux versions basées sur
  la longueur (plancher, mise à l'échelle, sélective) partagent le même angle mort sur
  `esgc` et le même coût sur `Trucost` ; celle qui retire tout bonus de premier token est
  sûre mais inutile pour la réparation. Une quatrième piste — combiner un signal qui
  regarde CE QUI a déjà été émis organiquement avant d'accorder le bonus de premier
  token, pas seulement la longueur du terme — n'a pas été conçue ni testée ce round.
- **Le seuil de rupture entre force 10 et force 30 n'est pas localisé.** `noBridle30`
  montre l'effondrement, pas où il commence.
- **`esgc` ne porte qu'1 injection sur 109 fichiers dans les 3 bras qui le laissent
  passer** — un seul point de données, comme `Superwhisper` au round 1.
- **Le mur du temps de ce round est doublement peu fiable** : la contention CPU documentée
  dans le brief affecte les bras à force 10 (ordre de grandeur, pas la conclusion), et le
  bras à force 30 mesure en plus un effondrement réel du décodage — les deux effets ne
  sont pas séparés dans les 18,8 s médianes rapportées en §3.
- **`PR` n'a que 4 occurrences de baseline sur 109 fichiers** — la plus faible exposition
  de tous les termes mesurés cette campagne, donc le "0 injection" mesuré au §4 est le
  chiffre le moins robuste statistiquement de cette section.
- **Rien de tout cela ne regarde l'audio.** Toutes les règles testées restent des
  fonctions de la longueur de tokenisation ou de la présence dans l'historique — jamais
  du signal encodeur. `esgc` qui persiste malgré 3 règles différentes en est la preuve
  directe : la longueur n'a jamais été, structurellement, un proxy de "le locuteur a-t-il
  vraiment dit ça".

## 7. Reproduire (round 2)

```
swift build -c release --package-path benchmark/vocabprobe

python3 benchmark/vocab_bridle.py benchmark/jobs-bridle.local.json benchmark/jobs-boost.local.meta.local.json
benchmark/vocabprobe/.build/release/vocabprobe benchmark/jobs-bridle.local.json benchmark/results-bridle.local.jsonl

# Force 30 (§3) et règle sélective short-only (§2), chacun un bras isolé
python3 benchmark/vocab_bridle_strength.py benchmark/jobs-bridle30.local.json benchmark/jobs-boost.local.meta.local.json
benchmark/vocabprobe/.build/release/vocabprobe benchmark/jobs-bridle30.local.json benchmark/results-bridle30.local.jsonl

python3 benchmark/vocab_bridle_short.py benchmark/jobs-bridle-short.local.json benchmark/jobs-boost.local.meta.local.json
benchmark/vocabprobe/.build/release/vocabprobe benchmark/jobs-bridle-short.local.json benchmark/results-bridle-short.local.jsonl
```

`baseline` n'a pas été redécodé : il est repris tel quel de `results-boost.local.jsonl`
(mêmes 109 fichiers, prompt et filtre nuls, décodage déterministe déjà vérifié
reproductible au round 1 §1). Un bras à la fois, un seul processus, aucune recompilation
ANE entre bras (chargement mesuré 1,3–1,5 s). Les décodages ne lisent que
`~/Documents/superwhisper/recordings` et n'écrivent que dans `benchmark/*.local.*` —
aucun n'écrit jamais dans `~/Library/Application Support/Murmure/`.
