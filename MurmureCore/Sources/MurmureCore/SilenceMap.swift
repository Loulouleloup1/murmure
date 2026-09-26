import Foundation

/// La **normalisation** des silences lus par le lot 4 en l'entrée exacte du plan de morceaux
/// (plan §4 lot 7, révision 6 ; arbitrage `t_e3167e58`).
///
/// **Ce que ce type fait, et la seule chose qu'il fait.** `FfmpegCommand.silenceIntervals` (lot 4)
/// lit la sortie d'`ffmpeg -af silencedetect` et rend des ``FfmpegSilence`` — des bornes brutes,
/// telles qu'`ffmpeg` les a écrites (`4.000063`), potentiellement au-delà de la fin du fichier.
/// `VideoTranscriptionPlan.units(duration:silences:nominal:)` (lot 3) consomme des intervalles
/// **fermés** `[début, fin]` en secondes de l'audio décodé. `SilenceMap` est le seul endroit où
/// l'un devient l'autre.
///
/// **Il ne parse pas.** Il n'y a qu'un analyseur de la sortie de `silencedetect` dans le plan, et
/// il est au lot 4 (`FfmpegCommand.silenceIntervals(inFfmpegOutput:)`) : deux analyseurs de la même
/// sortie divergeraient.
///
/// **Il ne choisit pas les points de coupe.** La règle — silence le plus proche du multiple du pas,
/// tolérance ± 30 s, coupe forcée marquée, grille 16 kHz — est gelée par `VideoTranscriptionPlan`
/// au lot 3, déjà implémenté. `SilenceMap` lui **donne à manger** des intervalles propres ; il ne
/// décide pas de ce qu'on en fait.
///
/// **Contrat gelé par la carte QA L7** — `intervals(from:duration:)` :
///
/// 1. intervalles **fermés** `[début, fin]`, en secondes de l'audio décodé, `début <= fin`
///    (c'est la sémantique du lot 3 : un intervalle fermé de silence) ;
/// 2. bornes ramenées à la **grille du WAV décodé** — des multiples entiers de
///    `1 / VideoTranscriptionPlan.sampleRate` (16 kHz), à l'échantillon le plus proche. C'est ce
///    qui porte la phrase du §2.1 (« durée exacte au multiple d'échantillon près ») : les bornes
///    rendues sont sur la grille, donc les `start` et `duration` des unités du lot 3 le sont aussi,
///    et le recollage des horodatages (`début_abrégé + horodatage_local`) est exact ;
/// 3. bornes **bornées à `[0, duration]`** : un silence à cheval sur la fin du fichier est ramené à
///    `duration` — ni écarté en bloc, ni laissé hors fichier ;
/// 4. intervalle **dégénéré écarté** : `fin <= début` **après** normalisation (donc un silence
///    entièrement hors fichier, ramené à `[0, 0]`, disparaît) ;
/// 5. résultat **trié par début croissant** ; `duration <= 0` ou liste vide → `[]`.
///
/// Ces bornes ne sont pas des paramètres : `silencedetect=noise=-30dB:duration=0.5` est l'affaire
/// du lot 4 (§2.1), et `SilenceMap` ne voit jamais les paramètres de détection, seulement
/// `[FfmpegSilence]`.
public enum SilenceMap {
    /// Les silences normalisés, prêts pour
    /// ``VideoTranscriptionPlan/units(duration:silences:nominal:)``.
    ///
    /// - Parameters:
    ///   - silences: ce que le lot 4 a lu dans la sortie d'`ffmpeg`, dans n'importe quel ordre —
    ///     bornes brutes, éventuellement hors grille, éventuellement hors fichier.
    ///   - duration: la durée de l'audio **décodé**, en secondes ; c'est la borne haute du fichier
    ///     et la référence de la couverture (critère 9).
    /// - Returns: les intervalles fermés `[début, fin]` de silence, sur la grille 16 kHz, bornés au
    ///   fichier, dégénérés écartés, triés par début croissant.
    public static func intervals(from silences: [FfmpegSilence], duration: Double)
        -> [ClosedRange<Double>]
    {
        guard duration > 0 else { return [] }

        // La borne haute du fichier **sur la grille** : une durée qui ne tomberait pas sur un
        // échantillon (elle est pourtant toujours un nombre entier d'échantillons pour un WAV)
        // est ramenée à l'échantillon inférieur. Rabattre une borne sur `duration` sans arrondir
        // la ferait sortir de la grille — et la grille est ce qui rend le recollage des
        // horodatages exact (§2.1) : les deux propriétés doivent tenir ensemble, donc c'est la
        // plus contraignante qui gagne, et jamais au prix d'un dépassement du fichier.
        let finDuFichier = surLaGrille(duration)

        var rendus: [ClosedRange<Double>] = []
        for silence in silences {
            // Arrondir d'abord, borner ensuite : un silence entièrement hors fichier se réduit
            // alors à `[0, 0]` (ou `[duration, duration]`) et disparaît par la règle du
            // dégénéré, au lieu d'être écarté en bloc (règle 3 du contrat).
            let debut = min(max(surLaGrille(silence.start), 0), finDuFichier)
            let fin = min(max(surLaGrille(silence.end), 0), finDuFichier)
            // `fin <= début` **après** normalisation : un intervalle fermé vide n'est pas un
            // silence, et le donner au lot 3 ferait chercher une coupe dans rien.
            guard fin > debut else { continue }
            rendus.append(debut...fin)
        }
        // L'ordre de la sortie de `ffmpeg` n'est pas contractuel (et l'appelant peut donner
        // n'importe quel ordre) : ce que le lot 3 consomme est trié par début croissant.
        return rendus.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// L'échantillon le plus proche de `temps` sur la grille du WAV décodé
    /// (`VideoTranscriptionPlan.sampleRate`, 16 kHz — §2.1). Une seule définition de la grille
    /// dans le module : elle vient du lot 3, pas d'une constante recopiée ici.
    private static func surLaGrille(_ temps: Double) -> Double {
        (temps * VideoTranscriptionPlan.sampleRate).rounded() / VideoTranscriptionPlan.sampleRate
    }
}
