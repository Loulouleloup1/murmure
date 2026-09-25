import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 10 : **la file d'attente des travaux vidéo** (critère 19) et **ses
/// libellés de progression** (critère 18, côté testable). Plan §4 lot 10, §2.7, §7.1.
///
/// Ce que ces tests protègent :
/// - **critère 19** — « trois liens ajoutés à la suite sont traités séquentiellement, dans
///   l'ordre » : les cas ci-dessous observent le **journal réel** des appels du travail, pas
///   l'ordre que la file prétend avoir. C'est la seule forme sous laquelle ce critère est
///   vérifiable : la politique de file est dans le cœur, le travail (acquérir, décoder,
///   transcrire) est dans `Murmure/`, qui n'a pas de bundle de tests ;
/// - **critère 18, côté libellés** — la barre de progression et la ligne de la file disent ce
///   qu'elles prétendent dire (motif `StatusPanelText`, dans le cœur pour cette raison) ;
/// - les trois cas **obligatoires** de la carte : trois liens séquentiels et ordonnés, un élément
///   en échec qui n'arrête pas la file, une annulation qui ne réordonne pas les suivants.
///
/// Ce que ces tests ne font pas : ils ne dessinent rien, n'écrivent rien sur disque, ne
/// téléchargent rien et ne lancent aucune notification. Le travail injecté est une closure de
/// test ; la notification macOS et la pastille sont dans `Murmure/` (carte dev).
///
/// **Aucun cas ne peut bloquer la suite de tests** : les attentes sont bornées
/// (``attendreCondition(_:limite:_:)``), parce qu'une file non implémentée n'appelle aucun
/// travail — une attente sans limite resterait suspendue et `swift test` ne rendrait jamais la
/// main au lieu d'échouer (règle 11 du §7.1).
///
/// Tous les cas ci-dessous échouent sur une **assertion explicite** — jamais sur une erreur de
/// compilation, ni sur un arrêt brutal — tant que les corps sentinelles de `TranscriptQueue.swift`
/// n'ont pas été remplacés. Aucun tableau issu de la file n'est indexé : un index hors bornes
/// ferait tomber tout le binaire de tests et masquerait les autres résultats. Et aucun `await` ne
/// vit dans une assertion : `XCTAssert*` prend une autoclosure, qui n'accepte pas la concurrence —
/// les valeurs attendues sont donc lues dans des locales **avant** d'être comparées.
final class TranscriptQueueTests: XCTestCase {
    /// Ce que porte chaque assertion rouge d'aujourd'hui.
    private let contrat = "contrat lot 10 : non implémenté"

    // MARK: - Critère 19 : séquentiel, dans l'ordre

    /// **Le cas obligatoire de la carte, et le critère 19 lui-même.** Trois liens ajoutés à la
    /// suite : la file les traite **un par un**, dans l'ordre d'ajout, et jamais deux en parallèle.
    ///
    /// Le travail journalise son entrée **avec l'état de l'élément qu'il reçoit** : c'est ce qui
    /// rend observable le passage `waiting` → `running`. Il tient ensuite son entrée pendant 1 ms :
    /// trois travaux instantanés ne se chevaucheraient jamais, même sur une file parallèle, donc
    /// une file qui lancerait les trois `Job` en même temps passerait ce test par accident si le
    /// travail n'avait aucune durée. `maximumSimultane` est le témoin de « jamais deux travaux
    /// vidéo en parallèle ».
    func testCriterion19ThreeLinksAddedInARowRunOneAtATimeInTheOrderTheyWereAdded() async {
        let journal = JournalDesTravaux()
        let file = TranscriptQueue { entree in
            journal.entrer("debut \(entree.source) etat \(entree.state.rawValue)")
            try? await Task.sleep(nanoseconds: 1_000_000)
            journal.sortir()
        }

        let premier = await file.enqueue(source: lienVideo(1))
        await file.enqueue(source: lienVideo(2))
        await file.enqueue(source: lienVideo(3))

        XCTAssertEqual(premier.source, lienVideo(1), contrat)
        XCTAssertEqual(premier.state, .waiting, "un élément ajouté attend — \(contrat)")
        XCTAssertFalse(
            premier.id.isEmpty, "un élément porte une identité d'affichage — \(contrat)")

        let sources = await file.entries.map(\.source)
        XCTAssertEqual(
            sources, [lienVideo(1), lienVideo(2), lienVideo(3)],
            "la file garde l'ordre d'ajout — \(contrat)")
        let enAttente = await file.waiting.map(\.source)
        XCTAssertEqual(
            enAttente, [lienVideo(1), lienVideo(2), lienVideo(3)],
            "rien n'a commencé avant `drain()` — \(contrat)")
        let auRepos = await file.running
        XCTAssertNil(auRepos, contrat)
        XCTAssertEqual(
            journal.contenu, [], "l'ajout ne démarre aucun travail ; c'est `drain()` — \(contrat)")

        await file.drain()

        XCTAssertEqual(
            journal.contenu,
            [
                "debut \(lienVideo(1)) etat running", "debut \(lienVideo(2)) etat running",
                "debut \(lienVideo(3)) etat running",
            ],
            "trois liens ajoutés à la suite sont traités séquentiellement, dans l'ordre — \(contrat)")
        XCTAssertEqual(
            journal.maximumSimultane, 1, "jamais deux travaux vidéo en parallèle — \(contrat)")

        let etats = await file.entries.map(\.state)
        XCTAssertEqual(etats, [.done, .done, .done], "chaque élément finit en `done` — \(contrat)")
        let reste = await file.waiting
        XCTAssertEqual(reste, [], contrat)
        let encoreEnCours = await file.running
        XCTAssertNil(encoreEnCours, contrat)
        let identifiants = await file.entries.map(\.id)
        XCTAssertEqual(
            Set(identifiants).count, 3, "trois identités distinctes dans une même file — \(contrat)")
    }

    /// Un travail **ajouté pendant qu'un autre tourne** attend son tour et garde sa place : c'est
    /// la bande de recouvrement du critère 19, celle où une file naïve lancerait le nouveau lien
    /// tout de suite.
    func testAJobAddedWhileAnotherIsRunningWaitsAndKeepsItsPlace() async {
        let journal = JournalDesTravaux()
        let demarre = Porte()
        let finDuPremier = Porte()
        let file = TranscriptQueue { entree in
            journal.entrer("debut \(entree.source)")
            if entree.source == lienVideo(1) {
                demarre.ouvrir()
                await finDuPremier.attendre()
            }
            journal.sortir()
            journal.entrer("fin \(entree.source)")
        }

        await file.enqueue(source: lienVideo(1))
        let tache = Task { await file.drain() }

        let premierDemarre = await attendreCondition("le premier lien doit être traité") {
            journal.contenu.contains("debut \(lienVideo(1))")
        }
        XCTAssertTrue(premierDemarre, "le premier lien doit être traité — \(contrat)")

        let enCours = await file.running
        XCTAssertEqual(
            enCours?.source, lienVideo(1), "le travail en cours est le premier — \(contrat)")
        XCTAssertEqual(enCours?.state, .running, contrat)
        XCTAssertEqual(
            journal.contenu, ["debut \(lienVideo(1))"],
            "un second travail ne démarre pas tant que le premier tourne — \(contrat)")

        // Ajouté **pendant** que le premier tourne.
        await file.enqueue(source: lienVideo(2))
        let enAttente = await file.waiting.map(\.source)
        XCTAssertEqual(
            enAttente, [lienVideo(2)],
            "un lien ajouté pendant un travail attend — \(contrat)")

        finDuPremier.ouvrir()
        await tache.value

        XCTAssertEqual(
            journal.contenu,
            [
                "debut \(lienVideo(1))", "fin \(lienVideo(1))", "debut \(lienVideo(2))",
                "fin \(lienVideo(2))",
            ],
            "l'ordre d'ajout est l'ordre d'exécution — \(contrat)")
        let etats = await file.entries.map(\.state)
        XCTAssertEqual(etats, [.done, .done], contrat)
    }

    /// **Cas obligatoire : un élément en échec n'arrête pas la file.** Le deuxième lien échoue,
    /// le troisième part quand même, dans l'ordre — et la raison de l'échec est conservée, sinon
    /// le panneau afficherait un état sans cause (règle 5 du contrat).
    func testAFailedJobDoesNotStopTheQueue() async {
        let journal = JournalDesTravaux()
        let file = TranscriptQueue { entree in
            journal.entrer("debut \(entree.source)")
            try? await Task.sleep(nanoseconds: 1_000_000)
            journal.sortir()
            if entree.source == lienVideo(2) {
                throw EchecDuTravail(message: "yt-dlp exited with status 403")
            }
        }

        await file.enqueue(source: lienVideo(1))
        await file.enqueue(source: lienVideo(2))
        await file.enqueue(source: lienVideo(3))
        await file.drain()

        XCTAssertEqual(
            journal.contenu,
            ["debut \(lienVideo(1))", "debut \(lienVideo(2))", "debut \(lienVideo(3))"],
            "les trois liens sont traités, l'échec du deuxième n'arrête pas la file — \(contrat)")
        XCTAssertEqual(journal.maximumSimultane, 1, contrat)

        let entrees = await file.entries
        XCTAssertEqual(
            entrees.map(\.state), [.done, .failed, .done],
            "un échec n'arrête pas la file — \(contrat)")
        let echoue = entrees.first { $0.source == lienVideo(2) }
        XCTAssertEqual(
            echoue?.error, "yt-dlp exited with status 403",
            "la raison de l'échec est conservée telle que le travail l'a donnée — \(contrat)")
    }

    /// **Cas obligatoire : l'annulation du travail en cours ne réordonne pas les suivants.**
    ///
    /// L'annulation est réelle, pas déclarative : `cancelCurrent()` doit annuler la tâche du
    /// travail (règle 6), et c'est ce que le travail observe avec `Task.isCancelled` — le travail
    /// ci-dessous ne se termine pas « en succès » quand il est annulé. L'élément annulé devient
    /// `failed` **sans raison** (il n'a pas de cause à montrer : c'est Louis qui l'a arrêté), et
    /// les deux suivants partent dans l'ordre d'ajout.
    func testCancellingTheRunningJobDoesNotReorderTheFollowingOnes() async {
        let journal = JournalDesTravaux()
        let demarre = Porte()
        let finDuPremier = Porte()
        let file = TranscriptQueue { entree in
            journal.entrer("debut \(entree.source)")
            if entree.source == lienVideo(1) {
                demarre.ouvrir()
                await finDuPremier.attendre()
                journal.sortir()
                if Task.isCancelled {
                    throw CancellationError()
                }
                journal.entrer("fin \(entree.source)")
                return
            }
            journal.sortir()
            journal.entrer("fin \(entree.source)")
        }

        await file.enqueue(source: lienVideo(1))
        await file.enqueue(source: lienVideo(2))
        await file.enqueue(source: lienVideo(3))
        let tache = Task { await file.drain() }

        let premierDemarre = await attendreCondition("le premier lien doit être traité") {
            journal.contenu.contains("debut \(lienVideo(1))")
        }
        XCTAssertTrue(premierDemarre, "le premier lien doit être traité — \(contrat)")

        await file.cancelCurrent()
        finDuPremier.ouvrir()
        await tache.value

        XCTAssertEqual(
            journal.contenu.filter { $0.hasPrefix("debut") },
            ["debut \(lienVideo(1))", "debut \(lienVideo(2))", "debut \(lienVideo(3))"],
            "l'annulation du travail en cours ne réordonne pas les suivants — \(contrat)")
        XCTAssertFalse(
            journal.contenu.contains("fin \(lienVideo(1))"),
            "un travail annulé ne se termine pas comme un succès — \(contrat)")

        let entrees = await file.entries
        XCTAssertEqual(entrees.map(\.state), [.failed, .done, .done], contrat)
        let annule = entrees.first { $0.source == lienVideo(1) }
        XCTAssertEqual(annule?.state, .failed, contrat)
        XCTAssertNil(
            annule?.error,
            "une annulation n'a pas de raison : c'est un arrêt de Louis, pas un défaut du média — \(contrat)")
    }

    /// **Un élément terminé ne tourne plus jamais, et un second `drain()` ne démarre rien.**
    ///
    /// Deux règles distinctes, vérifiées ensemble : l'élément fini est **retiré de la file**
    /// (règle 3), et un `drain()` appelé pendant qu'un autre tourne **rend la main immédiatement
    /// sans démarrer de travail** (règle 4) — deux `drain()` simultanés donneraient deux travaux
    /// vidéo en parallèle, et un appelant qui attendrait la fin du travail en cours ferait de la
    /// surface d'appel un piège.
    func testFinishedEntriesAreNeverReplayedAndASecondDrainStartsNothing() async {
        let journal = JournalDesTravaux()
        let demarre = Porte()
        let finDuPremier = Porte()
        let file = TranscriptQueue { entree in
            journal.entrer("debut \(entree.source)")
            if entree.source == lienVideo(1) {
                demarre.ouvrir()
                await finDuPremier.attendre()
            }
            journal.sortir()
        }

        await file.enqueue(source: lienVideo(1))
        await file.enqueue(source: lienVideo(2))
        let premiere = Task { await file.drain() }

        let premierDemarre = await attendreCondition("le premier lien doit être traité") {
            journal.contenu.contains("debut \(lienVideo(1))")
        }
        XCTAssertTrue(premierDemarre, "le premier lien doit être traité — \(contrat)")

        await file.drain()
        XCTAssertEqual(
            journal.contenu, ["debut \(lienVideo(1))"],
            "un `drain()` pendant qu'un autre tourne ne démarre rien et rend la main — \(contrat)")

        finDuPremier.ouvrir()
        await premiere.value
        XCTAssertEqual(
            journal.contenu, ["debut \(lienVideo(1))", "debut \(lienVideo(2))"],
            "la file reprend ce qui attend, dans l'ordre — \(contrat)")

        await file.drain()
        XCTAssertEqual(
            journal.contenu, ["debut \(lienVideo(1))", "debut \(lienVideo(2))"],
            "un élément terminé est retiré de la file et n'est jamais rejoué — \(contrat)")
        let etats = await file.entries.map(\.state)
        XCTAssertEqual(etats, [.done, .done], contrat)
    }

    /// **Cas limite : la file vide.** Un `drain()` sur une file vide n'appelle aucun travail et
    /// rend la main — et la file reste utilisable : c'est le contrôle positif qui rend ce cas
    /// vérifiable, puisque « aucun travail n'a tourné » serait vrai d'une file qui ne marche pas
    /// du tout.
    func testAnEmptyQueueDoesNothingAndStillRunsWhatIsAddedAfterwards() async {
        let journal = JournalDesTravaux()
        let file = TranscriptQueue { entree in
            journal.entrer("debut \(entree.source)")
        }

        let vide = await file.entries
        XCTAssertEqual(vide, [], contrat)
        let enAttente = await file.waiting
        XCTAssertEqual(enAttente, [], contrat)
        let auRepos = await file.running
        XCTAssertNil(auRepos, contrat)

        await file.drain()
        XCTAssertEqual(journal.contenu, [], "une file vide n'appelle aucun travail — \(contrat)")

        await file.enqueue(source: lienVideo(1))
        await file.drain()
        XCTAssertEqual(
            journal.contenu, ["debut \(lienVideo(1))"], "la file repart après un drain vide — \(contrat)")
    }

    // MARK: - Critère 18, côté libellés

    /// **Chaque état a sa phrase, en anglais, et aucune ne se lit à la place d'une autre.**
    ///
    /// Une phrase muette est une barre de progression qui ne dit rien ; deux états qui se lisent
    /// pareil sont un mensonge affiché au seul endroit où Louis regarde — l'argument que
    /// `StatusPanelText` fait déjà pour les phases de la dictée.
    func testEveryQueueStateHasItsOwnSentenceInEnglish() {
        let attente = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "1", source: lienVideo(1), state: .waiting))
        let enCours = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "2", source: lienVideo(1), state: .running))
        let fini = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "3", source: lienVideo(1), state: .done))
        let annule = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "4", source: lienVideo(1), state: .failed))
        let echoue = TranscriptQueueText.label(
            for: TranscriptQueueEntry(
                id: "5", source: lienVideo(1), state: .failed, error: "yt-dlp exited with status 403"))
        let phrases = [attente, enCours, fini, annule, echoue]

        for phrase in phrases {
            XCTAssertFalse(
                phrase.trimmingCharacters(in: .whitespaces).isEmpty,
                "\"\(phrase)\" ne dit rien à celui qui lit la file — \(contrat)")
        }
        let lettresFrancaises = CharacterSet(charactersIn: "éèêëàâùûüçîïôöÉÈÊÀÙÇÎÔ")
        for phrase in phrases {
            XCTAssertNil(
                phrase.rangeOfCharacter(from: lettresFrancaises),
                "\"\(phrase)\" n'est pas dans la langue du reste de l'interface — \(contrat)")
        }
        XCTAssertEqual(
            Set(phrases).count, 5,
            "cinq lignes distinctes : les quatre états, et l'échec qui porte sa raison — \(contrat)")
        XCTAssertNotEqual(attente, enCours, contrat)
    }

    /// **Le travail en cours dit le mot de la dictée**, et une annulation dit le mot des deux
    /// autres surfaces qui la montrent. Deux mots pour la même chose sont une différence que Louis
    /// devrait apprendre pour rien : transcrire une vidéo et dicter sont la même activité, et
    /// `StatusPanelText` porte déjà ces deux mots.
    func testTheRunningAndCancelledLabelsUseTheWordsTheOtherSurfacesAlreadyShow() {
        let enCours = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "1", source: lienVideo(1), state: .running))
        XCTAssertEqual(
            enCours, StatusPanelText.label(for: .transcribing),
            "le travail en cours dit le mot de la dictée — \(contrat)")

        let annule = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "2", source: lienVideo(1), state: .failed))
        XCTAssertEqual(
            annule, StatusPanelText.label(for: .cancelled),
            "une annulation dit le mot déjà employé ailleurs — \(contrat)")
    }

    /// **L'échec porte sa raison** : un état sans cause renverrait Louis au journal d'un travail
    /// lancé la veille, ce que `AcquisitionDiagnostics` existe précisément pour éviter.
    func testAFailedEntryShowsTheReasonItFailedWith() {
        let raison = "yt-dlp exited with status 403"
        let phrase = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "1", source: lienVideo(1), state: .failed, error: raison))
        XCTAssertEqual(phrase, "Failed: \(raison)", contrat)

        let sansRaison = TranscriptQueueText.label(
            for: TranscriptQueueEntry(id: "2", source: lienVideo(1), state: .failed, error: ""))
        XCTAssertFalse(sansRaison.isEmpty, "un échec sans raison se dit quand même — \(contrat)")
    }
}

// MARK: - Lot 10-S : une seule file, des attentes attachées aux identifiants

/// Contrat d'acceptation du raccordement panel/socket. Les régressions du lot 10 restent
/// ci-dessus, intactes. Ces cas n'importent pas `Murmure/` : le comportement de file est
/// exercé ici, tandis que le script ciblé observe le graphe applicatif.
final class TranscriptQueueSharedContractTests: XCTestCase {
    private let contrat = "contrat rouge 10-S : couture ou attente commune absente"

    func testCriterion1PanelThenSocketSubmissionsUseTheSameFIFOAndNeverOverlap() async {
        let journal = JournalPartage()
        let file = TranscriptQueue { entree in
            journal.debut(entree.source)
            try await Task.sleep(nanoseconds: 1_000_000)
            journal.fin(entree.source)
        }

        let panel = await file.enqueue(source: "panel-1")
        let socket = await file.enqueue(source: "socket-1")
        let secondPanel = await file.enqueue(source: "panel-2")
        await file.drain()

        let ordre = journal.evenements
        XCTAssertEqual(
            ordre,
            ["debut panel-1", "fin panel-1", "debut socket-1", "fin socket-1",
             "debut panel-2", "fin panel-2"],
            "panel puis socket doivent traverser la même FIFO — \(contrat)")
        XCTAssertEqual(journal.maximumSimultane, 1, "zéro travail concurrent — \(contrat)")
        let ids = [panel.id, socket.id, secondPanel.id]
        XCTAssertEqual(Set(ids).count, 3, "chaque soumission a son identité — \(contrat)")
        assertContratDansSource(
            "MurmureCore/Sources/MurmureCore/TranscriptQueue.swift",
            #"func\s+wait\s*\(\s*for\s+id\s*:\s*String"#,
            "la file expose l'attente par identifiant")
    }

    func testCriterion2ConcurrentWaitsReturnTheResultAttachedToTheirOwnID() async throws {
        let file = TranscriptQueue { entree in
            if entree.source == "first" {
                try await Task.sleep(nanoseconds: 2_000_000)
            } else {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let first = await file.enqueue(source: "first")
        let second = await file.enqueue(source: "second")

        async let waitFirst = attendreTerminal(file: file, id: first.id)
        async let waitSecond = attendreTerminal(file: file, id: second.id)
        let drainage = Task { await file.drain() }
        let resultats = try await (waitFirst, waitSecond)
        await drainage.value

        XCTAssertEqual(resultats.0.source, "first", "la première attente garde son id — \(contrat)")
        XCTAssertEqual(resultats.1.source, "second", "la seconde attente garde son id — \(contrat)")
        XCTAssertEqual(resultats.0.id, first.id, "aucun résultat d'un autre travail — \(contrat)")
        XCTAssertEqual(resultats.1.id, second.id, "aucun résultat d'un autre travail — \(contrat)")
        assertContratDansSource(
            "MurmureCore/Sources/MurmureCore/TranscriptQueue.swift",
            #"TranscriptQueueOutcome|Checkpoints|CheckedContinuation"#,
            "les résultats sont conservés et rendus au bon identifiant")
    }

    func testCriterion3FailureIsTerminalForItsWaitThenTheNextEntryStarts() async throws {
        let journal = JournalPartage()
        let file = TranscriptQueue { entree in
            journal.debut(entree.source)
            if entree.source == "failed" { throw EchecPartage(message: "fixture failed") }
            journal.fin(entree.source)
        }
        let failed = await file.enqueue(source: "failed")
        let next = await file.enqueue(source: "next")
        let attente = Task { try await attendreTerminal(file: file, id: failed.id) }
        await file.drain()
        let issue = try await attente.value
        let nextIssue = try await attendreTerminal(file: file, id: next.id)

        XCTAssertEqual(issue.state, .failed, "l'échec termine l'attente visée — \(contrat)")
        XCTAssertEqual(issue.error, "fixture failed", "l'erreur reste attachée à son id — \(contrat)")
        XCTAssertEqual(nextIssue.state, .done, "le suivant démarre après l'échec — \(contrat)")
        XCTAssertEqual(
            journal.evenements, ["debut failed", "debut next", "fin next"],
            "l'échec n'arrête pas la file — \(contrat)")
        assertContratDansSource(
            "MurmureCore/Sources/MurmureCore/TranscriptQueue.swift",
            #"func\s+wait\s*\(\s*for\s+id\s*:\s*String"#,
            "l'échec termine l'attente de cette entrée")
    }

    func testCriterion4CancellationTerminatesItsOwnWaitAndDoesNotStrandTheNextEntry() async throws {
        let started = PortePartage()
        let finish = PortePartage()
        let journal = JournalPartage()
        let file = TranscriptQueue { entree in
            journal.debut(entree.source)
            if entree.source == "cancelled" {
                started.open()
                await finish.wait()
                if Task.isCancelled { throw CancellationError() }
            }
            journal.fin(entree.source)
        }
        let cancelled = await file.enqueue(source: "cancelled")
        let next = await file.enqueue(source: "next")
        let attente = Task { try await attendreTerminal(file: file, id: cancelled.id) }
        let drainage = Task { await file.drain() }
        let startedSuccessfully = await attendreCondition("le travail démarre") {
            journal.evenements.contains("debut cancelled")
        }
        XCTAssertTrue(startedSuccessfully, "le travail doit démarrer — \(contrat)")

        await file.cancelCurrent()
        finish.open()
        let issue = try await attente.value
        await drainage.value
        let suivant = try await attendreTerminal(file: file, id: next.id)

        XCTAssertEqual(issue.state, .failed, "l'annulation est terminale — \(contrat)")
        XCTAssertNil(issue.error, "l'annulation n'invente pas de raison — \(contrat)")
        XCTAssertEqual(suivant.state, .done, "le suivant n'est pas perdu — \(contrat)")
        assertContratDansSource(
            "MurmureCore/Sources/MurmureCore/TranscriptQueue.swift",
            #"func\s+wait\s*\(\s*for\s+id\s*:\s*String"#,
            "l'annulation termine l'attente de cette entrée")
    }

    func testCriterion5StatusIsExactlyIdleRunningOrWaitingAndNeverLeaksSourceOrTranscript() throws {
        let file = try String(
            contentsOf: racine(for: "MurmureCore/Sources/MurmureCore/TranscriptQueue.swift"),
            encoding: .utf8)
        let serveur = try String(
            contentsOf: racine(for: "Murmure/TranscriptControlServer.swift"), encoding: .utf8)

        let formesAttendues = [
            "idle",
            "running <source>, <count> waiting",
            "idle, <count> waiting",
        ]
        for forme in formesAttendues {
            XCTAssertTrue(
                file.contains(forme) || serveur.contains(forme),
                "la forme exacte \(forme) doit exister — \(contrat)")
        }
        XCTAssertTrue(
            file.range(of: #"(?:public\s+)?var\s+status\s*:\s*String"#,
                options: .regularExpression) != nil,
            "le statut commun est calculé par la file — \(contrat)")
        XCTAssertTrue(
            serveur.range(of: #"statusProvider\s*\(\s*\)"#,
                options: .regularExpression) != nil,
            "status appelle le provider injecté — \(contrat)")
        let statusCalls = serveur.matches(of: #"statusProvider\s*\(\s*\)"#).count
        XCTAssertGreaterThanOrEqual(statusCalls, 1, "le socket ne fabrique aucun statut — \(contrat)")
        XCTAssertFalse(
            serveur.range(of: #"logger\.(?:debug|info|notice|warning|error).*?(?:source|transcript|segment)"#,
                options: [.regularExpression, .caseInsensitive]) != nil,
            "status ne journalise ni source ni transcript — \(contrat)")
    }

    func testCriterion6TheCommonQueueNeverRunsDuplicateOrParallelWork() async throws {
        let journal = JournalPartage()
        let started = PortePartage()
        let finish = PortePartage()
        let file = TranscriptQueue { entree in
            journal.debut(entree.source)
            if entree.source == "one" {
                started.open()
                await finish.wait()
            }
            journal.fin(entree.source)
        }
        await file.enqueue(source: "one")
        await file.enqueue(source: "two")
        let firstDrain = Task { await file.drain() }
        let startedSuccessfully = await attendreCondition("le premier travail démarre") {
            journal.debuts.contains("one")
        }
        XCTAssertTrue(startedSuccessfully, "le premier travail doit démarrer — \(contrat)")

        await file.drain()
        XCTAssertEqual(journal.debuts, ["one"], "un second drain ne duplique rien — \(contrat)")
        finish.open()
        await firstDrain.value
        XCTAssertEqual(journal.debuts, ["one", "two"], "chaque entrée part une fois — \(contrat)")
        XCTAssertEqual(journal.maximumSimultane, 1, "zéro travail concurrent — \(contrat)")
        let serveur = try String(
            contentsOf: racine(for: "Murmure/TranscriptControlServer.swift"), encoding: .utf8)
        XCTAssertFalse(
            serveur.contains("ControlJobBoard") || serveur.contains("enchainer"),
            "aucune file secondaire ne double la file commune — \(contrat)")
    }

    private func racine(for relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    private func assertContratDansSource(
        _ relative: String, _ expression: String, _ raison: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let contenu = (try? String(
            contentsOf: racine(for: relative), encoding: .utf8)) ?? ""
        XCTAssertNotNil(
            contenu.range(of: expression, options: .regularExpression),
            "\(raison) — \(contrat)", file: file, line: line)
    }
}

private extension String {
    func matches(of pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return expression.matches(in: self, range: range).compactMap { match in
            Range(match.range, in: self).map { String(self[$0]) }
        }
    }
}

private func attendreTerminal(
    file: TranscriptQueue, id: String, limite: Double = 1
) async throws -> TranscriptQueueEntry {
    let echeance = Date().addingTimeInterval(limite)
    while Date() < echeance {
        if let entry = await file.entries.first(where: { $0.id == id }),
            entry.state == .done || entry.state == .failed
        { return entry }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw EchecPartage(message: "timeout waiting for \(id)")
}

private final class JournalPartage: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var starts: [String] = []
    private var active = 0
    private var maximum = 0
    func debut(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        events.append("debut \(source)"); starts.append(source); active += 1
        maximum = max(maximum, active)
    }
    func fin(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        events.append("fin \(source)"); active -= 1
    }
    var evenements: [String] { lock.lock(); defer { lock.unlock() }; return events }
    var debuts: [String] { lock.lock(); defer { lock.unlock() }; return starts }
    var maximumSimultane: Int { lock.lock(); defer { lock.unlock() }; return maximum }
}

private final class PortePartage: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func open() {
        lock.lock(); opened = true; let waiter = continuation; continuation = nil; lock.unlock()
        waiter?.resume()
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume() }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
}

private struct EchecPartage: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Outils des cas ci-dessus

/// Une adresse de test, pour que les journaux se lisent. Jamais un vrai lien : ces cas ne
/// téléchargent rien.
private func lienVideo(_ numero: Int) -> String {
    "https://videos.example.test/lien-\(numero)"
}

/// L'erreur d'un travail vidéo qui échoue. La file enregistre `localizedDescription`, donc c'est
/// `errorDescription` qui est gelée par les cas ci-dessus.
private struct EchecDuTravail: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Le journal des appels du travail, écrit depuis les tâches du travail et lu depuis le test : ce
/// que ces cas observent est **l'ordre réel** des appels, et le nombre de travaux qui tournent en
/// même temps. Verrouillé, parce que deux tâches peuvent y écrire.
private final class JournalDesTravaux: @unchecked Sendable {
    private let verrou = NSLock()
    private var appels: [String] = []
    private var enCours = 0
    private var maximum = 0

    /// Un travail entre : il est compté comme simultané jusqu'à ``sortir()``.
    func entrer(_ ligne: String) {
        verrou.lock()
        defer { verrou.unlock() }
        appels.append(ligne)
        enCours += 1
        maximum = max(maximum, enCours)
    }

    func sortir() {
        verrou.lock()
        defer { verrou.unlock() }
        enCours -= 1
    }

    var contenu: [String] {
        verrou.lock()
        defer { verrou.unlock() }
        return appels
    }

    /// Le plus grand nombre de travaux qui ont tourné en même temps. Doit valoir 1 : c'est le
    /// témoin « jamais deux travaux vidéo en parallèle ».
    var maximumSimultane: Int {
        verrou.lock()
        defer { verrou.unlock() }
        return maximum
    }
}

/// Une porte à usage unique : `ouvrir()` réveille `attendre()`. C'est ce qui rend ces cas
/// déterministes — l'ordre des étapes est imposé par le test, jamais par une durée.
private final class Porte: @unchecked Sendable {
    private let verrou = NSLock()
    private var suite: CheckedContinuation<Void, Never>?
    private var ouverte = false

    func attendre() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            verrou.lock()
            if ouverte {
                verrou.unlock()
                continuation.resume()
            } else {
                suite = continuation
                verrou.unlock()
            }
        }
    }

    func ouvrir() {
        verrou.lock()
        let aReveiller = suite
        suite = nil
        ouverte = true
        verrou.unlock()
        aReveiller?.resume()
    }
}

/// Attend qu'une condition devienne vraie, **avec une limite** : un rouge ne doit jamais bloquer
/// la suite de tests. Une file non implémentée n'appelle aucun travail, donc une attente sans
/// limite ne rendrait pas la main — et `swift test` resterait suspendu au lieu d'échouer, ce qui
/// serait lu comme un rouge alors que ce serait un binaire qui ne rend pas la main.
private func attendreCondition(
    _ quoi: String, limite: Double = 1, _ condition: () -> Bool
) async -> Bool {
    let echeance = Date().addingTimeInterval(limite)
    while Date() < echeance {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
