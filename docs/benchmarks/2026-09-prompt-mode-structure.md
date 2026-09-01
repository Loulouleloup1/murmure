# Mode Prompt structuré — pourquoi il n'a pas été livré

Date : 2026-09-02 · Corpus : 53 dictées réelles de Louis (`benchmark/fixtures-promptmode.local.jsonl`,
**jamais commité**) · Résultats : `benchmark/results-promptmode{,B,C}-*.local.jsonl`, **jamais
commités** · Harnais : `benchmark/run_arms{,_b,_c}.py` · Détecteurs : `benchmark/detect{,_c}.py` ·
Grilles pré-enregistrées : `benchmark/rubric-promptmode{,-noslot}.md`

Louis a demandé un mode `Prompt` qui produise « vraiment un truc hyper structuré », au lieu du
nettoyage que fait le mode actuel. Contrainte qu'il a lui-même posée : **structurer sans inventer**
— réorganiser ce qu'il a dit, n'ajouter rien qu'il n'ait pas dit.

**Décision : aucun nouveau mode n'est livré.** On garde la dictée et la reformulation telles
qu'elles fonctionnent. Ce document existe pour que personne ne refasse ces trois campagnes.

---

## 1. Le fait le plus durable : 21 % de ce qu'il dicte ne demande rien

Sur les 53 dictées, **11 (21 %) ne contiennent ni impératif, ni demande, ni question** adressée à
l'agent. Ce sont des acquiescements, des accords, des constats d'état, des explications.

Ce chiffre ne dépend d'aucun modèle, d'aucun prompt et d'aucune conception. Il décrit son usage.
Il a été établi **une seule fois, avant de noter le moindre arm**, à partir des transcriptions
seules — c'est ce qui le rend réutilisable et c'est ce qui rend les comparaisons ci-dessous
honnêtes.

**Conséquence directe :** toute conception qui suppose qu'une demande existe se trompe une fois
sur cinq sur son usage réel. C'est le fait qui a tué le mode structuré, et il survivra aux modèles
mesurés ici.

### Le corpus

| source | n | quoi |
|---|---:|---|
| `murmure.sqlite` | 16 | chaque ligne est en mode `Prompt`, vers un terminal ou un éditeur |
| enregistrements superwhisper du 2026-08-31 | 37 | la veille, même contexte de travail |

Stratifié par longueur : 8 courtes (< 150 car.), 30 moyennes, 15 longues (max 1 481 car.). La
longueur compte : une dictée courte n'a rien à réorganiser, et c'est là que l'invention est la plus
tentante.

**Confidentialité.** Le corpus est du contenu de travail réel. Il est lu localement, il n'apparaît
nulle part dans ce document, et les fichiers suivent le motif `benchmark/*.local.jsonl` couvert par
`.gitignore` (vérifié au `git check-ignore`). Aucun extrait de dictée n'est reproduit ici.

---

## 2. Une case obligatoire fabrique ce qu'il faut y mettre

Première conception : un gabarit `Tâche : / Contexte : / Contraintes :`, avec instruction explicite
d'omettre toute rubrique sans matière.

**Métrique pré-enregistrée — FAB-TASK :** parmi les 11 dictées qui ne demandent rien, combien
reviennent avec une ligne `Tâche :` affirmant une action que le locuteur n'a jamais demandée. Une
`Tâche : Aucune` ne compte pas — c'est le modèle qui refuse d'inventer.

| arm | FAB-TASK | rubrique vide écrite | structuré | médiane | pire |
|---|---:|---:|---:|---:|---:|
| s1-mini `[Context: general]` (témoin) | **0/11** | 0/53 | **0/53** | 0,43 s | 1,47 s |
| gemma4 e2b, prompt à règles | **11/11 (100 %)** | 13/53 | 53/53 | 1,09 s | 4,38 s |
| gemma4 12B, prompt à règles | **10/11 (91 %)** | 46/53 (87 %) | 52/53 | 4,01 s | 10,26 s |
| gemma4 e2b, prompt à branche explicite | **9/11 (82 %)** | 28/53 | 52/53 | 1,12 s | 3,96 s |
| gemma4 12B, prompt à branche explicite | **3/11 (27 %)** | 25/53 | 42/53 | 4,43 s | 9,50 s |

*« structuré » = la sortie porte au moins une rubrique. Le témoin s1-mini est à 0 : il ne structure
pas, c'est le mode actuel, il est là comme plancher.*

**Le prompt n'est pas l'explication, mais il pèse.** Le second prompt fait de « la dictée ne demande
rien » une branche explicite en tête d'instruction (« si elle ne demande rien, rends-la nettoyée,
sans rubrique, et arrête-toi »). Il fait passer le 12B de 91 % à 27 % et ne bouge presque pas l'e2b
(100 % → 82 %). **Le défaut est donc réel et seulement partiellement contournable par le prompt.**

### Le défaut n'est pas cosmétique

Une des sorties du 12B, sur sa meilleure configuration, **inverse une instruction** : le locuteur
signale qu'une option n'est pas affichée ; la sortie demande à l'agent de faire en sorte qu'elle
ne soit pas affichée. C'est l'ordre contraire, remis à un agent qui l'exécutera.

C'est ce mode d'échec, et pas la latence, qui disqualifie la conception. Le 12B tourne ici en
**4,4 s de médiane, 9,5 s au pire** — la mesure du lot 2 (19 s de médiane, 57,5 s au pire) **ne se
transporte pas** : structurer produit une sortie bien plus courte que réécrire un mail ou un
message. La lenteur n'est pas le problème.

---

## 3. Supprimer la case supprime le défaut par construction

Seconde conception : **aucune case `Tâche :`**. Nettoyer, découper en points, un point par ligne,
dans l'ordre où il l'a dit, dans ses mots. Aucune rubrique.

**FAB-TASK n'a plus de sens sans case à remplir** — il fallait donc une autre métrique, et elle a
été pré-enregistrée avant la première exécution (`benchmark/rubric-promptmode-noslot.md`).

**ADD-CLAIM :** une proposition que la sortie affirme et que la transcription ne contient pas —
tâche, contrainte, critère, étape de vérification, fichier, outil, nombre, nom, ou fait. Comptée
**où qu'elle apparaisse**, précisément parce qu'un modèle privé de case peut inventer ailleurs.

Deux couches, et **le détecteur a changé avec la conception** au lieu d'être repris tel quel :

- **Couche A**, mécanique : tout *mot plein* de la sortie absent de l'entrée, après normalisation
  des accents et de la flexion. Élargi depuis le détecteur de « jetons durs » de la campagne 1,
  parce que cette conception prétend garder ses mots — un mot plein nouveau est donc une preuve
  pertinente ici, là où sous un gabarit il n'aurait été que du bruit.
- **Couche B**, adjudication : lecture de **toutes** les sorties signalées par la couche A, **plus
  un échantillon aléatoire fixe de 20 non signalées** par arm, pour estimer ce que la couche A rate.

| arm | ADD-CLAIM | signalé couche A | segmente (42 demandes) | recopie l'entrée | médiane | pire | RSS crête |
|---|---:|---:|---:|---:|---:|---:|---:|
| gemma4 e2b, sans case | **0/53** | 5/53, 7 mots | 23/42 | 14/42 | 1,27 s | 3,78 s | 4,6 Go |
| gemma4 12B, sans case | **0/53** | 8/53, 13 mots | **36/42** | 15/42 | 4,87 s | 13,93 s | 9,0 Go |
| s1-mini (témoin, **non adjugé**) | *voir §5* | 14/53, 19 mots | 15/42 | 29/42 | 0,43 s | 1,47 s | 1,07 Go |

**Zéro invention sur les deux modèles, et c'est un zéro vérifié.** Chaque signalement de la couche A
a été adjugé : ce sont presque tous des artefacts de segmentation en mots. L'échantillon de contrôle
n'a rien trouvé non plus.

**Le garde-fou contre le vainqueur dégénéré tient.** Une sortie qui recopie l'entrée passe le test
d'invention parfaitement et ne vaut rien : d'où les deux colonnes de droite. Les deux arms sans
case recopient nettement moins que le témoin (14–15/42 contre 29/42) tout en segmentant plus
(23 et 36/42 contre 15/42). La recopie se concentre sur les dictées courtes — 7 des 8 courtes,
3 des 15 longues — ce qui est le comportement correct, pas de la dégénérescence.

**Sur les 42 dictées qui SONT des demandes, le résultat reste utile** : celles qui portent plusieurs
demandes reviennent à raison d'une demande par ligne, dans ses phrases, inchangées. C'est la forme
qu'un agent lit le mieux.

### Ce que ça ne donne pas

**Ce n'est pas ce que Louis a demandé.** De la prose nettoyée et segmentée dans ses mots n'est pas
la forme tâche/contexte/contraintes. C'est une amélioration réelle sur le mode actuel et ça respecte
« n'ajoute rien » intégralement — mais **la mesure dit qu'il ne peut pas avoir les deux en local** :
cette conception achète la sûreté en abandonnant la forme.

C'est la piste à reprendre si quelqu'un revient sur le sujet.

---

## 4. Latence et RAM — méthode

**Toutes les figures ci-dessus sont mesurées sur cette machine (M4 Pro), une seule fois par appel,
modèles strictement séquentiels — jamais deux résidents en même temps.**

- **Formes de requête copiées de la production, pas approximées.** Dialecte s1 : `/api/generate`,
  `raw: true`, conversation écrite à la main avec bloc `<think>` vide prérempli, `temperature` 0,
  `repeat_penalty` 1.1, `num_ctx` 4096, `truncate` false, `stop` sur les marqueurs de tour.
  Dialecte chat : `/api/chat`, `think: false`, `temperature` 0, `num_predict` 2048, `num_ctx` 8192.
  Graine 20260901 dans les deux cas. **Une latence mesurée sous d'autres options est la latence
  d'une autre application.**
- **Latence** : horloge murale autour de l'appel HTTP, modèle déjà chaud (il reste chargé sur les
  53 fixtures). Les médianes ci-dessus ne contiennent donc **pas** le chargement à froid.
- **RSS crête** : somme des RSS `ollama` + `llama-server` échantillonnée après chaque génération.
  **Méthode plus grossière que celle de `benchmark/ram-v3*.json`**, qui échantillonne le seul
  `llama-server` toutes les 50 ms. Les chiffres de référence restent ceux de `ram-v3-ctxsweep.json`
  (s1-mini 1,07 Go à 4096 ; e2b 4,64 Go ; 12B 8,24 Go) ; les mesures de cette campagne les
  corroborent sans les remplacer.

### Ce que ça coûterait sur le Mac 16 Go

| pile | total |
|---|---:|
| Whisper + s1-mini (aujourd'hui) | ~2,6 Go |
| Whisper + s1-mini + e2b | ~7,2 Go |
| Whisper + s1-mini + 12B | ~11,6 Go |

Un mode structuré cohabite avec le mode de nettoyage : les deux modèles sont résidents. C'est
pourquoi la colonne RSS pèse dans la décision et pas seulement la qualité.

---

## 5. Ce qui n'est PAS établi — s1-mini n'a jamais été adjugé

**Le témoin s1-mini n'a pas été soumis à l'adjudication ADD-CLAIM.** Sa ligne dans le tableau du
§3 porte un compte de **couche A seulement** : 19 mots pleins nouveaux sur 14 sorties.

La couche A sur-signale par construction — flexion française, artefacts de découpage en mots. Sur
les deux arms qui *ont* été adjugés, **la totalité des signalements se sont révélés n'être pas des
inventions**. Il n'y a donc aucune raison de supposer que les 19 de s1-mini en sont.

**« s1-mini dérive plus de ses mots que les autres » n'est pas un résultat de cette campagne.** Le
comparer aux 7 et 13 des arms sans case compare un majorant de candidats non adjugés à des comptes
adjugés à zéro — ce n'est pas une comparaison valide, et l'affirmation a déjà été faite une fois à
tort avant d'être corrigée. Qui reprend le sujet et veut ce chiffre doit passer s1-mini par la
couche B.

---

## 6. Défauts relevés sur la conception sans case

Trois, dont un qui m'appartient :

1. **Dérive de terme.** Les abréviations métier de Louis sont parfois développées en toute lettre.
   L'e2b le fait souvent, le 12B de façon inconsistante — il garde la forme dictée sur une sortie et
   la développe sur une autre. Ce n'est pas une affirmation ajoutée, mais c'est son raccourci réécrit,
   et l'instruction disait de garder les termes tels que dictés.
2. **Bascule de langue, et c'est un défaut de mon prompt, pas des modèles.** La seule dictée en
   anglais du corpus revient en français sur les deux arms, parce que mes instructions disent
   « produis du français ». Corrigeable à peu de frais ; à ne pas imputer aux modèles.
3. **Le 12B fournit un mot sur une transcription abîmée.** Sur une dictée où la reconnaissance
   vocale avait produit un mot inexistant, il substitue la tournure correcte. C'est très
   probablement la bonne devinette, et sans doute la réparation qu'on attend d'un modèle de
   nettoyage — mais c'est un mot que le locuteur n'a pas dit, et il vaut mieux le voir écrit ici
   que le voir passer silencieusement pour un succès.

---

## Reproduire

Le corpus se reconstruit depuis les deux sources locales avec `benchmark/build_corpus.py`. Ensuite,
un arm à la fois, jamais deux modèles en même temps :

```
python3 benchmark/run_arms.py   <arm>   # gabarit avec case Tâche, prompt à règles
python3 benchmark/run_arms_b.py <arm>   # gabarit avec case Tâche, branche explicite
python3 benchmark/run_arms_c.py <arm>   # sans case
python3 benchmark/score.py      <arms>  # FAB-TASK, rubriques vides
python3 benchmark/detect_c.py   <fichier de résultats>  # couche A, recopie, segmentation
```

L'ensemble de référence des 11 dictées qui ne demandent rien est dans `benchmark/no_ask.txt` — il
est établi avant toute notation et il vaut pour tous les arms. Le refaire après avoir lu des
sorties invaliderait toute comparaison.
