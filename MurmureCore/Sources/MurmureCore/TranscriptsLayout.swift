import CoreGraphics

/// Les mesures de la grille de transcripts, en points (critère 16, plan §4 lot 9).
///
/// **Pourquoi elles sont ici et pas dans la vue**, exactement comme `WindowLayout`,
/// `HistoryLayout` et `WaveformLayout` : `Murmure/` n'a pas de bundle de tests, donc une largeur
/// écrite dans un `.frame(width:)` est une décision que rien ne peut vérifier et que personne ne
/// peut relire. Ce qui est gelé ici n'est pas seulement un chiffre, c'est la **relation** entre les
/// chiffres et la fenêtre : combien de colonnes tiennent dans un panneau, et quelle largeur chaque
/// tuile reçoit.
///
/// **Règles gelées par le contrat (carte QA L9)**, exécutées par `TranscriptsLayoutTests` :
///
/// 1. **Au moins une colonne, jamais zéro.** Une grille à zéro colonne n'est pas une grille vide,
///    c'est une surface blanche : rien n'y explique pourquoi elle est vide. Même règle que
///    `WaveformLayout.barCount(inWidth:)`, qui ne rend jamais zéro barre pour la même raison.
/// 2. **`columns(inWidth:)` est le plus grand nombre de colonnes qui tiennent à
///    ``minimumTileWidth``**, avec ``tileSpacing`` entre elles : `N × minimumTileWidth +
///    (N − 1) × tileSpacing ≤ width`. La conséquence est gelée aussi : le nombre de colonnes
///    **ne décroît jamais** quand la largeur augmente.
/// 3. **`tileWidth(inWidth:columns:)` partage la largeur restante, puis la borne** : la tuile
///    reçoit `(width − (columns − 1) × tileSpacing) / columns`, **plafonnée** à
///    ``maximumTileWidth`` et **planchée** à ``minimumTileWidth``. Le plafond est ce qui empêche
///    une colonne unique de s'étirer sur toute la largeur d'un écran — une tuile de 900 pt de large
///    pour trois mots n'est plus une tuile. Le plancher l'emporte sur le partage quand le panneau
///    est plus étroit qu'une tuile (même arbitrage que `WaveformLayout.barWidth(inWidth:barCount:)`,
///    qui déborde plutôt que de dessiner des barres de largeur nulle). Cet arbitrage-là n'est pas
///    atteignable dans l'application : la fenêtre ne descend pas sous `WindowLayout.minimumSize`.
/// 4. **La fenêtre la plus étroite porte encore au moins deux colonnes.** Le panneau fait
///    `WindowLayout.minimumSize.width` moins la barre latérale la plus large moins deux fois
///    ``contentPadding``, et une grille qui n'y tiendrait qu'une seule colonne serait une liste —
///    c'est-à-dire un autre écran. À la largeur par défaut de la fenêtre, il en tient au moins
///    trois.
/// 5. **`tileSpacing` et `contentPadding` sont des mesures, pas des bordures** : aucune règle de
///    séparation n'est dessinée entre deux tuiles. Le plan §2.2 a supprimé les traits de division
///    de cette fenêtre, et deux règles qui se contrediraient dans la même fenêtre seraient la
///    première chose à disparaître.
///
/// **Non gelé par un test** : le rayon d'une tuile. Elle prend `WindowLayout.rowCornerRadius` (le
/// palier « ligne interactive » de §2.3, 11 pt), pas un quatrième rayon inventé ici — la vue le
/// lit, il n'y a donc rien à geler dans ce fichier.
public enum TranscriptsLayout {
    /// La largeur minimale d'une tuile, en points.
    ///
    /// C'est la largeur à laquelle une tuile cesse d'être lisible : un titre sur deux lignes, une
    /// ligne « source · date · durée » et une ligne de résumé, à 13 pt. En dessous, le titre est
    /// coupé au milieu d'un mot et la ligne de provenance perd l'un de ses trois champs.
    public static let minimumTileWidth: CGFloat = 200

    /// La largeur maximale d'une tuile, en points.
    ///
    /// Plus large, une tuile cesse d'être une tuile : elle devient une ligne de texte bordée. C'est
    /// aussi ce qui force la grille à ajouter des colonnes au lieu d'étirer la sienne quand la
    /// fenêtre s'élargit — le contraire exact du défaut mesuré par `WaveformLayout` (« un amas
    /// resserré au centre d'une rangée de 340 pt »).
    public static let maximumTileWidth: CGFloat = 340

    /// L'écart entre deux tuiles, dans les deux directions.
    public static let tileSpacing: CGFloat = 16

    /// La marge entre la grille et les bords de son panneau, sur les quatre côtés.
    public static let contentPadding: CGFloat = 20

    /// La gouttière de l'horodatage, à gauche d'un paragraphe de la lecture (critère 16).
    ///
    /// **Réservée même vide** : l'horodatage apparaît au survol, et une colonne qui se remplirait
    /// en poussant le texte ferait sauter le document sous le pointeur, ligne après ligne. Assez
    /// large pour « 1:02:03 » et un glyphe de lecture à 11 pt — la forme la plus longue que
    /// ``TranscriptsPaneModel/instant(_:)`` produit sur une vidéo qui dépasse l'heure.
    ///
    /// Cinquième mesure de ce fichier, et la seule qui ne soit pas lue par un test du contrat :
    /// elle ne décide rien du dessin de la grille (colonnes, largeurs, écarts, marge), elle règle
    /// la lecture au survol, dont le plan §7 fait une gate à l'œil. Les quatre autres sont gelées
    /// par `TranscriptsLayoutTests` et ne bougent pas avec celle-ci.
    public static let instantGutterWidth: CGFloat = 74

    /// Le nombre de colonnes qui tiennent dans un panneau de `width` points (règles 1 et 2).
    public static func columns(inWidth width: CGFloat) -> Int {
        // Règle 2 réarrangée : `N × minimumTileWidth + (N − 1) × tileSpacing ≤ width` équivaut à
        // `(N − 1) × (minimumTileWidth + tileSpacing) ≤ width − minimumTileWidth`, donc à
        // `N ≤ (width + tileSpacing) / (minimumTileWidth + tileSpacing)`. Le plus grand N est la
        // partie entière de ce quotient — arithmétique et non approximatif : c'est ce qui rend vraie
        // la seconde moitié de la règle (« une colonne de plus ne tiendrait pas »), que le contrat
        // vérifie sur tout l'intervalle des largeurs réelles.
        let pas = minimumTileWidth + tileSpacing
        let colonnes = ((width + tileSpacing) / pas).rounded(.down)
        // Règle 1 : jamais zéro. Un panneau plus étroit qu'une tuile porte une colonne qui déborde
        // plutôt qu'une surface blanche — même arbitrage que `WaveformLayout.barCount(inWidth:)`,
        // et seul cas où la règle 2 ne peut pas être satisfaite (il n'est pas atteignable dans
        // l'application : la fenêtre ne descend pas sous `WindowLayout.minimumSize`).
        return max(1, Int(colonnes))
    }

    /// La largeur de chaque tuile quand `columns` colonnes sont posées dans `width` points
    /// (règle 3).
    public static func tileWidth(inWidth width: CGFloat, columns: Int) -> CGFloat {
        // `max(1,)` et non `columns` tel quel : la règle 1 dit qu'il y a toujours au moins une
        // colonne, et un appelant qui passerait zéro demanderait une division par zéro. La
        // contrainte est la même des deux côtés, donc elle se tient ici aussi.
        let colonnes = max(1, columns)
        // La largeur restante est partagée : les écarts entre les tuiles sont pris d'abord, parce
        // qu'ils ne sont pas compressibles.
        let partage = (width - CGFloat(colonnes - 1) * tileSpacing) / CGFloat(colonnes)
        // Puis bornée : le **plafond** empêche une colonne unique de s'étirer sur toute la largeur
        // d'un écran, le **plancher** l'emporte sur le partage quand le panneau est plus étroit
        // qu'une tuile (une tuile de largeur nulle serait un blanc, pas une tuile).
        return min(max(partage, minimumTileWidth), maximumTileWidth)
    }
}
