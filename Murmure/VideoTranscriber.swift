import Foundation
import MurmureCore
import os
import WhisperKit

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "transcription")

/// Le frein d'une unité en cours (plan §2.1).
///
/// **Deux leviers, et le second est celui qui termine l'unité.** Le rappel de progression de
/// WhisperKit est consulté à chaque jeton décodé et son `false` ferme la **fenêtre en cours**
/// (`TextDecoder.swift:747-767` : `earlyStopActor.set(true)` puis `break`). Cela ne suffit pas à
/// arrêter une unité : `transcribeFileStream` enchaîne ensuite sur le morceau suivant du flux
/// incrémental (`WhisperKit.swift:1192`), et la fenêtre d'après repart. C'est l'**annulation de la
/// `Task`** qui coupe réellement le travail — elle fait lever le `Task.checkCancellation()` du
/// chargeur incrémental (`AudioProcessor+IncrementalLoading.swift:136,178,181`) et ferme l'attente
/// de la contre-pression. ``VideoTranscriber/requestStop(_:)`` arme les deux leviers dans cet ordre.
///
/// Un objet et non un drapeau local : le frein est armé **de l'extérieur** de la boucle d'unités
/// (préemption par la dictée, lot 12 ; arrêt demandé par la passe de mesure, lot 8) pendant que le
/// rappel de progression, lui, s'exécute dans le décodeur.
///
/// **Un frein vit le temps d'une seule exécution.** `request()` est monotone et rien ne le réarme :
/// le propriétaire doit donc créer un frein neuf par travail — `TranscriptJobRunner` le fait à
/// chaque `run` — sans quoi un frein gardé plus longtemps couperait aussi la reprise du travail
/// qu'il vient de suspendre. C'est la raison pour laquelle ce type est passé **en paramètre** de
/// ``VideoTranscriber/transcribe(unit:duration:language:stop:onProgress:)`` et de
/// ``VideoTranscriber/requestStop(_:)`` plutôt que détenu par le moteur.
final class TranscriptionStop: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock(initialState: false)

    /// Vrai dès que l'arrêt a été demandé. Lu par le rappel de progression à chaque fenêtre.
    var isRequested: Bool { box.withLock { $0 } }

    /// Arme le frein. Idempotent : deux demandes d'arrêt ne changent rien à la seconde.
    func request() { box.withLock { $0 = true } }
}

/// Ce qu'une unité a rendu.
enum UnitTranscription: Equatable {
    /// L'unité est allée au bout : ses segments **locaux** (0 = début de l'unité), que
    /// `TranscriptAssembly.merge` recollera en absolu.
    case completed([TranscriptSegment])

    /// L'arrêt a été demandé pendant l'unité. Ce qui a été décodé est rendu, et l'unité **n'est pas
    /// terminée** : le point de reprise ne bouge pas, elle sera rejouée à la relance (plan §2.1,
    /// « perte maximale = l'unité en cours »).
    case stopped([TranscriptSegment])
}

/// Le moteur de transcription vidéo : il transcrit **une unité à la fois**, avec l'**instance de
/// modèle déjà chargée dans le processus** (plan §4 lot 8, décision du tour 7).
///
/// **Ce type ne décide de rien.** Où couper, dans quel ordre, ce qu'est un état reprisable et
/// comment recoller les horodatages sont les décisions de `VideoTranscriptionPlan`,
/// `TranscriptAssembly` et `TranscriptJobState` (lot 3). Ici il n'y a que l'appel au modèle, la
/// progression, et l'arrêt.
///
/// **La mémoire est bornée indépendamment de la taille de l'unité.** `audioInputOptions` force
/// `AudioLoadingMode.incremental` (WhisperKit v1.1.0 : 120 s par morceau, 2 morceaux en tampon,
/// contre-pression — `AudioProcessor.swift:53-56,63`) au lieu du `.fullFile` par défaut, qui
/// chargerait l'unité entière en flottants. C'est ce qui rend le critère 10 (pic < 2 Go sur 2 h)
/// vrai par construction et pas par chance (plan §2.1). Corollaire assumé : `clipTimestamps` est
/// refusé sous ce mode (`WhisperKit.swift:1200-1204`), donc une unité se transcrit en entier — ce
/// que la découpe en unités fait déjà.
///
/// **Aucun contenu n'est journalisé** (critère 15, AGENTS.md) : ce fichier ne journalise que des
/// index, des durées et des comptes. Le texte transcrit ne quitte jamais la valeur de retour.
actor VideoTranscriber {
    enum Failure: LocalizedError, Equatable {
        case languageDetectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .languageDetectionFailed(let reason):
                "Could not detect the language of the audio: \(reason)"
            }
        }
    }

    /// L'instance chargée : **la même** que celle de la dictée quand le modèle est déjà résolu
    /// (§2.2, scénario « instance partagée »). Elle n'est jamais créée ici.
    private let model: LoadedModel

    /// La `Task` de l'unité en cours, et rien d'autre : c'est la poignée dont
    /// ``requestStop(_:)`` a besoin pour armer le second levier. `nil` entre deux unités.
    private var inFlight: Task<[TranscriptionResult], Error>?

    init(model: LoadedModel) {
        self.model = model
    }

    /// La langue détectée sur le début d'une unité, avec le modèle **de ce transcripteur**.
    ///
    /// Instance et non type : le modèle n'est jamais créé par le moteur vidéo, il lui est donné
    /// (§2.2). L'appelant n'a donc pas à détenir une seconde référence à `LoadedModel`.
    func detectedLanguage(of unit: URL) async throws -> String {
        try await Self.detectedLanguage(of: unit, model: model)
    }

    /// La langue détectée sur le début d'une unité — le chemin **sans option** du critère 12.
    ///
    /// **Appelée une seule fois par travail, jamais à la reprise** (§2.1 : la langue vit dans le
    /// document et y est relue ; la re-détecter ferait basculer un travail repris dans une autre
    /// langue que celle sous laquelle ses unités déjà écrites ont été transcrites).
    ///
    /// `detectLangauge(audioArray:)` n'utilise que les 30 premières secondes
    /// (`WhisperKit.swift:560-567` : `padOrTrim(toLength: windowSamples)`), mais prend un tableau
    /// d'échantillons : on lui donne **l'unité 0**, pas l'audio entier — 5 min de flottants au pire
    /// (19 Mo), au lieu des 460 Mo d'une source de 4 h (le piège n°1 du plan).
    static func detectedLanguage(of unit: URL, model: LoadedModel) async throws -> String {
        do {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: unit.path)
            return try await model.detectLanguage(audioSamples: samples)
        } catch {
            // Aucun repli silencieux : `DecodingOptions` sans langue préfixerait `<|en|>` et
            // décoderait du français en anglais plausible mais faux (le commentaire de
            // `WhisperKitEngine.transcribe` porte la mesure). Mieux vaut échouer.
            logger.error("language detection failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.languageDetectionFailed(error.localizedDescription)
        }
    }

    /// Transcrit **une** unité.
    ///
    /// - Parameters:
    ///   - unit: la tranche WAV 16 kHz mono de l'unité (`UnitSlicer`), jamais la source compressée.
    ///   - duration: la durée de l'unité, pour la progression (WhisperKit la rapporte par fenêtre
    ///     de 30 s — `TranscribeTask.swift:100`).
    ///   - language: la langue de décodage, **décidée par l'appelant** (document relu ou détection).
    ///   - stop: le frein à consulter à chaque fenêtre.
    ///   - onProgress: la progression de l'unité, dans `[0, 1]`.
    func transcribe(
        unit: URL,
        duration: Double,
        language: String,
        stop: TranscriptionStop,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> UnitTranscription {
        let windows = max(1, Int((duration / Self.windowSeconds).rounded(.up)))

        // Le rappel est appelé sur une tâche détachée par WhisperKit (`TextDecoder.swift:752`) :
        // il doit rester léger et ne rien journaliser du texte. `false` = arrêt au jeton.
        let callback: TranscriptionCallback = { progress in
            onProgress(min(Double(progress.windowId + 1) / Double(windows), 1))
            return stop.isRequested ? false : nil
        }

        // `language` explicite **et** `detectLanguage: false` : WhisperKit dérive `detectLanguage`
        // de `!usePrefillPrompt` et préfixerait `<|en|>` si la langue était nil. Une seule langue
        // par unité, connue d'avance : pas de bascule en cours de décodage.
        //
        // `skipSpecialTokens: true` **n'est pas un confort** : le défaut de WhisperKit v1.1.0 est
        // `false` (`Configurations.swift:202`, relevé par `docs/research/2026-09-09-spike-longform-report.md`
        // §« any shipped feature must either set skipSpecialTokens: true »), et avec `false` le texte
        // de chaque segment sort préfixé de ses jetons : `<|3.32|> On va voir!<|5.32|>` au lieu de
        // « On va voir! ». Le premier segment d'une unité porte en plus le préremplissage
        // (`<|startoftranscript|><|fr|><|transcribe|>`) — mesuré sur la passe de 400 s du harnais
        // avant correction. Ces jetons ne sont pas des horodatages à nous : les débuts et fins de
        // segment viennent de `segment.start`/`segment.end`, pas du texte.
        let options = DecodingOptions(
            language: language, detectLanguage: false, skipSpecialTokens: true)

        let work = Task { [model] in
            try await model.kit.transcribe(
                audioPath: unit.path,
                audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                decodeOptions: options,
                callback: callback)
        }
        inFlight = work
        defer { inFlight = nil }

        do {
            let results = try await work.value
            let segments = Self.segments(from: results)
            return stop.isRequested ? .stopped(segments) : .completed(segments)
        } catch is CancellationError {
            // Le second levier a coupé la contre-pression : rien n'est revenu. Ce n'est pas un
            // échec — c'est l'arrêt demandé, et l'unité sera rejouée à la reprise.
            return .stopped([])
        }
    }

    /// Transcrit **un intervalle** d'une unité — la reprise d'une fenêtre que le moteur a sautée
    /// (plan §2.1 révision 9 et §4 lot 8-R).
    ///
    /// **Pourquoi cet appel existe, et pourquoi il est différent des autres.** WhisperKit v1.1.0
    /// saute une fenêtre entière de 30 s quand sa probabilité de non-parole dépasse
    /// `noSpeechThreshold` (0,6 par défaut, `Core/Configurations.swift:216`) sans que `avgLogProb` ne
    /// la renverse (`Core/Text/SegmentSeeker.swift:57-71`). Sur la vidéo A du plan la fenêtre sautée
    /// portait de la **parole** (RMS −19,4 dBFS sur `[300, 330)`, aucun silence ≥ 1 s) : 24,4 s ou
    /// 30,0 s perdus, et le critère 9 mesuré à 0,9573 / 0,9680 / 0,9800 selon la passe. Le remède
    /// décidé au §2.1 est **local** : rejouer l'intervalle non couvert, avec **le seul
    /// `noSpeechThreshold` désactivé**, plutôt que de désarmer le saut partout — sur un vrai silence,
    /// désarmer le seuil fait redécoder la fenêtre jusqu'à six fois par la boucle de repli et remplit
    /// le silence de texte inventé, qui **couvre** alors le silence et fait cesser le critère 9 de
    /// mesurer quoi que ce soit.
    ///
    /// **C'est le seul endroit du plan qui ne décode pas une tranche entière en `.incremental`**, et
    /// c'est assumé : `clipTimestamps` est refusé sous ce mode (`WhisperKit.swift:1200-1204`), et la
    /// reprise a besoin de décoder un **sous-intervalle** d'un fichier. Le coût est borné par la
    /// taille de l'intervalle — > 5,0 s (le plafond des pauses naturelles, plan §2.1) et ≤ 30-60 s,
    /// soit 2-4 Mo de flottants — et non par celle de
    /// l'unité : c'est ce qui garde la borne mémoire du critère 10 vraie. Les échantillons de
    /// l'unité sont lus en mémoire exactement comme ``VideoTranscriber/detectedLanguage(of:)`` les
    /// lit (5 min = 19 Mo au pire), jamais l'audio entier.
    ///
    /// - Parameters:
    ///   - unit: la tranche WAV 16 kHz mono de l'unité (`UnitSlicer`), la même que `transcribe`.
    ///   - range: l'intervalle rejoué, **dans le temps de l'unité** (`UnitSpeechRecovery.toReplay`).
    ///   - duration: la durée de l'unité — borne haute de ce qui peut être lu.
    ///   - language: la langue du travail, comme pour `transcribe` : la reprise décode dans la langue
    ///     de l'unité, elle ne détecte rien (critère 12).
    ///   - stop: le même frein que le reste du travail.
    /// - Returns: les segments **ramenés au temps de l'unité** (`+ range.lowerBound`), filtrés comme
    ///   ceux de ``VideoTranscriber/transcribe(unit:duration:language:stop:onProgress:)``.
    /// - Throws: `CancellationError` si l'arrêt est demandé avant ou pendant l'appel : l'appelant
    ///   rend `.stopped`, l'unité n'est **pas** écrite et sera rejouée à la relance (plan §2.1,
    ///   « perte maximale = l'unité en cours »).
    ///
    /// **Aucun contenu n'est journalisé** (critère 15, AGENTS.md), et la progression ne remonte rien :
    /// la barre reste sur l'unité, dont la reprise ne change pas la fraction faite.
    func transcribeInterval(
        of unit: URL,
        range: ClosedRange<Double>,
        duration: Double,
        language: String,
        stop: TranscriptionStop
    ) async throws -> [TranscriptSegment] {
        // Le frein est consulté **avant** la lecture : une demande d'arrêt déjà armée ne doit pas
        // payer la lecture de l'unité ni un appel au modèle.
        if stop.isRequested { throw CancellationError() }

        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: unit.path)
        // La coupe est faite sur la grille d'échantillons du WAV décodé (`VideoTranscriptionPlan`),
        // jamais sur une durée en secondes flottantes : c'est la même convention que `UnitSlicer`.
        let debut = min(max(0, Int((range.lowerBound * Self.sampleRate).rounded(.down))), samples.count)
        let fin = min(
            max(0, Int((min(range.upperBound, duration) * Self.sampleRate).rounded(.up))),
            samples.count)
        // Un intervalle vide ne se décode pas. Ce cas ne peut pas venir de `UnitSpeechRecovery`
        // (un trou rejoué porte > 5,0 s **dans** l'unité, plafond des pauses naturelles §2.1) : s'il
        // arrive, rendre `[]` laisse le trou en
        // place — borné, sans texte fabriqué, et c'est exactement ce que le plan attend d'une reprise
        // qui ne rend rien.
        guard debut < fin else { return [] }
        let tranche = Array(samples[debut..<fin])

        // Les options du livrable, **et le seul `noSpeechThreshold` désactivé** (`nil` : la boucle de
        // saut de `SegmentSeeker.swift:57` est un `if let`, elle devient inatteignable). Langue,
        // `detectLanguage`, température et `skipSpecialTokens` sont ceux de `transcribe`.
        let options = DecodingOptions(
            language: language, detectLanguage: false, skipSpecialTokens: true,
            noSpeechThreshold: nil)
        // Le rappel rend `false` sur arrêt (fin de la fenêtre en cours), et ne remonte **rien** :
        // la reprise ne fait pas avancer la barre de l'unité.
        let callback: TranscriptionCallback = { _ in stop.isRequested ? false : nil }

        let work = Task { [model] in
            try await model.kit.transcribe(
                audioArray: tranche, decodeOptions: options, callback: callback)
        }
        inFlight = work
        defer { inFlight = nil }

        let results = try await work.value
        // Comme `transcribe` : ce qui est revenu n'est pas une unité terminée tant que le frein n'a
        // pas dit non. Une demande arrivée pendant le décodage rend `CancellationError`.
        if stop.isRequested { throw CancellationError() }
        // Le recollage : les horodatages rendus sont locaux **à la tranche décodée**, pas à l'unité.
        // Sans ce décalage, chaque segment rejoué serait posé à 0 et se confondrait avec le début de
        // l'unité.
        return Self.segments(from: results).map {
            TranscriptSegment(
                start: $0.start + range.lowerBound, end: $0.end + range.lowerBound, text: $0.text)
        }
    }

    /// Arme l'arrêt d'une unité en cours : le frein au jeton d'abord, l'annulation de la `Task`
    /// ensuite (plan §2.1 — « le rappel de progression rend `false` **puis** la `Task` est
    /// annulée »). Sans effet entre deux unités : la boucle s'arrête d'elle-même au point de reprise.
    func requestStop(_ stop: TranscriptionStop) {
        stop.request()
        inFlight?.cancel()
    }

    /// La fenêtre de progression de WhisperKit : 30 s de mél (`Constants.defaultWindowSamples`).
    private static let windowSeconds: Double = 30

    /// La grille d'échantillons du WAV décodé — **la constante du plan**, pas un littéral : la coupe
    /// d'intervalle de ``transcribeInterval(of:range:duration:language:stop:)`` doit tomber sur la
    /// même grille que `UnitSlicer` et `VideoTranscriptionPlan`, sinon le décalage de reprise serait
    /// faux d'une fraction d'échantillon par segment.
    private static let sampleRate = VideoTranscriptionPlan.sampleRate

    /// Les segments **locaux** d'un résultat, dans la forme du contrat de document.
    ///
    /// Deux filtres, tous les deux portés par un contrat écrit :
    /// - un segment de durée nulle ou négative ne peut pas satisfaire `start < end` (règle 4 de
    ///   `TranscriptAssembly`) ;
    /// - un segment **sans texte** n'est pas rendu. Le §2.4 ne prévoit pas de segment vide — c'est
    ///   une pause, et l'assemblage du lot 3 le garde pour cette raison — mais le document livré
    ///   à un agent n'a rien à dire d'une pause, et le contrôle 3 du contrat observable refuse
    ///   `segments[i].text` vide. Le filtre est donc ici, à la source, plutôt que dans un type
    ///   dont le contrat est gelé.
    private static func segments(from results: [TranscriptionResult]) -> [TranscriptSegment] {
        results.flatMap { result in
            result.segments.compactMap { segment -> TranscriptSegment? in
                let start = Double(segment.start)
                let end = Double(segment.end)
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard end > start, !text.isEmpty else { return nil }
                return TranscriptSegment(start: start, end: end, text: text)
            }
        }
    }
}
