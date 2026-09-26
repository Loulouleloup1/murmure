import Foundation

/// L'état d'un travail de transcription, écrit dans
/// `Application Support/Murmure/Transcripts/work/<jobID>/progress.json` (plan §2.1) : la liste des
/// unités, l'état du travail, la dernière unité terminée et l'erreur éventuelle.
///
/// **C'est ici que vit la reprise**, en Swift pur — donc testée. `progress.json` est la seule
/// mémoire d'un travail interrompu : il est écrit après chaque unité, relu **tel quel** au
/// lancement suivant, et rien d'autre ne décide où reprendre (plan §2.1 ; §2.4, arbitrage N1 : un
/// transcript `inProgress` ou `failed` est **repris**, jamais écrasé ni relancé à froid).
///
/// **Règles gelées par le contrat (carte QA L3)** :
///
/// 1. `lastCompletedUnit` est l'**index** (0-based) de la dernière unité terminée, `nil` si aucune
///    ne l'est. ``nextUnitIndex`` est l'index de la **première unité non terminée**
///    (`lastCompletedUnit + 1`), `nil` quand toutes les unités sont faites : c'est le point de
///    reprise, et c'est la seule chose que le moteur (lot 8) ait à demander.
/// 2. `advance()` marque terminée la **première** unité non terminée, et **n'en rejoue aucune** :
///    `lastCompletedUnit` ne recule jamais. Le premier `advance` d'un travail `pending` le fait
///    passer en `running` ; quand plus aucune unité ne reste, l'état devient `complete` et
///    ``nextUnitIndex`` vaut `nil`.
/// 3. `pause()` passe en `paused` et `resume()` en `running`, et **aucun des deux ne touche à
///    `lastCompletedUnit`** : une reprise repart de ``nextUnitIndex``, elle ne rejoue pas les
///    unités déjà transcrites et écrites sur disque. `resume()` accepte aussi un travail `failed`
///    (arbitrage N1 ci-dessus).
/// 4. `fail(_:)` passe en `failed`, enregistre le message dans `error`, et **ne marque pas**
///    l'unité en cours comme terminée : elle sera rejouée à la reprise. Le message est conservé
///    tant que le travail n'est pas terminé.
/// 5. **Clés JSON gelées** — ce fichier est lu par le CLI (lot 11) et par un contrôle qualité
///    ultérieur, donc son nom de clés compte : `units` (les frontières du plan, donc
///    `start`/`duration`/`quality` avec les valeurs brutes du document), `state`
///    (`pending|running|paused|failed|complete`), `lastCompletedUnit`, `error`. Comme partout dans
///    ce schéma, une clé sans valeur (`nil`) n'est pas écrite.
public struct TranscriptJobState: Codable, Equatable {
    /// Où en est le travail. Distinct de ``TranscriptStatus`` (le `status` du document, qui n'a que
    /// trois valeurs) : un travail en pause n'existe que dans `progress.json`.
    public enum State: String, Codable, Equatable, CaseIterable {
        case pending = "pending"
        case running = "running"
        case paused = "paused"
        case failed = "failed"
        case complete = "complete"
    }

    /// Les unités du plan, dans l'ordre (``VideoTranscriptionPlan/units(duration:silences:nominal:)``).
    public var units: [UnitBoundary]
    public var state: State
    /// Index (0-based) de la dernière unité terminée ; `nil` si aucune.
    public var lastCompletedUnit: Int?
    /// Le message du dernier échec, conservé pour la reprise et pour l'affichage.
    public var error: String?

    public init(
        units: [UnitBoundary], state: State = .pending, lastCompletedUnit: Int? = nil,
        error: String? = nil
    ) {
        self.units = units
        self.state = state
        self.lastCompletedUnit = lastCompletedUnit
        self.error = error
    }

    /// L'index de la première unité non terminée, ou `nil` si toutes le sont : le point de reprise.
    public var nextUnitIndex: Int? {
        let suivant = (lastCompletedUnit ?? -1) + 1
        return suivant < units.count ? suivant : nil
    }

    /// Marque terminée la première unité non terminée (règle 2).
    public mutating func advance() {
        guard let suivant = nextUnitIndex else {
            // Plus aucune unité à faire : c'est la fin du travail, quel que soit l'état d'où l'on
            // vient. `lastCompletedUnit` ne bouge pas — il ne recule jamais.
            state = .complete
            return
        }
        lastCompletedUnit = suivant
        state = suivant + 1 < units.count ? .running : .complete
    }

    /// Met le travail en pause sans perdre une unité déjà terminée (règle 3).
    public mutating func pause() {
        state = .paused
    }

    /// Reprend le travail — interrompu ou en échec — à ``nextUnitIndex`` (règle 3).
    public mutating func resume() {
        state = .running
    }

    /// Enregistre un échec sans marquer l'unité en cours comme terminée (règle 4).
    public mutating func fail(_ message: String) {
        state = .failed
        error = message
    }
}
