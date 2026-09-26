import Foundation

/// Le **bloc d'informations copiable** du critère 7 : ce que l'utilisateur colle à son agent IA
/// quand une acquisition échoue (plan §4 lot 4, SPEC critère 7 et décision du tour 4 — « afficher
/// les informations brutes avec un bouton copier »).
///
/// **Ce bloc est un objet de confiance, et c'est pour ça que son contenu est gelé ici.** Trois
/// règles le tiennent, et les trois sont vérifiées par des tests :
///
/// 1. **Aucun chemin de fichier audio, ni de transcript.** Le bloc dit *quelle* source a échoué
///    (son URL), pas *où* l'audio temporaire vit sur le disque. Les chemins de travail
///    (`Application Support/Murmure/Transcripts/work/<job>/source.m4a`, les unités WAV, les
///    fichiers `.json`/`.md`) sont donc **retirés** de la sortie brute : `ffmpeg` et `yt-dlp` les
///    citent spontanément dans leurs messages d'erreur, et un bloc copié dans un ticket ou une
///    conversation ne doit pas charrier l'arborescence privée de quelqu'un.
/// 2. **Jamais un contenu.** Ni le texte transcrit, ni les octets d'audio. Le bloc ne recopie que
///    la sortie des *outils* (AGENTS.md : on ne journalise jamais l'audio ni un transcript).
/// 3. **La sortie brute est bornée.** Un `ffmpeg` bavard ou un `yt-dlp` qui boucle sur des
///    avertissements peut écrire des milliers de lignes ; le bloc garde le **début** de la sortie
///    (le message d'erreur, les avertissements du début) et dit explicitement qu'il a tronqué.
///
/// Le bloc est du texte destiné à être collé tel quel : il est en anglais, comme les libellés
/// d'interface de l'application (règle de langue de `MenuText`), parce que l'agent à qui on le
/// donne n'est pas francophone par construction.
public enum AcquisitionDiagnostics {
    /// Un outil et sa version, tels qu'ils figureront dans le bloc.
    public struct ToolVersion: Equatable {
        public var name: String
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    /// Longueur maximale de la sortie brute recopiée. Assez pour le message d'erreur et ses
    /// avertissements, trop court pour qu'un bloc copié devienne illisible.
    public static let defaultStderrLimit = 4_000

    /// Construit le bloc.
    ///
    /// - Parameters:
    ///   - source: la source telle qu'elle doit apparaître (une URL, ou le libellé d'un fichier
    ///     local) — **jamais un chemin de travail**.
    ///   - toolVersions: les versions des outils impliqués (au moins `yt-dlp` et `ffmpeg` quand
    ///     elles sont lisibles : un outil absent se dit par son absence de la liste, pas par une
    ///     version inventée).
    ///   - exitCode: le code de sortie du processus fautif.
    ///   - stderr: la sortie brute de l'outil, telle quelle et non bornée par l'appelant.
    ///   - paths: les chemins à ne jamais recopier (répertoire de travail, source téléchargée,
    ///     unités WAV, fichiers de transcript). Passés par l'appelant, qui les connaît.
    ///   - notes: les remarques issues de l'analyse de la sortie (par exemple la signature
    ///     d'avertissement de `yt-dlp` sur l'absence de runtime JavaScript, plan §2.3).
    ///   - stderrLimit: la borne, injectable pour que le test la manipule.
    public static func block(
        source: String,
        toolVersions: [ToolVersion],
        exitCode: Int32,
        stderr: String,
        redacting paths: [String],
        notes: [String] = [],
        stderrLimit: Int = defaultStderrLimit
    ) -> String {
        // L'ordre compte : réduire **avant** de borner, sans quoi un chemin qui tombe juste à la
        // coupure laisserait passer un morceau de chemin, et la borne porterait sur une longueur
        // qui n'est plus celle du texte copié.
        let clean = redacted(stderr, hiding: paths)
        let output = truncate(clean, to: stderrLimit)

        var lines = [
            "Murmure acquisition diagnostics",
            "source: \(source)",
            "exit code: \(exitCode)",
        ]
        if toolVersions.isEmpty {
            // Un outil dont la version n'a pas pu être lue se dit par son absence, pas par une
            // version inventée.
            lines.append("tools: (no version reported)")
        } else {
            lines.append("tools:")
            lines.append(contentsOf: toolVersions.map { "  \($0.name) \($0.version)" })
        }
        if !notes.isEmpty {
            lines.append("notes:")
            lines.append(contentsOf: notes.map { "  - \($0)" })
        }
        lines.append(
            output.truncated
                ? "tool output (omitted after the first \(stderrLimit) of \(clean.count) characters):"
                : "tool output:")
        lines.append(output.text)
        return lines.joined(separator: "\n")
    }

    /// Ce qui remplace un chemin retiré. Volontairement sans `<`/`>` : un bloc collé dans un
    /// ticket ou un terminal ne doit rien avoir à interpréter.
    static let redaction = "[path withheld]"

    private static func redacted(_ output: String, hiding paths: [String]) -> String {
        // Le plus long d'abord : un répertoire de travail est le préfixe des fichiers qu'il
        // contient, et le remplacer le premier laisserait la fin des chemins en clair.
        var text = output
        for path in paths.sorted(by: { $0.count > $1.count }) where !path.isEmpty {
            text = text.replacingOccurrences(of: path, with: redaction)
        }
        return text
    }

    /// Garde le **début** de la sortie : le message d'erreur et ses premiers avertissements.
    private static func truncate(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        guard limit >= 0, text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }
}

// MARK: - CONTRAT lot 6 — implémenté
//
// **La tranche du lot 6** du contrat d'acquisition (plan §4 lot 6, SPEC critères 5, 6, 7 et 8).
//
// POURQUOI ICI, ET POURQUOI EN EXTENSION. `MurmureCore/Sources/MurmureCore/AcquisitionDiagnostics.swift`
// appartient au **lot 4** (§7.1 règle 9) : le lot 6 n'en est pas le créateur, il part de la copie
// du lot 4 (règle 10) et y **ajoute** ses cas. L'extension rend cette addition **prouvable** : rien
// de ce qui précède n'est touché, et `git diff` ne montre que des lignes nouvelles.
//
// Les corps de cette tranche ont été rendus par la reprise `t_58040168` : aucun ne rend plus de
// valeur sentinelle. Le motif de test du lot 6 est `AcquisitionBootstrapDiagnostics` — la classe
// ajoutée dans `AcquisitionDiagnosticsTests.swift`, disjointe de `AcquisitionDiagnosticsTests` :
// un rouge du lot 6 ne masque jamais les cas du lot 4, et réciproquement (§7.1, table des motifs).
//
// CE QUE CETTE TRANCHE GÈLE, et pourquoi ces trois choses-là :
//
// 1. **Le choix des sous-titres et sa provenance** (critère 8). Le défaut du produit est la
//    retranscription locale ; une piste de sous-titres ne s'exécute que si l'utilisateur l'a
//    désignée. Les trois provenances affichables sont celles de la SPEC — `human`, `automatic` et
//    `local` — et `local` n'est **pas** une valeur de `info.json` : c'est celle de notre propre
//    transcription, donc celle du défaut.
// 2. **La classification d'un échec d'acquisition et l'étape qui en découle** (critères 5 et 6).
//    « Ne pas retélécharger un `yt-dlp` présent » et « tenter une mise à jour avant d'annoncer
//    l'échec » ne sont pas des commentaires dans un appelant : ce sont deux décisions, et elles
//    sont prises ici, sans exécuter quoi que ce soit.
// 3. **Le texte copiable d'un échec persistant** (critère 7). Le bloc brut est déjà gelé au lot 4
//    (`block(...)`) ; ce que le lot 6 ajoute est ce que l'utilisateur voit *avant* de copier — la
//    classification, le message qui nomme la cause — et le fait que le bloc porte la **version
//    réellement constatée** de `yt-dlp`, jamais une version supposée d'après une URL de
//    téléchargement.
extension AcquisitionDiagnostics {
    // MARK: Sous-titres : le choix, et la provenance affichée (critère 8)

    /// D'où vient le texte qu'on s'apprête à lire (SPEC critère 8).
    ///
    /// `human` et `automatic` sont les deux seules provenances qu'un `info.json` puisse porter
    /// (``YtDlpMetadata/Provenance``, lot 4) ; `local` est celle de **notre** retranscription —
    /// c'est-à-dire celle du défaut. Les valeurs brutes sont les mots affichés.
    public enum SubtitleProvenance: String, Equatable, Codable, CaseIterable {
        case human = "human"
        case automatic = "automatic"
        case local = "local"
    }

    /// Une option **proposée** à l'utilisateur, telle qu'elle s'affiche.
    ///
    /// `label` porte la provenance : c'est la seule façon dont le critère 8 (« provenance
    /// affichée ») est satisfait — l'utilisateur ne doit pas avoir à deviner si le texte qu'il
    /// choisit a été écrit par un humain ou produit par une machine.
    public struct SubtitleOption: Equatable {
        /// La langue de la piste, ou `nil` pour la retranscription locale. Le défaut n'est pas une
        /// langue : le dire par `nil` interdit de l'afficher comme une piste de `info.json`.
        public var language: String?
        public var provenance: SubtitleProvenance
        /// Le libellé affiché, provenance comprise.
        public var label: String

        public init(language: String?, provenance: SubtitleProvenance, label: String) {
            self.language = language
            self.provenance = provenance
            self.label = label
        }
    }

    /// Le choix **exécuté** de l'acquisition.
    ///
    /// Il n'y a pas de cas « aucun choix » : l'absence de choix *est* ``localTranscription``
    /// (critère 8, « sans choix explicite, c'est la retranscription locale qui s'exécute »). Un
    /// `Optional` laisserait croire qu'un appelant peut oublier de trancher.
    public enum SubtitleChoice: Equatable {
        case localTranscription
        case subtitles(language: String, provenance: SubtitleProvenance)
    }

    /// Les options proposées pour une source **lue** (`info.json`, lot 4).
    ///
    /// La retranscription locale est **toujours** la première (critère 8 : c'est le défaut, et
    /// celui qui refuse les sous-titres doit avoir une ligne à désigner), puis vient une entrée par
    /// piste de `metadata.subtitles` — donc **aucune piste inventée**, et l'ordre de `info.json`
    /// est conservé (il est déjà trié par le lot 4).
    public static func subtitleOptions(from metadata: YtDlpMetadata) -> [SubtitleOption] {
        // La retranscription locale est **toujours** en tête, et `language: nil` dit qu'elle ne
        // désigne aucune piste de `info.json` : celui qui refuse les sous-titres doit avoir une
        // ligne à choisir, et cette ligne n'est pas une langue.
        let locale = SubtitleOption(
            language: nil,
            provenance: .local,
            label: "Local transcription (no subtitle track)")

        // Une entrée par piste, dans l'ordre de `info.json` (le lot 4 l'a déjà trié par langue) :
        // aucune piste inventée, aucune dupliquée. La provenance est traduite par un `switch`
        // exhaustif — un `?? valeur` par défaut afficherait une provenance fausse le jour où une
        // troisième valeur apparaîtrait dans `info.json`.
        func affichable(_ provenance: YtDlpMetadata.Provenance) -> SubtitleProvenance {
            switch provenance {
            case .human: return .human
            case .automatic: return .automatic
            }
        }

        return [locale]
            + metadata.subtitles.map { piste in
                // Le libellé **porte** la provenance : c'est la seule façon dont le critère 8 est
                // satisfait sans obliger l'utilisateur à deviner qui a écrit le texte.
                SubtitleOption(
                    language: piste.language,
                    provenance: affichable(piste.provenance),
                    label: "\(piste.language) — \(piste.provenance.rawValue) subtitles")
            }
    }

    /// Le choix **exécuté** pour la sélection de l'utilisateur.
    ///
    /// `nil` — aucun choix explicite — est la retranscription locale ; une option désignée est
    /// exécutée telle quelle. C'est le seul endroit où « les sous-titres ne servent que sur choix
    /// explicite » devient vrai plutôt que promis.
    public static func subtitleChoice(for option: SubtitleOption?) -> SubtitleChoice {
        // L'absence de choix *est* la retranscription locale, et la ligne qui la porte aussi : une
        // option sans langue ne désigne aucune piste de `info.json`, donc rien à exécuter.
        guard let option, let language = option.language else { return .localTranscription }
        return .subtitles(language: language, provenance: option.provenance)
    }

    // MARK: Première utilisation et mise à jour de `yt-dlp` (critères 5 et 6)

    /// L'URL **épinglée** du binaire officiel : la variante macOS autonome des releases de
    /// `yt-dlp`, et rien d'autre (plan §4 lot 6).
    ///
    /// `latest` est voulu : c'est ce qui rend la mise à jour du critère 6 possible, et c'est la
    /// raison pour laquelle `yt-dlp` n'est **pas** dans le bundle. La version réellement installée
    /// n'est jamais déduite de cette URL : elle est lue sur le binaire présent (`--version`) et
    /// c'est cette valeur-là qui entre dans le bloc du critère 7.
    public static let ytDlpDownloadURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// Ce que l'installateur **constate** avant d'agir (critère 6).
    public enum ToolState: Equatable {
        /// Rien à l'emplacement de l'application (`Application Support/Murmure/tools/yt-dlp`,
        /// ``ToolLocations/ytDlp(in:)``) : c'est le cas de la première utilisation.
        case absent
        /// Le binaire est là, et il a répondu sa version.
        case present(version: String)
    }

    /// L'étape suivante, **décidée avant toute acquisition** (critères 5 et 6).
    public enum BootstrapStep: Equatable {
        /// Premier besoin : télécharger, retirer la quarantaine, signer ad-hoc (critère 5).
        case install
        /// Déjà présent et utilisable : **aucun re-téléchargement** (critère 6).
        case reuse
        /// L'acquisition a échoué et la mise à jour n'a pas encore été tentée : elle l'est
        /// **avant** que l'échec soit annoncé (critère 6).
        case update
        /// La mise à jour a déjà été tentée : l'échec est annoncé, avec le bloc du critère 7.
        case report
    }

    /// L'étape d'avant-acquisition, à partir du constat de l'installateur.
    public static func bootstrapStep(for state: ToolState) -> BootstrapStep {
        switch state {
        // Un binaire présent et capable de rendre sa version n'est **jamais** retéléchargé : le
        // re-télécharger pour rien coûterait 13-16 s d'auto-extraction (plan §8) à chaque
        // acquisition.
        case .present: return .reuse
        case .absent: return .install
        }
    }

    /// L'étape après un échec d'acquisition, `updateAlreadyAttempted` disant si la mise à jour a
    /// déjà été tentée pour cette source. Un seul essai de mise à jour par acquisition : sans ce
    /// drapeau, une source durablement inaccessible ferait boucler l'application sur `-U`.
    public static func recoveryStep(updateAlreadyAttempted: Bool) -> BootstrapStep {
        // Un seul essai de mise à jour par acquisition : le drapeau est la seule chose qui
        // distingue « on n'a pas encore essayé » de « on a essayé, la source est vraiment
        // inaccessible ». Sans lui, l'application bouclerait sur `-U`.
        updateAlreadyAttempted ? .report : .update
    }

    // MARK: Le texte copiable d'un échec persistant (critère 7)

    /// Ce que l'application a **constaté**, avant d'écrire le moindre texte (critère 7). La
    /// classification existe pour que le message dise la cause et pas seulement « échec » : c'est
    /// ce qu'un utilisateur doit pouvoir coller à son agent IA.
    public enum FailureKind: Equatable, CaseIterable {
        /// `yt-dlp` n'a jamais pu être installé (téléchargement interrompu, quarantaine non levée,
        /// signature refusée) : il n'y a **rien à mettre à jour**, et dire « mise à jour impossible »
        /// enverrait l'utilisateur sur une fausse piste.
        case toolNotInstalled
        /// `yt-dlp` est installé et à jour : c'est la source qui est inaccessible (403, vidéo
        /// retirée, réseau). C'est le cas du risque 2 du plan.
        case sourceUnavailable
        /// Un fichier local illisible : ce chemin ne touche **jamais** le réseau (critère 3), et
        /// annoncer un problème de réseau serait faux.
        case localFileUnreadable
    }

    /// Les signatures connues, et la remarque que chacune produit.
    ///
    /// Une signature est reconnue par **tous** ses marqueurs, jamais par un seul : « runtime »
    /// traîne dans des sorties qui ne parlent pas de JavaScript, et une remarque inventée vaut
    /// moins que pas de remarque. Ajouter un cas connu, c'est ajouter une ligne ici — pas un
    /// `if` de plus dans le corps.
    private static let knownSignatures: [(markers: [String], note: String)] = [
        (
            markers: ["javascript", "runtime"],
            note:
                "yt-dlp reports no JavaScript runtime: some formats may be missing (plan §2.3)."
        )
    ]

    /// Les remarques tirées de la sortie brute, ajoutées au bloc (plan §2.3).
    ///
    /// Le cas visé est mesuré : quand YouTube exige un runtime JavaScript que l'incrément 1
    /// n'embarque pas, `yt-dlp` écrit un avertissement et l'acquisition peut échouer sans que rien
    /// ne le dise. La sortie est donc **analysée** pour que le bloc porte la cause réelle, au lieu
    /// d'un 403 muet. Une sortie sans signature connue ne produit **aucune** remarque : on
    /// n'invente pas de diagnostic.
    public static func notes(inOutput output: String) -> [String] {
        // Comparaison sur la sortie repliée : `yt-dlp` écrit « JavaScript » tantôt capitalisé,
        // tantôt non selon la version. Une sortie sans signature connue rend une liste vide.
        let text = output.lowercased()
        return knownSignatures.compactMap { signature in
            guard signature.markers.allSatisfy({ text.contains($0) }) else { return nil }
            return signature.note
        }
    }

    /// Le **bloc d'informations copiable** d'un échec persistant (critère 7) : le message qui
    /// nomme la cause, puis le bloc brut de ``block(source:toolVersions:exitCode:stderr:redacting:notes:stderrLimit:)``
    /// — version de `yt-dlp` réellement constatée, URL de la source, code de sortie, sortie bornée.
    ///
    /// Les mêmes interdits que le bloc du lot 4 s'appliquent, et ils sont tenus par les tests :
    /// **aucun chemin de travail** (`redacting` est fourni par l'appelant, qui les connaît),
    /// **aucun contenu audio**, **aucun texte transcrit** (AGENTS.md).
    public static func failureReport(
        kind: FailureKind,
        source: String,
        ytDlpVersion: String,
        exitCode: Int32,
        stderr: String,
        redacting paths: [String],
        stderrLimit: Int = defaultStderrLimit
    ) -> String {
        // Le message d'abord : il **nomme la cause**, et c'est lui qui distingue un `yt-dlp` jamais
        // installé d'une source inaccessible. Ces deux diagnostics n'envoient pas l'utilisateur au
        // même endroit — dire « mise à jour impossible » quand l'installation a échoué serait une
        // fausse piste — et c'est la seule raison d'être de `FailureKind`.
        let cause: String
        switch kind {
        case .toolNotInstalled:
            cause = "yt-dlp could not be installed, so there is nothing to update."
        case .sourceUnavailable:
            cause = "yt-dlp is installed and up to date: the source could not be reached."
        case .localFileUnreadable:
            cause = "The local file could not be read: no network was involved."
        }

        // La version qui entre dans le bloc est celle qui a été **lue sur le binaire**
        // (`--version`), jamais celle qu'on supposerait d'après l'URL de téléchargement.
        let versions = [ToolVersion(name: "yt-dlp", version: ytDlpVersion)]
        return cause + "\n\n"
            + block(
                source: source,
                toolVersions: versions,
                exitCode: exitCode,
                stderr: stderr,
                redacting: paths,
                // L'avertissement §2.3 devient une remarque du bloc, au lieu d'un échec muet.
                notes: notes(inOutput: stderr),
                stderrLimit: stderrLimit)
    }
}
