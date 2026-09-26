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
            return documentFactice()
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
            return documentFactice()
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
            return documentFactice()
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
                return documentFactice()
            }
            journal.sortir()
            journal.entrer("fin \(entree.source)")
            return documentFactice()
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
            return documentFactice()
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
            return documentFactice()
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
            return documentFactice()
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
    }

    func testCriterion2ConcurrentWaitsReturnTheResultAttachedToTheirOwnID() async throws {
        let file = TranscriptQueue { entree in
            if entree.source == "first" {
                try await Task.sleep(nanoseconds: 2_000_000)
            } else {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            return documentFactice()
        }
        let first = await file.enqueue(source: "first")
        let second = await file.enqueue(source: "second")
        let firstEntered = PortePartage()
        let secondEntered = PortePartage()
        let firstReturned = PortePartage()
        let secondReturned = PortePartage()
        let waitFirst = Task {
            firstEntered.open()
            let resultat = try await file.wait(for: first.id)
            firstReturned.open()
            return resultat
        }
        let waitSecond = Task {
            secondEntered.open()
            let resultat = try await file.wait(for: second.id)
            secondReturned.open()
            return resultat
        }
        await firstEntered.wait()
        await secondEntered.wait()

        XCTAssertFalse(firstReturned.estOuverte, "la première attente reste suspendue avant drainage — \(contrat)")
        XCTAssertFalse(secondReturned.estOuverte, "la seconde attente reste suspendue avant drainage — \(contrat)")
        let drainage = Task { await file.drain() }
        let resultats = try await (waitFirst.value, waitSecond.value)
        await drainage.value

        XCTAssertEqual(resultats.0.source, "first", "la première attente garde son id — \(contrat)")
        XCTAssertEqual(resultats.1.source, "second", "la seconde attente garde son id — \(contrat)")
        XCTAssertEqual(resultats.0.id, first.id, "aucun résultat d'un autre travail — \(contrat)")
        XCTAssertEqual(resultats.1.id, second.id, "aucun résultat d'un autre travail — \(contrat)")
        XCTAssertEqual(resultats.0.state, .done, "la première attente se termine avec son résultat — \(contrat)")
        XCTAssertEqual(resultats.1.state, .done, "la seconde attente se termine avec son résultat — \(contrat)")
        XCTAssertTrue(firstReturned.estOuverte, "la première attente retourne après drainage — \(contrat)")
        XCTAssertTrue(secondReturned.estOuverte, "la seconde attente retourne après drainage — \(contrat)")
    }

    func testCriterion3FailureIsTerminalForItsWaitThenTheNextEntryStarts() async throws {
        let journal = JournalPartage()
        let file = TranscriptQueue { entree in
            journal.debut(entree.source)
            if entree.source == "failed" { throw EchecPartage(message: "fixture failed") }
            journal.fin(entree.source)
            return documentFactice()
        }
        let failed = await file.enqueue(source: "failed")
        let next = await file.enqueue(source: "next")
        let waitEntered = PortePartage()
        let attente = Task {
            waitEntered.open()
            return try await file.wait(for: failed.id)
        }
        await waitEntered.wait()
        await file.drain()
        let issue = try await attente.value
        let nextIssue = try await file.wait(for: next.id)

        XCTAssertEqual(issue.id, failed.id, "l'échec termine l'attente visée — \(contrat)")
        XCTAssertEqual(issue.state, .failed, "l'échec est terminal — \(contrat)")
        XCTAssertEqual(issue.error, "fixture failed", "l'erreur reste attachée à son id — \(contrat)")
        XCTAssertEqual(nextIssue.id, next.id, "le suivant garde son identité — \(contrat)")
        XCTAssertEqual(nextIssue.state, .done, "le suivant démarre après l'échec — \(contrat)")
        XCTAssertEqual(
            journal.evenements, ["debut failed", "debut next", "fin next"],
            "l'échec n'arrête pas la file — \(contrat)")
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
            return documentFactice()
        }
        let cancelled = await file.enqueue(source: "cancelled")
        let next = await file.enqueue(source: "next")
        let waitEntered = PortePartage()
        let attente = Task {
            waitEntered.open()
            return try await file.wait(for: cancelled.id)
        }
        await waitEntered.wait()
        let drainage = Task { await file.drain() }
        let startedSuccessfully = await attendreCondition("le travail démarre") {
            journal.evenements.contains("debut cancelled")
        }
        XCTAssertTrue(startedSuccessfully, "le travail doit démarrer — \(contrat)")

        await file.cancelCurrent()
        finish.open()
        let issue = try await attente.value
        await drainage.value
        let suivant = try await file.wait(for: next.id)

        XCTAssertEqual(issue.id, cancelled.id, "l'annulation termine l'attente visée — \(contrat)")
        XCTAssertEqual(issue.state, .failed, "l'annulation est terminale — \(contrat)")
        XCTAssertNil(issue.error, "l'annulation n'invente pas de raison — \(contrat)")
        XCTAssertEqual(suivant.id, next.id, "le suivant garde son identité — \(contrat)")
        XCTAssertEqual(suivant.state, .done, "le suivant n'est pas perdu — \(contrat)")
    }

    func testCriterion5StatusTransitionsExactlyIdleRunningAndWaiting() async throws {
        let started = PortePartage()
        let finish = PortePartage()
        let file = TranscriptQueue { _ in
            started.open()
            await finish.wait()
            return documentFactice()
        }
        let vide = await file.status
        let first = await file.enqueue(source: "first")
        let second = await file.enqueue(source: "second")
        let waiting = await file.status
        let drainage = Task { await file.drain() }
        await started.wait()
        let running = await file.status

        finish.open()
        await drainage.value
        let terminal = await file.status

        XCTAssertEqual(vide, "idle", "une file vide est idle — \(contrat)")
        XCTAssertEqual(waiting, "idle, 2 waiting", "deux attentes sont exactes — \(contrat)")
        XCTAssertEqual(running, "running \(first.source), 1 waiting", "le travail courant est exact — \(contrat)")
        XCTAssertEqual(terminal, "idle", "plus rien à attendre après la terminaison — \(contrat)")
        XCTAssertNotEqual(running, waiting, "le statut suit la transition de la file — \(contrat)")
    }

    func testCriterion6SingleThreadedBaselineRunsTheSubmittedWorkExactlyOnce() async {
        let journal = JournalPartage()
        let file = TranscriptQueue { entree in
            journal.debut(entree.source)
            journal.fin(entree.source)
            return documentFactice()
        }

        await file.enqueue(source: "one")
        await file.drain()

        XCTAssertEqual(
            journal.debuts, ["one"],
            "la ligne de base single-threaded démarre l'entrée soumise une seule fois — \(contrat)")
        XCTAssertEqual(
            journal.evenements, ["debut one", "fin one"],
            "un seul travail, exécuté séquentiellement de bout en bout — \(contrat)")
        XCTAssertEqual(
            journal.maximumSimultane, 1,
            "aucun travail parallèle n'est nécessaire sur la ligne de base — \(contrat)")
    }
}

// MARK: - Lot 10-S-R : le `done` porte la tige du fichier que son travail a écrit

/// Le transport de la tige, vu du seul endroit où il est observable : **l'élément `done` de la
/// file**, et la bibliothèque qui doit pouvoir relire ce que cette tige désigne.
///
/// Ce que ces cas protègent, et qui n'était pas protégé avant :
/// - **un `done` est porteur de sa tige** : `TranscriptQueueEntry.documentID` vaut la tige du
///   **fichier écrit**, et cette tige se relit par `library.transcript(id:)`. Le disque est la
///   vérité (critère 14), donc une tige que personne ne peut relire n'est pas une tige ;
/// - **la tige transportée est celle du fichier, jamais l'identité** de la source. Les deux
///   donnent deux fichiers différents quand la même source est transcrite deux fois
///   (`tige-2026-09-20-1a2b3c4d` et `tige-2026-09-20-1a2b3c4d-2`) : un élément qui porterait
///   l'identité désignerait, une fois sur deux, le **mauvais** fichier — celui de l'autre
///   transcription, au texte différent ;
/// - **une tige n'est annoncée que lorsqu'un fichier existe** : un travail qui jette et une
///   annulation n'ont écrit aucun transcript, donc leur `documentID` reste vide (règle 6 du
///   contrat gelé, et la même honnêteté pour l'échec).
///
/// **Pourquoi le travail écrit pour de vrai, et relit par la bibliothèque.** `TranscriptLibrary.write`
/// **re-dote** le document de la tige qu'**elle** a choisie (`ecrit.id = tige`) : le document
/// construit en mémoire porte donc un `id` que la bibliothèque ne reconnaîtra jamais, et
/// `transcript(id:)` le rend `nil`. Un travail qui rendrait le document d'avant écriture ferait
/// rougir ce contrat **sur une base parfaitement correcte** : c'est ce qui a fait échouer une
/// sonde précédente. Le travail rend donc ce que la bibliothèque **relit**, jamais ce
/// qu'elle a reçu, et jamais un `JSONDecoder` de test qui n'aurait pas sa configuration de dates.
///
/// **Chaque cas négatif est couplé, dans le même test, à un contrôle positif** qui exerce
/// l'implémentation : « une tige vide » serait aussi vrai d'une file qui n'écrit jamais de tige,
/// donc l'affirmation seule ne prouverait rien. Le témoin positif, dans chaque cas, est un autre
/// travail du **même** `drain()` dont la tige est non vide **et relisible par la bibliothèque**.
///
/// Aucun de ces cas n'indexe un tableau issu de la file : un index hors bornes ferait tomber tout
/// le binaire de tests et masquerait les autres résultats.
final class TranscriptQueueTigeDuFichierTests: XCTestCase {
    private let contrat = "contrat 10-S-R : le done ne porte pas la tige du fichier écrit"

    private var espace: URL!
    private var base: URL!

    override func setUpWithError() throws {
        espace = try Self.bacASable("TranscriptQueueTigeDuFichierTests")
        base = espace.appendingPathComponent("Transcripts", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: espace)
    }

    // MARK: - Cas de comportement

    /// **Un travail qui rend un document donne un élément `done` porteur de la tige de ce
    /// document, et cette tige est lisible par `library.transcript(id:)`.**
    ///
    /// C'est le cas central, et il est volontairement écrit en deux temps : d'abord la tige est
    /// comparée à **ce que la bibliothèque a réellement écrit** (l'URL rendue par `write`, dont le
    /// nom de fichier est la tige par construction), puis elle est **relue** par la bibliothèque.
    /// Une assertion qui ne ferait que comparer deux chaînes du même calcul ne prouverait que la
    /// cohérence du calcul, pas le transport.
    func testADoneEntryCarriesTheStemOfTheFileItsJobWroteAndTheLibraryReadsItBack() async throws {
        let disque = DisqueDeTest(base: base)
        let identite = "dQw4w9WgXcQ"
        let fichier = TranscriptQueue { _ in
            try disque.ecrireEtRelire(documentEcrit(identite: identite, titre: "Première transcription"))
        }

        await fichier.enqueue(source: lienVideo(1))
        await fichier.drain()

        let entrees = await fichier.entries
        let fini = entrees.first { $0.state == .done }
        let tige = fini?.documentID ?? ""
        let ecrits = disque.tigesEcrites

        XCTAssertEqual(fini?.source, lienVideo(1), "le travail rendu est bien celui de ce lien — \(contrat)")
        XCTAssertEqual(ecrits.count, 1, "le travail a écrit un fichier, et un seul — \(contrat)")
        XCTAssertFalse(
            tige.isEmpty, "un `done` sans tige est un fichier que personne ne peut relire — \(contrat)")
        XCTAssertEqual(
            tige, ecrits.first ?? "",
            "la tige du `done` est celle du fichier écrit, pas un calcul parallèle — \(contrat)")

        let relu = disque.library.transcript(id: tige)
        XCTAssertNotNil(
            relu, "la tige du `done` doit désigner un fichier que la bibliothèque relit — \(contrat)")
        XCTAssertEqual(
            relu?.id, tige,
            "l'invariant du schéma tient : l'id du document relu EST sa tige — \(contrat)")
        XCTAssertEqual(
            relu?.title, "Première transcription",
            "c'est bien le fichier de ce travail qui est relu — \(contrat)")

        // Le témoin de la ligne suivante : l'identité de la source ne désigne **aucun** fichier.
        // C'est ce qui rend l'égalité « tige = identité » fausse **et observable**, plutôt que
        // simplement discouraged.
        XCTAssertNil(
            disque.library.transcript(id: identite),
            "l'identité de la source ne désigne aucun fichier : la transporter serait une impasse")
        XCTAssertNotEqual(tige, identite, "la tige n'est pas l'identité de la source — \(contrat)")
    }

    /// **Un travail qui jette ne donne pas de tige** — et le travail suivant, dans le **même**
    /// `drain()`, en donne une qui est relisible. Sans ce témoin positif, « `documentID` vide »
    /// serait aussi vrai d'une file qui n'écrit jamais de tige.
    func testAThrowingJobCarriesNoStemWhileTheNextDoneEntryCarriesItsOwn() async throws {
        let disque = DisqueDeTest(base: base)
        let identite = "XyZ0123456_"
        let fichier = TranscriptQueue { entree in
            if entree.source == lienVideo(1) {
                throw EchecDuTravail(message: "yt-dlp exited with status 403")
            }
            return try disque.ecrireEtRelire(documentEcrit(identite: identite, titre: "Seconde transcription"))
        }

        await fichier.enqueue(source: lienVideo(1))
        await fichier.enqueue(source: lienVideo(2))
        await fichier.drain()

        let entrees = await fichier.entries
        let echoue = entrees.first { $0.source == lienVideo(1) }
        let fini = entrees.first { $0.source == lienVideo(2) }

        XCTAssertEqual(echoue?.state, .failed, "le travail qui jette est en échec — \(contrat)")
        XCTAssertEqual(
            echoue?.error, "yt-dlp exited with status 403",
            "la raison de l'échec est conservée telle que le travail l'a donnée — \(contrat)")
        XCTAssertEqual(
            echoue?.documentID, "",
            "un travail qui jette n'a écrit aucun transcript : aucune tige ne peut être annoncée")

        // Contrôle positif, dans le même drainage : la file sait porter une tige quand il y en a une.
        let tigeDuSuivant = fini?.documentID ?? ""
        XCTAssertEqual(fini?.state, .done, "le travail suivant aboutit — \(contrat)")
        XCTAssertFalse(
            tigeDuSuivant.isEmpty,
            "témoin positif : le travail suivant porte une tige — \(contrat)")
        XCTAssertEqual(
            tigeDuSuivant, disque.tigesEcrites.first ?? "",
            "c'est la tige du fichier que CE travail a écrit — \(contrat)")
        XCTAssertNotNil(
            disque.library.transcript(id: tigeDuSuivant),
            "témoin positif : cette tige se relit dans la bibliothèque — \(contrat)")
    }

    /// **Une annulation ne donne pas de tige** (règle 6 du contrat gelé) — et le travail suivant,
    /// annulé ou non, en donne une relisible. L'annulation est **réelle** : `cancelCurrent()`
    /// annule la tâche, le travail observe `Task.isCancelled` et ne rend pas de document.
    func testACancelledJobCarriesNoStemWhileTheFollowingDoneEntryCarriesItsOwn() async throws {
        let disque = DisqueDeTest(base: base)
        let journal = JournalDesTravaux()
        let demarre = Porte()
        let finDuPremier = Porte()
        let fichier = TranscriptQueue { entree in
            journal.entrer("debut \(entree.source)")
            if entree.source == lienVideo(1) {
                demarre.ouvrir()
                await finDuPremier.attendre()
                journal.sortir()
                if Task.isCancelled { throw CancellationError() }
                return try disque.ecrireEtRelire(
                    documentEcrit(identite: "wXyZ9876543", titre: "Jamais transcrite"))
            }
            journal.sortir()
            return try disque.ecrireEtRelire(
                documentEcrit(identite: "0aBcDeFgHiJ", titre: "Après annulation"))
        }

        await fichier.enqueue(source: lienVideo(1))
        await fichier.enqueue(source: lienVideo(2))
        let drainage = Task { await fichier.drain() }
        let premierDemarre = await attendreCondition("le premier lien doit être traité") {
            journal.contenu.contains("debut \(lienVideo(1))")
        }
        XCTAssertTrue(premierDemarre, "le premier lien doit être traité — \(contrat)")

        await fichier.cancelCurrent()
        finDuPremier.ouvrir()
        await drainage.value

        let entrees = await fichier.entries
        let annule = entrees.first { $0.source == lienVideo(1) }
        let suivant = entrees.first { $0.source == lienVideo(2) }

        XCTAssertEqual(annule?.state, .failed, "une annulation est un `failed` — \(contrat)")
        XCTAssertNil(
            annule?.error, "une annulation n'a pas de raison : c'est un arrêt de Louis — \(contrat)")
        XCTAssertEqual(
            annule?.documentID, "",
            "un travail annulé n'a écrit aucun transcript : annoncer une tige serait un mensonge")
        XCTAssertEqual(
            disque.tigesEcrites.count, 1,
            "seul le travail non annulé a écrit un fichier — \(contrat)")

        // Contrôle positif, dans le même drainage.
        let tigeDuSuivant = suivant?.documentID ?? ""
        XCTAssertEqual(suivant?.state, .done, "le suivant n'est pas arrêté par l'annulation — \(contrat)")
        XCTAssertFalse(
            tigeDuSuivant.isEmpty, "témoin positif : le suivant porte une tige — \(contrat)")
        XCTAssertNotNil(
            disque.library.transcript(id: tigeDuSuivant),
            "témoin positif : cette tige se relit dans la bibliothèque — \(contrat)")
    }

    /// **Le `documentID` rapporté est la tige du fichier écrit, jamais l'identité** — et cette
    /// assertion **échoue** si on lui donne l'identité.
    ///
    /// La forme qui rend la différence observable : **deux écritures de la même source**, avec le
    /// **même titre, la même date et la même identité** — donc la bibliothèque leur donne **deux
    /// tiges distinctes** : la tige de base, puis la même tige suffixée `-2` (règle 3 des
    /// collisions, `TranscriptLibrary.write`). Les deux fichiers ne se distinguent alors que par
    /// leur **contenu**, pas par leur nom.
    ///
    /// C'est ce dosage qui sépare les trois possibilités :
    /// - si `drain()` écrit **l'identité**, les deux `documentID` valent la même chose et ne
    ///   désignent **aucun** fichier ;
    /// - si `drain()` **re-dérive** la tige au lieu de transporter celle du document rendu, il
    ///   retrouve le **nom** de la première écriture pour les deux — et le second `done` pointe
    ///   alors le **mauvais fichier**, dont le texte le prouve ;
    /// - si `drain()` transporte la tige, la seconde vaut le nom **suffixé**, et `transcript(id:)`
    ///   rend à chaque fois le document au **bon** texte.
    ///
    /// **Pourquoi le même titre est indispensable.** Avec deux titres différents, les deux tiges
    /// diffèrent déjà par le slug et aucune collision n'a lieu : une re-dérivation calculerait le
    /// bon nom par hasard, et le cas serait **vert sur une base fausse** — c'est mesuré, sur la
    /// première rédaction de ce cas. C'est le `-2` qui rend le second nom **indéductible** du
    /// premier.
    func testTwoWritesOfTheSameSourceReportTwoDistinctStemsAndEachIsTheOneItWrote() async throws {
        let disque = DisqueDeTest(base: base)
        let identite = "mNopQrStUvW"
        let titre = "Même source, deux fois"
        let fichier = TranscriptQueue { entree in
            let texte = entree.source == lienVideo(1) ? "le premier transcript" : "le second transcript"
            return try disque.ecrireEtRelire(documentEcrit(identite: identite, titre: titre, texte: texte))
        }

        await fichier.enqueue(source: lienVideo(1))
        await fichier.enqueue(source: lienVideo(2))
        await fichier.drain()

        let entrees = await fichier.entries
        let premier = entrees.first { $0.source == lienVideo(1) }?.documentID ?? ""
        let second = entrees.first { $0.source == lienVideo(2) }?.documentID ?? ""
        let ecrits = disque.tigesEcrites

        XCTAssertEqual(ecrits.count, 2, "les deux travaux ont écrit un fichier chacune — \(contrat)")
        XCTAssertNotEqual(
            premier, second,
            "deux écritures de la même source donnent deux tiges distinctes, la seconde suffixée — \(contrat)")
        XCTAssertTrue(
            second.hasSuffix("-2"),
            "la seconde écriture est suffixée par la bibliothèque : « \(second) » — \(contrat)")
        XCTAssertEqual(
            [premier, second], ecrits,
            "chaque `done` rapporte la tige du fichier que SON travail a écrit, dans l'ordre — \(contrat)")
        XCTAssertNotEqual(premier, identite, "la tige n'est pas l'identité de la source — \(contrat)")
        XCTAssertNotEqual(second, identite, "la tige n'est pas l'identité de la source — \(contrat)")

        // Le contenu est le seul juge : les deux fichiers portent le même titre, donc seul le
        // segment les distingue. Une re-dérivation de la tige ferait lire « le premier
        // transcript » deux fois — c'est ce que ces deux assertions distinguent.
        let texteDuPremier = disque.library.transcript(id: premier)?.segments.first?.text
        let texteDuSecond = disque.library.transcript(id: second)?.segments.first?.text
        XCTAssertEqual(
            texteDuPremier, "le premier transcript",
            "la première tige relit le PREMIER fichier : le bon, pas celui de l'autre travail — \(contrat)")
        XCTAssertEqual(
            texteDuSecond, "le second transcript",
            "la seconde tige relit le SECOND fichier : une re-dérivation la ferait pointer sur le premier — \(contrat)")
    }

    // MARK: - Outils

    /// Le seul endroit du fichier qui nomme un dossier : tout vit sous `NSTemporaryDirectory()`.
    /// Ni `Application Support/Murmure/Transcripts`, ni `Documents` — ces cas n'écrivent que dans
    /// une base injectée, comme la bibliothèque l'est dans l'application.
    private static func bacASable(_ nom: String) throws -> URL {
        let temporaire = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let racine = temporaire.appendingPathComponent("\(nom)-\(UUID().uuidString)", isDirectory: true)
        precondition(
            racine.resolvingSymlinksInPath().path.hasPrefix(temporaire.path),
            "un test de tige ne travaille que sous NSTemporaryDirectory()")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        return racine
    }
}

/// Le disque d'un cas de tige : une bibliothèque isolée, et le **journal des tiges réellement
/// écrites**. C'est ce journal qui donne au test autre chose que ses propres calculs à comparer.
///
/// `@unchecked Sendable` assumé et justifié : `TranscriptLibrary` est une valeur **immuable**
/// (`let base: URL`) et le seul accès au dossier passe par elle ; le verrou protège le tableau
/// des écritures, que deux tâches peuvent alimenter.
private final class DisqueDeTest: @unchecked Sendable {
    private let verrou = NSLock()
    private var ecritures: [String] = []
    let library: TranscriptLibrary

    init(base: URL) {
        library = TranscriptLibrary(base: base)
    }

    /// Écrit par la bibliothèque, puis **relu par elle** : c'est la seule forme qui prouve la tige.
    ///
    /// La relecture passe par ``TranscriptLibrary/transcript(id:)``, jamais par un `JSONDecoder`
    /// écrit ici : le décodeur de la bibliothèque porte sa stratégie de dates ISO-8601, et c'est
    /// elle qui refuse un fichier dont l'`id` n'est pas sa tige — donc c'est elle, et personne
    /// d'autre, qui peut dire si une tige est **la** tige d'un fichier.
    ///
    /// - Throws: `EchecDuTravail` si la bibliothèque ne relit pas ce qu'elle vient d'écrire —
    ///   impossible sur une base correcte, donc le travail échoue et l'entrée est `failed` : le
    ///   cas rouge alors sur son **nom**, jamais sur une panique qui tuerait le binaire.
    func ecrireEtRelire(_ document: TranscriptDocument) throws -> TranscriptDocument {
        let url = try library.write(document)
        let tige = url.deletingPathExtension().lastPathComponent
        guard let relu = library.transcript(id: tige) else {
            throw EchecDuTravail(
                message: "la bibliothèque ne relit pas le fichier qu'elle vient d'écrire : \(tige)")
        }
        verrou.lock()
        ecritures.append(tige)
        verrou.unlock()
        return relu
    }

    /// Les tiges des fichiers écrits, dans l'ordre des écritures : le témoin de terrain contre
    /// lequel chaque `documentID` rapporté est comparé.
    var tigesEcrites: [String] {
        verrou.lock()
        defer { verrou.unlock() }
        return ecritures
    }
}

/// Le document qu'un travail de ce cas écrit vraiment : un `id` **avant** écriture, qui n'est la
/// tige de rien — c'est la bibliothèque qui le redéfinira —, une identité de source canonique, et
/// un texte de segment qui sert de juge quand deux fichiers portent le même nom de départ.
private func documentEcrit(
    identite: String, titre: String, texte: String = "Bonjour"
) -> TranscriptDocument {
    let date = midiDeTest()
    return TranscriptDocument(
        id: "avant-ecriture-\(identite)",
        title: titre,
        source: TranscriptSource(kind: .file, path: "/tmp/\(identite).mp4", identity: identite),
        duration: 12,
        language: "fr",
        languageWasForced: false,
        model: "large-v3-turbo",
        createdAt: date,
        completedAt: date,
        status: .complete,
        segments: [TranscriptSegment(start: 0, end: 12, text: texte)],
        coverage: TranscriptDocument.Coverage(coveredSeconds: 12, ratio: 1),
        boundaries: [])
}

/// Midi, dans le calendrier et le fuseau courants : la tige porte le jour **local**, et midi ne
/// peut pas basculer d'un jour à l'autre par un décalage horaire.
private func midiDeTest() -> Date {
    var composants = DateComponents()
    composants.year = 2026
    composants.month = 9
    composants.day = 20
    composants.hour = 12
    return Calendar(identifier: .gregorian).date(from: composants) ?? Date(timeIntervalSince1970: 0)
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
    var estOuverte: Bool { lock.lock(); defer { lock.unlock() }; return opened }
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

/// Le document que rend un travail de fixture.
///
/// **Une seule fixture partagée, et elle n'est observée par aucun des cas ci-dessus** : ces
/// régressions portent sur la *politique* de la file — l'ordre, l'échec qui n'arrête pas la file,
/// l'annulation, les attentes concurrentes — et sur les *libellés* de ses éléments, jamais sur le
/// contenu d'un transcript. La seule chose que le changement de signature leur impose est de
/// **rendre** un document ; écrire le même à douze endroits n'ajouterait aucune lecture et
/// doublerait la surface à maintenir quand le schéma bougera.
///
/// La tige est celle que porte la fixture. Un travail qui écrit un vrai fichier rend le document
/// **relu sur disque**, dont la bibliothèque a re-doré l'`id` de la tige qu'**elle** a choisie
/// (§2.4) : un cas qui veut prouver que la tige est *celle du fichier* doit écrire par la
/// bibliothèque, pas rendre une fixture. C'est le cas de `t_de890205`, pas celui-ci.
private func documentFactice(id: String = "fixture-tige") -> TranscriptDocument {
    TranscriptDocument(
        id: id,
        title: "Fixture",
        source: TranscriptSource(kind: .file, path: "/tmp/fixture.mp4", identity: "fixture"),
        duration: 1,
        language: "fr",
        languageWasForced: false,
        model: "fixture",
        createdAt: Date(timeIntervalSince1970: 0),
        completedAt: Date(timeIntervalSince1970: 1),
        status: .complete,
        segments: [],
        coverage: TranscriptDocument.Coverage(coveredSeconds: 1, ratio: 1),
        boundaries: [])
}

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
