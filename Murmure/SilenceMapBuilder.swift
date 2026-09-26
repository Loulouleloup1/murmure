import Foundation
import MurmureCore

/// La **carte de silence** d'un WAV décodé : `ffmpeg` analyse, nous ne portons que le rapport
/// (plan §2.1 et §4 lot 7).
///
/// **Ce fichier n'a pas de tests, et c'est une propriété de la cible, pas un oubli** : la cible
/// app n'a pas de bundle de tests (`EmbeddedTools.swift` dit la même chose). Tout ce qui est
/// décidable est donc dans `MurmureCore` — `FfmpegCommand` construit l'invocation et lit la
/// sortie, `SilenceMap` normalise ; ici il ne reste que le câblage : lancer le binaire, et
/// remettre sa sortie au lot 3.
///
/// **L'audio ne traverse jamais notre processus.** `ffmpeg` lit le WAV ; ce que nous recevons est
/// le *rapport* de `silencedetect` (une ligne de quelques dizaines d'octets par silence détecté).
/// C'est exactement l'inverse du piège n°1 du plan : une carte obtenue en chargeant le WAV décodé
/// entier coûterait 460 Mo pour 4 h d'audio et n'apprendrait rien de plus.
///
/// Les valeurs de détection (`noise=-30dB:duration=0.5`) et l'analyseur de la sortie de `ffmpeg`
/// sont la propriété du **lot 4** (règle 9) : ils ne sont ni recopiés ni réécrits ici — c'est
/// pour ça que ``invocation(wav:ffmpeg:)`` existe plutôt qu'un tableau d'arguments local.
enum SilenceMapBuilder {
    /// Le résultat d'une analyse : ce que `ffmpeg` a écrit, et ce que le lot 3 consomme.
    struct Analysis: Equatable {
        /// Les intervalles **normalisés** — grille 16 kHz, bornés au fichier, dégénérés écartés,
        /// triés par début croissant. C'est l'entrée directe de
        /// `VideoTranscriptionPlan.units(duration:silences:nominal:)`.
        var intervals: [ClosedRange<Double>]
        /// Les silences **tels qu'`ffmpeg` les a écrits**, avant toute normalisation : gardés
        /// pour le compte rendu de la carte (nombre de silences, bornes brutes au 1/16 000 près,
        /// part des coupes tombées dans un silence — la mesure que le plan §2.1 rouvrira si le
        /// seuil doit changer).
        var readings: [FfmpegSilence]
    }

    /// Ce qui peut empêcher l'analyse d'aboutir. Les trois cas sont **des échecs**, pas des
    /// cartes vides : une analyse qui n'a pas tourné rendrait des coupes forcées silencieuses
    /// (toutes les unités, `.forced`) et personne ne verrait que `ffmpeg` a refusé de tourner.
    enum Failure: Error, Equatable {
        case cannotStart(executable: String, reason: String)
        case failed(exitCode: Int32, excerpt: String)
        case timedOut(excerpt: String)
    }

    /// L'invocation exacte de l'analyse, construite par le lot 4. Les valeurs de détection
    /// (`noise=-30dB:duration=0.5`, §2.1) ne sont pas écrites ici : elles restent injectables
    /// sans qu'une ligne de ce fichier change.
    static func invocation(wav: URL, ffmpeg: URL) -> FfmpegCommand.Invocation {
        FfmpegCommand.silences(of: wav, ffmpeg: ffmpeg)
    }

    /// Lance `ffmpeg -af silencedetect` sur `wav` et rend la carte de silence normalisée.
    ///
    /// - Parameter duration: la durée de l'audio **décodé** (WAV 16 kHz mono), en secondes —
    ///   c'est la borne haute du fichier (critère 9), jamais la durée annoncée par la source.
    /// - Parameter timeout: la borne de l'analyse. Une analyse qui expire échoue explicitement ;
    ///   elle ne rend pas la carte partielle qu'`ffmpeg` avait écrite jusque-là.
    static func analyze(
        wav: URL,
        duration: Double,
        ffmpeg: URL,
        timeout: TimeInterval = 3_600
    ) throws -> Analysis {
        let invocation = invocation(wav: wav, ffmpeg: ffmpeg)
        let result: SubprocessResult
        do {
            result = try Subprocess.run(
                invocation.executable, arguments: invocation.arguments, timeout: timeout)
        } catch let error as SubprocessError {
            switch error {
            case let .launchFailed(executable, reason):
                throw Failure.cannotStart(executable: executable, reason: reason)
            }
        } catch {
            throw Failure.cannotStart(
                executable: invocation.executable.path, reason: error.localizedDescription)
        }

        if result.timedOut { throw Failure.timedOut(excerpt: excerpt(result.stderr)) }
        guard result.exitCode == 0 else {
            throw Failure.failed(exitCode: result.exitCode, excerpt: excerpt(result.stderr))
        }

        // `stderr` est le seul flux exploitable : `silencedetect` écrit son rapport là (c'est la
        // raison pour laquelle `Subprocess` rend les deux flux séparément, lot 4).
        let readings = FfmpegCommand.silenceIntervals(inFfmpegOutput: result.stderr)
        return Analysis(
            intervals: SilenceMap.intervals(from: readings, duration: duration),
            readings: readings)
    }

    /// Longueur maximale de la sortie recopiée dans un échec. Le rapport de `silencedetect` est
    /// court, mais `ffmpeg` écrit aussi son en-tête et sa ligne de progression : ce qui doit
    /// rester lisible, c'est le **début** de la sortie, là où est le refus.
    static let excerptLimit = 2_000

    /// Un extrait de `stderr`, borné. Destiné à `AcquisitionDiagnostics.block(...redacting:)`
    /// (lot 4), qui retire les chemins de travail avant qu'un bloc ne soit copié quelque part.
    private static func excerpt(_ stderr: String) -> String {
        String(stderr.prefix(excerptLimit))
    }
}
