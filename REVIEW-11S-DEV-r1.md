# Revue lot 11-S (DEV `t_6ebc3f69`) — round 1, lentille ARTEFACT

Verdict : **PASS**, 0 finding bloquant. Deux observations non bloquantes, dont une
régression réelle laissée sans propriétaire (carte créée, voir §5).

## 1. Le diff, lu à froid

123 lignes d'implémentation sur 4 fichiers (`diff -u` contre `t_7785056d`, la base
transportée) ; `TranscriptControlServer.swift` a 0 ligne. Borne du plan ≤ 390 : tenue.

| Fichier | Lignes (`diff -u`) |
|---|---|
| `Murmure/TranscriptsPaneModel.swift` | 45 |
| `Murmure/MurmureApp.swift` | 37 |
| `Murmure/AppDelegate.swift` | 32 |
| `Murmure/DictationController.swift` | 9 |
| `Murmure/TranscriptControlServer.swift` | 0 |

Cinq critères du plan (§4 lot 11-S, l. 1267-1272) confronts au code, pas au récit :

1. **Un seul moteur** — `DictationController.swift:365` `transcriptionEngine = engine`,
   la seule construction de `WhisperKitEngine(` dans `Murmure/` hors `ModelWarmup.swift`
   (échauffement, distinct et antérieur). `TranscriptsPaneModel.init(library:engine:)`
   prend `engine` en paramètre **non optionnel** : un appelant qui l'oublie ne compile
   pas — l'invariant est dans le type, pas dans une convention.
   `engine.loadedModelForVideo(dedicatingComputeUnits: false)` (`WhisperKitEngine.swift:331-334`)
   retourne `loadedKit(for:)` — le modèle **déjà chargé** par la dictée, aucune seconde
   instance. Le paramètre L12 reste le seul chemin vers une instance dédiée.
2. **Delegate propriétaire, handover idempotent** — `AppDelegate.swift:39` propriété,
   `guard controlServer == nil else { return }` en sortie anticipée réelle,
   `if applicationLaunched { start() }`. `start()` dans `applicationDidFinishLaunching`,
   `stop()` dans `applicationWillTerminate`. L'ordre des deux chemins (handover avant ou
   après le lancement) rend le démarrage unique dans les deux cas.
3. **Submitteur = file 10-S** — `MurmureApp.swift:255-264` : `transcriptsModel.submit(source)`
   puis `ControlJobHandle(attendu:)` ; `fournisseurStatut: { await transcriptsModel.queueStatus() }`.
   Une seule table de traduction file→socket (`MurmureApp.outcome(of:model:)`, extension privée).
4. **Chemin Finder** — rejoué par moi (§3).
5. **Journal** — `FINDER journal_lignes=9`, `log-no-transcript-text` VERT.

Point de conception vérifié à froid : `MurmureApp.outcome(of:model:)` fait
`model.finishedDocument(id: documentID)` sur la **tige** transportée par la file, et
`library.transcript(id:)` est bien une recherche par tige. La ré-derivation
`documentID(for:)` (identité SHA-256 passée à une recherche de tige) a disparu du
panneau — le défaut trouvé par la gate 11-S est absorbé par le parent `t_95eaa2b1`, et
`.complete(documentID:)` est désormais atteignable. Une tige illisible rend `.failed(phrase)`,
jamais un succès que personne ne peut ouvrir.

## 2. Périmètre

- Fichiers de production modifiés : les 4 listés ci-dessus, rien d'autre. `cmp` sur
  `MurmureCore/Package.swift` : identique à `t_d1dbdc77` (transport, pas écriture).
- `project.yml` : `279d0a48`, jamais réécrit.
- HEAD `8117857`, aucun commit (interdit par la carte).

## 3. Preuves rejouées par la revue (sur les octets courants)

- `bash scripts/checks/control-startup-contract.sh wire` → **CONTRÔLE=49/49, VERT contrôle=11-S**.
  `FINDER status rc=0`, `FINDER transcribe rc=0` (couverture 0.9663472928422587),
  `finder-transcript-on-disk` et `finder-transcript-has-text` verts,
  `finder-status-settles` vert, refus socket absent `rc=3`, `TeamIdentifier` non `not set`
  (le bundle est signé par identité — préalable du plan r. 22).
- `swift test` (MurmureCore) → **1655 tests, 0 échec**, rc=0.
- Mutants joués un par un : `mutant-sous-dossier-video` **capturé** (rc=1 sur son unique
  contrôle nommé), ce qui confirme que le contrôle `video-compute-not-dedicated` est
  lui-même discriminant.

## 4. O1 (non bloquant, pour `t_aeb3aea0`) — trois mutants inopérants, REPRODUIT

`mutant-dedicated-compute`, `mutant-dedicated-compute-multiligne` et
`mutant-default-dedicated` sortent tous trois **rc=3 « MUTANT NON capturé »**, 28/28 verts.
Constat du DEV, confirmé et expliqué : ces trois mutants mutent `$work/pane.swift`
(ou `engine.swift`) **en place**, or `run_graph` (l. 296-301) ne repasse par aucun
localisateur `MURMURE_STARTUP_PANE` — le contrôle relit le vrai panneau de `TEST_ROOT`.

Ce n'est pas un contrôle mort : la sonde du DEV le prouve, et je l'ai rejouée dans un
autre sens — `MURMURE_STARTUP_ROOT=<copie de l'arbre, dedicatingComputeUnits: true>`
donne ROUGE sur `video-compute-not-dedicated`. Le défaut est dans le harnais des mutants,
pas dans le contrôle ni dans le code de production. Le script appartient à `t_aeb3aea0`,
la carte interdit d'y toucher : **signalé, pas absorbé**.

Écart de décompte à signaler aussi : la revue QA r7 annonce 20/20 mutants capturés, mes
mesure sur le même script (sha256 `ac79a43d…`, identique à `t_aeb3aea0`) donne 3 non
capturés. Les deux constats ne peuvent pas être vrais sur le même fichier.

## 5. O2 (NON BLOQUANT, mais régression réelle et SANS PROPRIÉTAIRE) — `preparation` n'est plus alimentée

`TranscriptsPaneModel.preparation` n'est plus affectée que de `nil`
(l. 635 et 709 ; la base `t_7785056d` avait `self?.preparation = etat` en l. 689).
La phrase `StatusPanelText.label(for: .preparingModel(…))` de `MurmureApp.swift:370-371`
ne s'affichera donc plus pendant une **première transcription vidéo** — le cas exact
qu'elle existe pour (« un téléchargement de 1,6 Go sans nombre ressemble exactement à un
blocage »). La barre indéterminée, elle, reste (`isWorking`).

Pourquoi ce n'est pas bloquant ici : aucun des cinq critères du §4 ne la mentionne, la
ligne 53 de la SPEC n'exige qu'« une barre de progression » — toujours là — et le
commentaire de la barre (l. 366-368) reste exact pour ce qui est encore vrai. La
correction demandait une seconde surface d'observation sur le moteur de la dictée, ce
qui sort du périmètre décrit par la carte ; le DEV l'a signalée sans l'absorber, ce qui
est le comportement correct.

Mais « signalée » ne suffit pas si personne ne la porte : aucune carte du board ne
mentionne `preparation` ni `preparingModel`. Je crée donc une carte de suivi dédiée
plutôt que de la laisser tomber.

## 6. Ce que je n'ai pas rejoué

- La construction Release elle-même est un SegmentRepeated de la gate (l. ~300 du script) :
  rejouée dans le cadre du `wire`, pas isolément.
- `control-queue-wiring.sh` (21/21) et `control-queue-wiring-tige.sh` (5/5) : affirmés par
  le DEV, non rejoués par moi — ils portent le contrat 10-S/10-S-R, hors du diff de 11-S,
  et la suite complète (1655/0) couvre le cœur.
