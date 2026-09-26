import Foundation

/// Où vivent les deux binaires externes de l'acquisition (plan §4 lot 4, §2.6).
///
/// **Les deux fonctions sont pures** : elles ne lisent pas le disque, ne cherchent rien dans le
/// `PATH` et ne créent aucun dossier. C'est le point qui compte : `ffmpeg` **voyage dans le
/// bundle** (`Murmure/Resources/ffmpeg`, critère 4) et `yt-dlp` **est téléchargé par Murmure**
/// sous `Application Support` (critère 5). Un `ffmpeg` pris dans le `PATH` serait celui de
/// Homebrew — donc un build GPL, et c'est exactement ce que le critère 4 interdit. La machine de
/// développement en a un (`/opt/homebrew/bin/ffmpeg`) : le contrat doit rendre le binaire du
/// bundle, jamais celui-là.
///
/// L'injection de la base est le même motif que `Storage(url:in:)` : le cœur ne décide pas de
/// l'emplacement réel, c'est l'adaptateur de l'app qui le fournit.
public enum ToolLocations {
    /// `yt-dlp` sous Application Support : `<base>/tools/yt-dlp`.
    ///
    /// Le sous-dossier `tools/` est un choix : `Application Support/Murmure/` contient déjà
    /// `models/`, `modes/`, `recordings/`, `murmure.sqlite` et `vocabulary.json` ; un binaire en
    /// vrac à la racine s'y perdrait, et l'installeur du lot 6 doit pouvoir recréer son dossier
    /// sans toucher au reste.
    public static func ytDlp(in applicationSupport: URL) -> URL {
        // `isDirectory: true` sur `tools` est ce qui garde le chemin stable : sans lui, `URL.path`
        // change selon que le dossier existe ou non (`Storage.url(subfolder:)` a mesuré le même
        // piège sur `history`). Rien n'est créé ici : demander un chemin ne construit rien.
        applicationSupport
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("yt-dlp", isDirectory: false)
    }

    /// `ffmpeg` embarqué : `Murmure.app/Contents/Resources/ffmpeg`, ou `nil` s'il manque.
    ///
    /// `nil` est un cas réel et non une commodité : une copie du bundle sans la ressource (build
    /// partiel, `project.yml` qui ne copie pas encore le fichier) doit être **constatée** par
    /// l'appelant, pas remplacée par un binaire du système.
    public static func ffmpeg(inBundle bundle: Bundle) -> URL? {
        // La question est posée au bundle, pas au disque ni au `PATH` : c'est `Bundle` qui sait
        // où sont ses ressources, et c'est ce qui rend la fonction injectable par un bundle de
        // test. Un bundle qui ne porte pas la ressource rend `nil`.
        bundle.url(forResource: "ffmpeg", withExtension: nil)
    }
}
