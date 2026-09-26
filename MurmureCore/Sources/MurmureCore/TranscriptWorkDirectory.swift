import Foundation

/// Le répertoire de travail d'un travail de transcription : `work/<jobID>/`, **dans la même
/// arborescence** que les transcripts (plan §2.4), donc sous Application Support — hors du regard
/// de l'utilisateur, dans la seule racine que l'app possède.
///
/// ``` 
/// <base>/work/<jobID>/
///   source.<ext>       mur.<ext>          (déposés par l'acquisition, lots 6 et 7)
///   units/0000.wav …   progress.json      (tranches et point de reprise, lots 3 et 8)
/// ```
///
/// **Rien n'est créé au nommage.** `directoryURL`, `progressURL` et `unitURL(index:)` *calculent*
/// un chemin ; `create()` crée, `remove()` supprime, et ce sont les deux seules fonctions de ce
/// type à toucher le disque. La séparation n'est pas de l'hygiène, c'est une leçon déjà payée dans
/// ce dépôt (``Storage``) : une fonction qui nomme un chemin et qui crée au passage fait écrire un
/// test qui voulait seulement **demander** où se trouve le dossier.
///
/// **Aucun nettoyage automatique du support applicatif** (AGENTS.md) : `remove()` n'est appelé
/// qu'après un succès vérifié (R7), et jamais par cette structure elle-même.
public struct TranscriptWorkDirectory {
    /// La base de la bibliothèque : le répertoire de travail est son sous-dossier `work/`.
    public let base: URL
    /// L'identifiant du travail, qui nomme le répertoire.
    public let jobID: String

    public init(base: URL, jobID: String) {
        self.base = base
        self.jobID = jobID
    }

    /// `<base>/work/<jobID>` : le répertoire de travail lui-même. Pur — ne crée rien.
    ///
    /// `isDirectory: true` est explicite : la variante à un argument **interroge le disque** pour
    /// décider d'une barre oblique finale, ce qui rendrait deux URL inégales pour un même
    /// emplacement avant et après `create()` (le défaut mesuré de ``Storage/url(subfolder:in:)``).
    public var directoryURL: URL {
        base.appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
    }

    /// `<base>/work/<jobID>/progress.json` : le point de reprise du travail (lots 3 et 8). Pur.
    public var progressURL: URL {
        directoryURL.appendingPathComponent(Self.progressNomDeFichier)
    }

    /// `<base>/work/<jobID>/units/<index>.wav` : la tranche numéro `index`. Pur — ne crée rien.
    ///
    /// Le numéro est écrit sur **au moins quatre chiffres** (`0000`, `0042`, `1234`), parce que
    /// c'est un ordre de lecture dans le Finder comme dans un tri de chaînes. Au-delà de 9999 le
    /// numéro **s'allonge** (`10000`) au lieu d'être tronqué : deux tranches ne peuvent pas porter
    /// le même nom de fichier — c'est la seule chose qui compte vraiment ici.
    public func unitURL(index: Int) -> URL {
        unitsURL.appendingPathComponent(String(format: "%04d.wav", index))
    }

    /// `<base>/work/<jobID>/units/` : le sous-dossier des tranches. Pur, comme les trois
    /// ci-dessus — c'est `create()` qui le crée, et c'est le seul endroit qui le connaît par son
    /// nom.
    private var unitsURL: URL {
        directoryURL.appendingPathComponent("units", isDirectory: true)
    }

    /// Crée `<base>/work/<jobID>/units/`, parents compris. Réussit si le répertoire existe déjà :
    /// une reprise (statut `inProgress`, plan §2.4) repasse par ici sans rien casser.
    public func create() throws {
        // Le dossier `units/` est créé avec ses parents : `work/<jobID>/` n'existe donc plus pour
        // personne sans ses tranches — les deux ne se séparent pas, et `progress.json` (écrit par
        // le lot 8 à la racine du travail) trouve toujours son dossier.
        try FileManager.default.createDirectory(
            at: unitsURL, withIntermediateDirectories: true)
    }

    /// Supprime **tout** le répertoire de travail, unités comprises. Ne jette pas.
    ///
    /// Idempotent : appelé deux fois (suppression après succès vérifié, puis relance ou nettoyage
    /// manuel), il ne doit rien casser. **Ne touche à rien en dehors de `work/<jobID>/`** — en
    /// particulier pas les transcripts du dossier parent, qui sont le résultat du travail.
    public func remove() {
        // Un `try?` et pas une erreur : « il n'y avait déjà plus rien à supprimer » n'est pas un
        // échec — c'est l'état visé. La suppression reste **bornée** à `directoryURL`, donc le
        // dossier des transcripts et les autres travaux sont hors d'atteinte.
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// Le nom du point de reprise, écrit une fois : c'est la forme du plan §2.4
    /// (`work/<jobID>/progress.json`), lue par les lots 3 et 8.
    private static let progressNomDeFichier = "progress.json"
}
