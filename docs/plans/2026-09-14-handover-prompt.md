# Prompt de passation (2026-09-14)

Texte à coller tel quel dans une nouvelle session d'assistant (ChatGPT ou autre) ouverte dans le
dépôt cloné. Il pointe vers `RESUME.md`, qui reste la source de vérité ; ce fichier n'est que le
message d'amorçage.

---

Tu reprends **Murmure**, une application macOS de dictée vocale entièrement locale (clone personnel
de Superwhisper), écrite en Swift/SwiftUI. Dépôt : `https://github.com/Loulouleloup1/murmure`
(privé), branche de travail `feat/murmure-v1`, miroir sur `main`, les deux à `4afc2fa`.

**Commence par lire, dans cet ordre, sans rien modifier :**
1. `RESUME.md` — état du projet, lots livrés, ce qui n'a pas été vérifié à l'œil, prochain chantier,
   règles de travail et contraintes de confidentialité. Tout ce qui suit en découle.
2. `docs/specs/2026-09-09-transcripts-design.md` — le prochain chantier, validé section par section
   avec moi le 2026-09-09.
3. `docs/plans/2026-09-backlog.md` — ce qui est fermé, ce qui a été mesuré puis refusé, ce qui est
   connu et non planifié.
4. `docs/plans/2026-09-09-modes-editor-v2.md` — le dernier plan exécuté, comme modèle du format
   attendu pour le prochain.

**Où en est le code.** 1392 tests passent (`cd MurmureCore && swift test`), l'app se construit
(`xcodegen generate` puis `xcodebuild`, commande exacte dans `RESUME.md` §5). Les règles vivent dans
le package `MurmureCore` (testé) ; le dossier `Murmure/` ne contient que le câblage et les vues, sans
bundle de test.

**Ce que j'attends de toi.**
1. D'abord un état des lieux en dix lignes maximum : ce que tu as compris, ce qui te semble
   incohérent ou manquant entre `RESUME.md`, le spec Transcripts et le code. Pas d'implémentation
   avant mon accord.
2. Ensuite, rédiger le plan d'implémentation du lot **T1** (spec §2, §5, §7) dans
   `docs/plans/`, découpé en tâches indépendantes, chacune avec ses tests à écrire d'abord, ses
   fichiers, et son critère de vérification. Me le présenter, attendre mon « go ».
3. Puis exécuter tâche par tâche : tests rouges, implémentation, tests verts, revue critique,
   commit petit et descriptif. Ne jamais grouper plusieurs tâches dans un commit, ne jamais
   squasher.
4. Enchaîner T2 et T3 de la même manière, puis le test bout-en-bout réel du spec §5 (me prévenir
   avant, il occupe le Neural Engine).

**Règles non négociables** (détail dans `RESUME.md` §6) :
- Mes dictées (`~/Documents/superwhisper/recordings/`, `~/Library/Application Support/Murmure/`)
  sont du contenu professionnel privé : lisibles en local, jamais commitées, jamais citées.
- Ne jamais écrire dans `~/Library/Application Support/Murmure/` ; les tests reçoivent des dossiers
  temporaires.
- Un seul modèle chargé à la fois ; ne jamais supprimer mes cinq modèles Ollama ; tout modèle tiré
  pour un test est supprimé ensuite.
- Ne pas lancer l'interface graphique, ne pas piloter ma souris ou mon clavier, ne pas toucher au
  presse-papiers général, ne pas déclencher de dialogue de permission macOS.
- Expliquer et obtenir mon accord avant d'implémenter un changement ; pas de code spécifique à ma
  machine ou à mon usage ; solutions générales et simples ; décisions appuyées sur des mesures.
- `scripts/install.sh` quitte Murmure sans le relancer : me le dire à chaque installation.
- Push : `gh auth switch --user Loulouleloup1`, pousser `feat/murmure-v1` et
  `feat/murmure-v1:main`, puis `gh auth switch --user LouisCourcier`.

**En parallèle, je dois vérifier moi-même à l'écran** les huit points de `RESUME.md` §3 (Home,
survols, Modes v2). Si je te rapporte un défaut, reproduis-le par un test avant de corriger.

Réponds en français, de façon concise.
