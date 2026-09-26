import Foundation

/// Un silence détecté par `ffmpeg -af silencedetect`, en secondes depuis le début de l'audio
/// analysé (plan §4 lot 4).
///
/// **Le type est au lot 4, la politique de coupe est au lot 7.** Ici on lit ce que `ffmpeg` a
/// écrit ; choisir *où* couper (le silence le plus proche du pas nominal, la tolérance de ± 30 s,
/// la coupe forcée marquée) est le travail de `SilenceMap` (lot 7), qui consomme ces intervalles.
/// Séparer les deux évite d'écrire deux fois le même analyseur de sortie.
public struct FfmpegSilence: Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// Durée du silence, telle qu'elle sera offerte au plan de morceaux.
    public var duration: Double { end - start }
}

/// Les trois usages de `ffmpeg` dans l'acquisition, construits **sans rien exécuter** (plan §4
/// lot 4).
///
/// **Le binaire est toujours celui qu'on donne.** Aucune de ces fonctions ne cherche `ffmpeg`
/// dans le `PATH` ni ne construit un nom nu : c'est la condition du critère 4, et c'est la raison
/// pour laquelle la machine de développement (qui a un ffmpeg Homebrew GPL) ne peut pas le
/// satisfaire par accident.
///
/// **Les nombres sont écrits sans zéro inutile** (`300.25`, `0.5`, `1.25`) : ces arguments sont
/// lus par `ffmpeg`, pas par un humain, et un format d'affichage localisé (`300,25`) serait un
/// bogue d'exécution silencieux selon la langue de la machine.
public enum FfmpegCommand {
    /// Un appel `ffmpeg` complet, prêt à être exécuté par ``Subprocess``.
    public struct Invocation: Equatable {
        public var executable: URL
        public var arguments: [String]

        public init(executable: URL, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// Décode n'importe quelle source en **WAV 16 kHz mono PCM signé 16 bits** — la seule entrée
    /// que la suite accepte : c'est le format que WhisperKit consomme, et c'est le PCM sur lequel
    /// `.slice(_:at:duration:)` découpe (§2.1).
    public static func decodeToWav16kMono(_ input: URL, to output: URL, ffmpeg: URL) -> Invocation {
        Invocation(
            executable: ffmpeg,
            arguments: [
                // `-y` : sans lui, ffmpeg demanderait s'il faut écraser la sortie, à un processus
                // qui n'a pas de terminal pour répondre.
                "-y",
                // `-nostdin` : un ffmpeg qui attend une touche bloque une acquisition entière.
                "-nostdin",
                "-i", input.path,
                // Aucune image : `-vn` évite de décoder une piste vidéo pour rien.
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                output.path,
            ])
    }

    /// La détection de silence : `-af silencedetect`, dont la sortie est lue par
    /// ``silenceIntervals(inFfmpegOutput:)``.
    ///
    /// Les valeurs par défaut (`-30dB`, 0,5 s) sont une **décision** d'architecte, pas une mesure
    /// (arbitrage `t_e3167e58`, 2026-09-21 ; plan §2.1 révision 6) : elles ont été **mesurées** ensuite
    /// sur les sources décodées 16 kHz mono du benchmark du 20/09, où les deux valeurs en présence sont
    /// indiscernables et où `-30dB` est la moins stricte des deux. Le plan les veut injectables pour
    /// être re-mesurés (le pas d'unité l'est aussi, §2.1).
    public static func silences(
        of input: URL,
        threshold: String = "-30dB",
        duration: Double = 0.5,
        ffmpeg: URL
    ) -> Invocation {
        Invocation(
            executable: ffmpeg,
            arguments: [
                "-nostdin",
                "-i", input.path,
                // Orthographe longue (`noise=` / `duration=`), celle que le contrat gèle : `n=` et
                // `d=` sont des alias valides, mais une seule écriture est écrite.
                "-af", "silencedetect=noise=\(threshold):duration=\(number(duration))",
                // Aucune sortie écrite : l'analyse ne produit que le rapport de `silencedetect`.
                "-f", "null",
                "-",
            ])
    }

    /// Découpe une tranche **sans ré-encoder** (`-c copy`), à l'échantillon près.
    ///
    /// **L'entrée doit être le WAV décodé 16 kHz mono**, jamais la source compressée (§2.1) : sur
    /// un m4a ou un Opus les frontières ne sont pas échantillon-exactes, et la dérive
    /// s'accumulerait sur 48 unités sans qu'aucun critère ne l'attrape. La lecture se fait par
    /// `-ss` **avant** `-i` (recherche dans le conteneur PCM, pas saut de paquets après
    /// décodage) : c'est cette forme qui donne l'offset exact des horodatages (critère 9).
    public static func slice(
        _ input: URL,
        at start: Double,
        duration: Double,
        to output: URL,
        ffmpeg: URL
    ) -> Invocation {
        Invocation(
            executable: ffmpeg,
            arguments: [
                "-y",
                "-nostdin",
                // `-ss` **avant** `-i` : la recherche se fait dans le conteneur PCM, à
                // l'échantillon près — c'est ce qui donne l'offset exact des horodatages.
                "-ss", number(start),
                "-i", input.path,
                "-t", number(duration),
                // Copie de flux : aucune ré-encodage, donc aucune dérive d'échantillonnage. Ni
                // `-ar` ni `-ac` : la tranche est du PCM 16 kHz mono tel quel.
                "-c", "copy",
                output.path,
            ])
    }

    /// Lit les silences dans une sortie **réelle** de `ffmpeg` (`stderr`).
    ///
    /// Les lignes utiles ont la forme `[silencedetect @ 0x…] silence_start: 2` et
    /// `[silencedetect @ 0x…] silence_end: 4.000063 | silence_duration: 2.000062` ; tout le reste
    /// de la sortie (l'en-tête de `ffmpeg`, le mapping des flux, la ligne `size=N/A time=…`) est
    /// ignoré, comme les doublons éventuels.
    ///
    /// **Un `silence_start` sans `silence_end` est ignoré** : c'est ce que produit une analyse
    /// interrompue (expiration du délai, processus arrêté), et un silence sans fin n'a pas de
    /// durée — l'inventer couperait une unité au hasard.
    public static func silenceIntervals(inFfmpegOutput output: String) -> [FfmpegSilence] {
        var silences: [FfmpegSilence] = []
        // Un seul début en attente : deux `silence_start` de suite (un doublon) ne fabriquent pas
        // deux silences, le dernier lu est celui qui compte.
        var pendingStart: Double?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let start = seconds(after: "silence_start:", in: line) {
                pendingStart = start
            } else if let end = seconds(after: "silence_end:", in: line) {
                if let start = pendingStart {
                    silences.append(FfmpegSilence(start: start, end: end))
                }
                pendingStart = nil
            }
        }
        return silences
    }

    /// La valeur qui suit `marker` sur une ligne de `ffmpeg`, jusqu'au `|` ou à la fin de la ligne
    /// (`silence_end: 4.000063 | silence_duration: 2.000062`).
    private static func seconds(after marker: String, in line: Substring) -> Double? {
        guard let range = line.range(of: marker) else { return nil }
        let value = line[range.upperBound...].split(separator: "|").first ?? ""
        return Double(value.trimmingCharacters(in: .whitespaces))
    }

    /// Un nombre écrit pour `ffmpeg`, jamais pour un humain : `String(Double)` ignore la locale
    /// (contrairement à un format d'affichage, qui écrirait `300,25` en français), et le `.0`
    /// inutile est retiré.
    private static func number(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
