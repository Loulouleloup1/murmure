import Foundation

/// Ce qu'une tuile de transcript affiche, dérivé du document JSON (critère 16, plan §2.4 et §4
/// lot 9).
///
/// **Pourquoi ce type existe, alors que la tuile est une vue.** `Murmure/` n'a pas de bundle de
/// tests : une phrase, un format de date ou une largeur écrits dans `TranscriptsPaneView` sont des
/// décisions que rien ne peut vérifier et que rien ne peut relire. Tout ce qu'une tuile **décide**
/// est donc ramené ici, en Swift pur — quelles chaînes, dans quel ordre, et quelles actions elle
/// offre. Ce qui reste dans la vue ne décide plus rien : elle pose cinq chaînes et itère deux
/// actions.
///
/// **Règles gelées par le contrat (carte QA L9)** — chacune est exécutée par
/// `TranscriptTileTests` :
///
/// 1. **Une tuile par document, sans filtrer par statut.** Le disque est la vérité (critère 14) :
///    un travail `inProgress` ou `failed` **a** son fichier, donc sa tuile. Un tel document n'a
///    souvent aucun segment, et sa tuile porte alors un résumé vide (règle 5) plutôt qu'un mot
///    inventé.
/// 2. **`id` est l'`id` du document**, c'est-à-dire la tige de son nom de fichier telle que
///    `TranscriptLibrary.write` la lui a posée (lot 2). C'est ce que le panneau redonne à
///    `TranscriptLibrary.transcript(id:)` et `delete(id:)` : une tuile porte une identité, pas un
///    chemin.
/// 3. **`title` est `document.title` tel quel.** Jamais le slug du nom de fichier : c'est le titre
///    qui a été écrit, et c'est lui que le Markdown affiche (critères 16 et 21).
/// 4. **`source` est un mot d'affichage, jamais une valeur de stockage** : « YouTube », « X »,
///    « File ». Les valeurs brutes de ``TranscriptSourceKind`` (`youtube`, `x`, `file`) sont un nom
///    de schéma gelé par le lot 1, pas une chaîne d'interface — les confondre mettrait un nom de
///    fichier JSON dans une tuile.
/// 5. **`date` est le JOUR de `createdAt`**, format `d MMM yyyy` (« 20 Sep 2026 »), dans le
///    calendrier passé en paramètre et la locale `HistoryGrouping.locale` (anglais, comme le reste
///    de la fenêtre). **Pas d'heure** : une tuile est un document dans une bibliothèque, pas une
///    dictée dans une journée. `createdAt` et non `completedAt`, parce que le second est absent
///    d'un travail en cours et qu'une tuile sans date n'est pas une tuile.
/// 6. **`duration` suit la seule règle de durée du module** : `HistoryRow.duration(_:)`. Deux
///    formatages qui s'accorderaient aujourd'hui sont deux formatages qui peuvent diverger demain,
///    et « 38 min » doit vouloir dire la même chose dans l'Historique et dans les Transcripts.
/// 7. **`summary` est le début du texte, sur une seule ligne** : le premier segment qui porte du
///    texte, aplati par ``StatusPanelText/oneLine(_:)`` (une transcription contient des retours à
///    la ligne), puis coupé à ``previewLimit`` **à une frontière de mot**, avec « … ». Un document
///    sans texte rend une chaîne vide — la vue n'affiche alors pas de ligne de résumé.
/// 8. **L'ordre d'affichage appartient à ce lot.** `TranscriptLibrary.list()` rend les documents
///    dans l'ordre du dossier et le dit explicitement (« L'ordre n'est pas contractuel : c'est le
///    panneau (lot 9) qui trie pour l'affichage »). Ici : **`createdAt` décroissant** — le plus
///    récent d'abord, comme l'Historique — et, à instant égal, **`id` croissant**, pour que deux
///    documents écrits dans la même seconde ne dépendent pas de l'ordre de parcours du dossier.
/// 9. **Deux actions, et deux seulement** (critère 17) : ouvrir et supprimer. La relance d'une
///    transcription n'est pas une action de tuile (R7 : elle passe par le chemin de lancement
///    normal), et le plan §7 range le critère 17 sous « tests du modèle de tuile » — c'est
///    ``Action``.
public struct TranscriptTile: Equatable, Sendable, Identifiable {
    /// Les deux actions qu'une tuile offre (critère 17), dans l'ordre où elles sont offertes :
    /// ouvrir le texte continu, puis supprimer le transcript.
    ///
    /// **Énumérées dans `MurmureCore` alors qu'elles sont dessinées dans la vue**, et c'est le
    /// seul moyen que « les seules actions sont ouvrir et supprimer » soit vérifiable : une liste
    /// écrite dans la vue, ou un `default` qui l'aurait complétée, auraient rendu la règle
    /// invérifiable — exactement comme les trois `switch` sans `default` de ``WindowSection``.
    ///
    /// **Créer n'est pas une action de tuile** : ce qui crée un transcript, c'est l'acquisition
    /// (lot 6) lancée par le menu ou par une cible de dépôt (R7, critère 17).
    public enum Action: CaseIterable, Sendable {
        /// Ouvrir le texte continu du transcript, horodatage au survol (critère 16).
        case open
        /// Supprimer le transcript — les deux fichiers, `.json` et `.md` (critère 17).
        case delete
    }

    /// La longueur maximale du résumé, en caractères.
    ///
    /// Même valeur ET même raison que `HistoryRow.previewLimit` : c'est un plafond sur ce qui est
    /// **construit**, pas la troncature que l'œil voit (`Text` fait la sienne, à la largeur de la
    /// tuile). Il est là parce que l'alternative est de tendre à SwiftUI la première minute d'une
    /// vidéo de deux heures pour chaque tuile d'une grille de trente.
    public static let previewLimit = 140

    /// La tige du nom de fichier du transcript (règle 2) — l'identité que le panneau redonne à la
    /// bibliothèque pour ouvrir ou supprimer.
    public let id: String
    /// Le titre tel qu'il a été écrit (règle 3).
    public let title: String
    /// Le mot d'affichage de la provenance : « YouTube », « X », « File » (règle 4).
    public let source: String
    /// Le jour du transcript, formaté (règle 5).
    public let date: String
    /// La durée formatée, par la règle de l'Historique (règle 6).
    public let duration: String
    /// Une ligne du début du texte, ou une chaîne vide (règle 7).
    public let summary: String

    public init(
        id: String, title: String, source: String, date: String, duration: String, summary: String
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.date = date
        self.duration = duration
        self.summary = summary
    }

    /// Les actions que **cette** tuile offre : ``Action/allCases`` (règle 9).
    ///
    /// Exposé sur la tuile et non lu directement de l'énumération par la vue, pour que le panneau
    /// itère ce qu'un transcript offre au lieu d'une constante écrite de son côté.
    public var actions: [Action] {
        Action.allCases
    }

    /// La tuile d'un document (règles 2 à 7).
    public static func tile(
        for document: TranscriptDocument, calendar: Calendar
    ) -> TranscriptTile {
        TranscriptTile(
            id: document.id,
            title: document.title,
            source: sourceWord(for: document.source.kind),
            date: HistoryGrouping.formatted(
                document.createdAt, format: "d MMM yyyy", calendar: calendar),
            duration: HistoryRow.duration(document.duration),
            summary: summary(of: document.segments))
    }

    /// Les tuiles d'une liste de documents, **dans l'ordre d'affichage** (règle 8) : `createdAt`
    /// décroissant, puis `id` croissant.
    ///
    /// Le panneau lui passe `TranscriptLibrary.list().documents` — le disque est l'index (critère
    /// 14), donc ce qui apparaît ici est ce qui existe, et supprimer un fichier retire sa tuile au
    /// rechargement suivant.
    public static func tiles(
        for documents: [TranscriptDocument], calendar: Calendar
    ) -> [TranscriptTile] {
        // Le tri porte sur les DOCUMENTS, pas sur les tuiles : `createdAt` et `id` sont les deux
        // clés de la règle 8 — la tuile ne porte ni l'un ni l'autre (elle porte le jour formaté),
        // et trier sur une chaîne d'affichage ferait dépendre l'ordre du format de la date.
        documents
            .sorted { gauche, droite in
                guard gauche.createdAt == droite.createdAt else {
                    return gauche.createdAt > droite.createdAt
                }
                // À instant égal, `id` croissant (règle 8) : sans ce second critère, deux
                // documents écrits dans la même seconde changeraient de place d'un rechargement à
                // l'autre, au gré de l'ordre de parcours du dossier.
                return gauche.id < droite.id
            }
            .map { tile(for: $0, calendar: calendar) }
    }

    // MARK: - Les champs dérivés

    /// Le mot d'affichage de la provenance (règle 4). **Sans `default`** : un quatrième
    /// ``TranscriptSourceKind`` doit dire son mot ici, parce que retomber sur la valeur brute
    /// mettrait `youtube` dans une tuile sans que rien ne le signale.
    private static func sourceWord(for kind: TranscriptSourceKind) -> String {
        switch kind {
        case .youtube: "YouTube"
        case .x: "X"
        case .file: "File"
        }
    }

    /// Le début du texte, sur une seule ligne (règle 7).
    ///
    /// Le **premier segment qui porte du texte**, et non le premier segment : une transcription
    /// commence par un silence et rend un segment vide (ou une suite d'espaces), et un résumé qui
    /// afficherait ce blanc ne pourrait plus être distingué d'un document sans texte — c'est
    /// exactement la propriété que le contrat de `TranscriptTile` vérifie dans le même test.
    private static func summary(of segments: [TranscriptSegment]) -> String {
        for segment in segments {
            // Même aplatissement que la ligne d'une entrée d'Historique (`StatusPanelText`), et
            // pour la même raison : une transcription contient des retours à la ligne, qui
            // pousseraient la suite du résumé hors d'une tuile qui n'en montre qu'un.
            let ligne = StatusPanelText.oneLine(segment.text)
            guard ligne.isEmpty else { return cut(ligne) }
        }
        // Un document sans texte rend une chaîne vide et **pas un mot inventé** : l'interface n'a
        // de mots que dans `MenuText`, et un placeholder ici serait une phrase que personne n'a
        // décidée (règle 7).
        return ""
    }

    /// Coupé à la queue, à une frontière de mot, avec une ellipsis — la règle de
    /// ``previewLimit``, identique mot pour mot à celle de `HistoryRow`, parce qu'une tuile et une
    /// ligne d'Historique montrent la même chose : le début d'un texte, à la largeur d'une ligne.
    ///
    /// **Le texte est coupé à ``previewLimit`` caractères *avant* l'ellipsis**, donc au plus
    /// ``previewLimit`` + 1 : le plafond porte sur ce qui est construit, pas sur ce que l'œil voit
    /// (`Text` fait la sienne, à la largeur de la tuile).
    private static func cut(_ ligne: String) -> String {
        guard ligne.count > previewLimit else { return ligne }
        let tete = ligne.prefix(previewLimit)
        // La coupe tombe **entre deux mots**, jamais dans `endpoi…` : le début du texte est ce qui
        // l'identifie, et une ellipsis au milieu d'un mot le rend illisible.
        guard let dernierEspace = tete.lastIndex(of: " ") else { return tete + "…" }
        return tete[..<dernierEspace] + "…"
    }
}
