# Murmure — application macOS

- Cœur testable : `MurmureCore/`. Câblage de l'application : `Murmure/`.
- Plans et décisions : `docs/plans/` ; design : `docs/design/` ; exigences : `docs/specs/`.
- Vérification canonique : `bash scripts/codex/verify.sh` (suite Swift complète ; logs dans `.codex/workflow-runs/`). Détails et CI : `docs/plans/codex-workflow.md`.
- Diagnostic d'installation en lecture seule : `bash scripts/doctor.sh`. Application stable : `~/Applications/Murmure.app` ; ne pas lancer une seconde copie depuis DerivedData.
- Pour une modification visible : ouvrir l'app, dicter un texte de test, vérifier transcription puis insertion. Une compilation du cœur ne remplace pas ce parcours ; documenter toute autorisation macOS manquante.
- Ne jamais journaliser audio, transcriptions ou données de `~/Library/Application Support/Murmure/`. Les tests doivent utiliser des fixtures isolées, jamais ces données réelles.
- Pas de bootstrap, installation, téléchargement de modèle ni régénération XcodeGen dans une gate automatique. Ces opérations nécessitent un périmètre de tâche explicite.
- Aucun nettoyage automatique du support applicatif, des modèles ou des autorisations utilisateur.
