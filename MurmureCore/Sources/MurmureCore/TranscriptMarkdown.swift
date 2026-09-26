import Foundation

/// Le rendu Markdown d'un document de transcript : la « source de vérité humaine » du même
/// fichier que le JSON (critère 21, plan §2.4).
///
/// **Ce que le fichier doit permettre de lire d'affilée**, comme un article : le titre, la ligne
/// de source, puis des **paragraphes aérés**. Aucun horodatage dans le corps — les horodatages
/// sont dans le JSON, et l'interface les affiche au survol (tour 5 : « la lisibilité d'affilée
/// passe devant »). Un fichier qui recopie ses secondes à chaque ligne n'est pas ce qui a été
/// décidé, même s'il contient le même texte.
///
/// **Règle de fusion, gelée ici** : les segments consécutifs sont fusionnés, dans l'ordre, tant
/// que
/// - la pause entre la fin d'un segment et le début du suivant reste **strictement inférieure à
///   1,2 s**, **et**
/// - le paragraphe en cours ne **dépasserait pas 480 caractères** en accueillant le segment
///   suivant.
///
/// La seconde règle est lue comme un **plafond** et non comme un seuil d'arrêt après coup : aucun
/// paragraphe ne fait plus de 480 caractères. C'est la lecture qui rend le rendu prévisible ; si
/// l'architecte voulait l'autre, c'est un amendement de contrat.
///
/// Deux segments d'un même paragraphe sont joints par **une seule espace**, et deux paragraphes
/// sont séparés par une **ligne vide**. Ce sont les deux détails qui rendent le fichier lisible
/// dans n'importe quel lecteur Markdown, et les tests les vérifient par égalité exacte.
public enum TranscriptMarkdown {
    /// Le contenu complet du fichier `.md`, terminé par un retour à la ligne.
    ///
    /// **L'en-tête a deux lignes, et dans cet ordre** : la première est `# ` suivi du titre
    /// **tel quel** (`title`), la seconde est la ligne de source — l'URL de la source distante, ou
    /// le chemin du fichier local. Le titre du nom de fichier n'est pas réutilisé ici : le
    /// Markdown est ce que Louis lit, et « Comment écrire une app macOS » n'est pas
    /// « comment-ecrire-une-app-macos-…-2026-09-20-a1b2c3d4 ». La ligne de source est ce qui
    /// permet de rouvrir la vidéo des mois plus tard, donc c'est l'adresse, pas l'identité
    /// canonique.
    ///
    /// Un document sans segment (un travail `inProgress` écrit avant sa première unité, ou un
    /// travail `failed`) rend quand même son en-tête : le fichier doit être lisible à tout
    /// moment, c'est ce qui rend un travail interrompu consultable.
    public static func render(_ document: TranscriptDocument) -> String {
        var lignes = ["# \(document.title)", ligneDeSource(document.source)]
        let paragraphes = paragraphes(document.segments)
        if !paragraphes.isEmpty {
            // Un paragraphe par ligne, **une ligne vide entre deux** : c'est ce qui les sépare
            // dans n'importe quel lecteur Markdown, et le corps d'un document doit être lu
            // d'affilée (plan §2.4).
            lignes.append("")
            lignes.append(paragraphes.joined(separator: "\n\n"))
        }
        return lignes.joined(separator: "\n") + "\n"
    }

    /// La ligne de source : l'adresse de la source distante, ou le chemin du fichier local. En
    /// dernier recours l'identité canonique — un document dont la source n'aurait ni l'une ni
    /// l'autre garde tout de même une deuxième ligne, et le contrat d'en-tête est « deux lignes,
    /// dans cet ordre », pas « deux lignes quand c'est possible ».
    private static func ligneDeSource(_ source: TranscriptSource) -> String {
        "Source : \(source.url?.absoluteString ?? source.path ?? source.identity)"
    }

    /// Le corps : les segments fusionnés en paragraphes, dans l'ordre, sans aucun horodatage.
    ///
    /// Un texte vide est transparent : il n'ajoute rien au paragraphe et ne compte pas comme un
    /// segment de plus (il produirait une espace de trop sans porter un mot). Le seuil de pause
    /// se mesure donc bien entre deux textes consécutifs **rendus**.
    ///
    /// **Le plafond ne se paie jamais par une perte de texte.** Un segment plus long que
    /// ``plafondCaracteres`` est son propre paragraphe : le contrat arbitre ici entre deux
    /// lectures de la règle des 480 caractères, et couper à l'intérieur d'un segment trahirait
    /// l'invariant que les tests du lot 1 vérifient explicitement — « aucun texte n'est perdu ni
    /// réordonné ».
    private static func paragraphes(_ segments: [TranscriptSegment]) -> [String] {
        var paragraphes: [String] = []
        var courant = ""
        var finPrecedente: Double?

        for segment in segments {
            let texte = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !texte.isEmpty else { continue }

            let pause = finPrecedente.map { segment.start - $0 } ?? 0
            let pauseFranchie = pause >= seuilDePause
            let plafondFranchi =
                !courant.isEmpty && courant.count + 1 + texte.count > plafondCaracteres

            if courant.isEmpty || !(pauseFranchie || plafondFranchi) {
                courant = courant.isEmpty ? texte : "\(courant) \(texte)"
            } else {
                paragraphes.append(courant)
                courant = texte
            }
            finPrecedente = segment.end
        }
        if !courant.isEmpty { paragraphes.append(courant) }
        return paragraphes
    }

    /// La pause qui coupe un paragraphe, en secondes (plan §2.4). **Strictement** inférieure à
    /// cette valeur, une pause fusionne : le seuil appartient au paragraphe suivant.
    private static let seuilDePause = 1.2

    /// Le plafond d'un paragraphe, en caractères (plan §2.4).
    private static let plafondCaracteres = 480
}
