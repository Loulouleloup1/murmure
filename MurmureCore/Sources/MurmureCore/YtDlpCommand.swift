import Foundation

/// Ce que `info.json` apprend sur la source : la durée **annoncée**, le titre, et les sous-titres
/// disponibles avec leur provenance (plan §4 lot 4, SPEC critères 1 et 8).
///
/// **Le modèle est décodable, et c'est le contrat** : `--write-info-json` fait écrire par `yt-dlp`
/// le fichier complet à côté de l'audio, et c'est ce fichier qu'on décode. Rien n'est deviné sur
/// la source depuis son URL.
///
/// **La durée annoncée est la référence du critère 1** : `afinfo` sur l'audio produit doit tomber
/// à ± 1 s de cette valeur. Elle est donc lue telle quelle, en secondes, jamais reformatée.
///
/// **Sous-titres : une seule ligne par langue, et l'humain gagne.** `info.json` porte deux
/// dictionnaires — `subtitles` (écrits par des humains) et `automatic_captions` (machine) — et
/// une même langue peut figurer dans les deux. Proposer les deux entrées à l'utilisateur serait
/// lui demander d'arbitrer une différence qu'il ne voit pas ; la provenance existe pour qu'il
/// sache ce qu'il choisit, pas pour l'obliger à lire deux fois la même langue.
public struct YtDlpMetadata: Equatable, Decodable {
    /// D'où vient un sous-titre : `human` ou `automatic`. Ce sont les **deux noms écrits** (SPEC
    /// critère 8), et ils sont sérialisables tels quels pour l'interface.
    public enum Provenance: String, Equatable, Codable, CaseIterable {
        case human = "human"
        case automatic = "automatic"
    }

    /// Une piste de sous-titres **disponible**, telle qu'elle sera proposée en option (critère 8).
    public struct Subtitle: Equatable, Decodable {
        /// Le code de langue rendu par `yt-dlp` (`"fr"`, `"en"`, `"de"`), sans normalisation.
        public var language: String
        public var provenance: Provenance

        public init(language: String, provenance: Provenance) {
            self.language = language
            self.provenance = provenance
        }
    }

    /// L'identifiant de la source (`id` de la vidéo YouTube, `id` du statut X), c'est-à-dire
    /// l'identité canonique du plan §2.4.
    public var identifier: String
    /// Le titre **tel qu'il a été écrit** — celui des tuiles et de l'en-tête Markdown.
    public var title: String
    /// Durée annoncée en secondes. C'est la valeur du critère 1 (`afinfo` doit tomber à ± 1 s).
    public var duration: Double
    /// L'URL publique de la source, quand il y en a une.
    public var webpageURL: URL?
    /// Une entrée par langue, triées par code de langue croissant (voir la note du type).
    public var subtitles: [Subtitle]

    public init(
        identifier: String,
        title: String,
        duration: Double,
        webpageURL: URL?,
        subtitles: [Subtitle]
    ) {
        self.identifier = identifier
        self.title = title
        self.duration = duration
        self.webpageURL = webpageURL
        self.subtitles = subtitles
    }
}

/// Les commandes `yt-dlp` de l'acquisition, construites **sans rien exécuter** (plan §4 lot 4).
///
/// **Une seule invocation par acquisition**, et c'est mesuré : chaque appel de `yt-dlp` coûte
/// 13-16 s (auto-extraction PyInstaller, plan §8). `--write-info-json` fait donc écrire les
/// métadonnées *pendant* le téléchargement — un second appel pour lire la durée serait payé
/// deux fois pour la même information.
///
/// **Aucune invocation pour un fichier local.** Un `.mp4`/`.m4a` déjà sur le disque ne passe
/// jamais par `yt-dlp` : c'est ce que dit le critère 3 (« aucun accès réseau »), et c'est
/// structurel ici — `download(_:)` rend une `.localFile`, pas une invocation vide qu'un appelant
/// distrait exécuterait quand même.
public enum YtDlpCommand {
    /// Un appel `yt-dlp` complet, prêt à être exécuté par ``Subprocess``.
    public struct Invocation: Equatable {
        /// Le binaire : `<tools>/yt-dlp` (critère 5 — il n'est pas dans le bundle, il est
        /// téléchargé puis mis à jour).
        public var executable: URL
        public var arguments: [String]
        /// Le répertoire de travail du job : l'audio téléchargé y tombe, et rien n'en sort
        /// (plan §2.4, `work/<jobID>/`).
        public var workingDirectory: URL
        /// Où `--write-info-json` écrit le fichier que ``YtDlpCommand/metadata(_:)`` décode.
        public var infoJSON: URL

        public init(executable: URL, arguments: [String], workingDirectory: URL, infoJSON: URL) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.infoJSON = infoJSON
        }
    }

    /// Ce que l'acquisition doit **faire** d'une source — la décision, pas l'exécution.
    public enum Action: Equatable {
        case download(Invocation)
        case localFile(URL)
    }

    /// Les deux façons dont une source n'est pas exploitable. Aucune n'est un code de sortie : ce
    /// sont des refus de construction, avant qu'un processus existe.
    public enum Failure: Error, Equatable {
        /// Source distante sans URL, ou fichier local sans chemin.
        case missingSource
        /// `info.json` sans titre ou sans durée : inutilisable pour le critère 1, donc refusé au
        /// lieu d'être décodé en zéros silencieux.
        case malformedInfoJSON
    }

    /// L'action à mener pour `source`, sans rien exécuter.
    ///
    /// - Parameters:
    ///   - toolsDirectory: le dossier de `yt-dlp` (`Application Support/Murmure/tools/`).
    ///   - workDirectory: le répertoire de travail du job (`work/<jobID>/`).
    public static func download(
        _ source: TranscriptSource,
        toolsDirectory: URL,
        into workDirectory: URL
    ) throws -> Action {
        switch source.kind {
        case .file:
            // Un fichier local ne construit **aucun** argument : il n'y a pas de vecteur à
            // exécuter, donc pas de socket possible (critère 3).
            guard let path = source.path, !path.isEmpty else { throw Failure.missingSource }
            return .localFile(URL(fileURLWithPath: path))
        case .youtube, .x:
            // Seule l'URL change entre YouTube et X : c'est le même chemin de code (critère 2).
            guard let url = source.url else { throw Failure.missingSource }
            return .download(invocation(for: url, toolsDirectory: toolsDirectory, into: workDirectory))
        }
    }

    /// L'invocation unique d'une source distante : métadonnées et audio dans le même passage.
    private static func invocation(
        for url: URL,
        toolsDirectory: URL,
        into workDirectory: URL
    ) -> Invocation {
        let arguments = [
            "--write-info-json",
            // `bestaudio/best` : le ffmpeg embarqué décode Opus/WebM, donc plus de `ext=m4a` qui
            // forcerait un ré-encodage (plan §2.6, §8).
            "-f", "bestaudio/best",
            // Une ligne par état de progression, sur `stdout`.
            "--newline",
            "--progress-template",
            "download:%(progress._percent_str)s of %(progress._total_bytes_estimate_str)s",
            // Une URL de vidéo dans une playlist ne doit pas emporter la playlist entière.
            "--no-playlist",
            // Le modèle de sortie : l'audio tombe dans le répertoire de travail du job et n'en
            // sort pas. Le chemin est écrit tel quel (et non composé par `URL`) pour que
            // `%(ext)s` ne soit pas ré-encodé en `%25(ext)s`.
            "-o", path(joining: workDirectory, "source.%(ext)s"),
            url.absoluteString,
        ]
        return Invocation(
            executable: toolsDirectory.appendingPathComponent("yt-dlp", isDirectory: false),
            arguments: arguments,
            workingDirectory: workDirectory,
            infoJSON: workDirectory.appendingPathComponent("source.info.json", isDirectory: false))
    }

    /// Décode le `info.json` écrit par `yt-dlp` pendant le téléchargement.
    public static func metadata(_ infoJSON: Data) throws -> YtDlpMetadata {
        guard let object = (try? JSONSerialization.jsonObject(with: infoJSON)) as? [String: Any],
            let title = object["title"] as? String, !title.isEmpty,
            // La durée annoncée est la référence du critère 1 : absente (ou nulle), le fichier est
            // refusé plutôt que décodé en zéro silencieux.
            let duration = (object["duration"] as? NSNumber)?.doubleValue, duration > 0,
            duration.isFinite
        else { throw Failure.malformedInfoJSON }

        // L'humain gagne sur la machine, une seule ligne par langue (voir la note du type).
        var byLanguage: [String: YtDlpMetadata.Provenance] = [:]
        for language in subtitleLanguages(in: object["subtitles"]) {
            byLanguage[language] = .human
        }
        for language in subtitleLanguages(in: object["automatic_captions"])
        where byLanguage[language] == nil {
            byLanguage[language] = .automatic
        }

        return YtDlpMetadata(
            identifier: object["id"] as? String ?? "",
            title: title,
            duration: duration,
            webpageURL: (object["webpage_url"] as? String).flatMap(URL.init(string:)),
            subtitles: byLanguage.keys.sorted().map {
                YtDlpMetadata.Subtitle(language: $0, provenance: byLanguage[$0] ?? .automatic)
            })
    }

    /// Les codes de langue portés par un dictionnaire de sous-titres (`subtitles` ou
    /// `automatic_captions`) : la clé suffit, la valeur est la liste des formats disponibles, dont
    /// on ne se sert pas ici. Un dictionnaire vide ou absent rend un ensemble vide.
    private static func subtitleLanguages(in value: Any?) -> Set<String> {
        guard let dictionary = value as? [String: Any] else { return [] }
        return Set(dictionary.keys)
    }

    /// Le chemin d'un fichier du répertoire de travail, composé en chaîne pour ne pas laisser
    /// `URL` ré-encoder les `%(…)s` du modèle de sortie de `yt-dlp`.
    private static func path(joining directory: URL, _ name: String) -> String {
        directory.path.hasSuffix("/") ? directory.path + name : directory.path + "/" + name
    }
}
