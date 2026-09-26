import Foundation
import MurmureCore

/// Les **tranches WAV** d'un travail de transcription : une unité du plan (lot 3), un fichier
/// (plan §2.1 et §4 lot 7).
///
/// **Ce fichier n'a pas de tests, et c'est une propriété de la cible, pas un oubli** (la cible
/// app n'a pas de bundle de tests, cf. `EmbeddedTools.swift`) : la décision — où couper, combien
/// d'unités, quelle qualité — appartient à `VideoTranscriptionPlan` (lot 3, testé), la commande à
/// `FfmpegCommand` (lot 4, testé). Ici il ne reste que l'exécution et la remise au pas des
/// fichiers produits.
///
/// **Ce qui est coupé est le WAV décodé 16 kHz mono, jamais la source compressée** (§2.1) : sur un
/// m4a ou un Opus, les frontières ne sont pas échantillon-exactes et la dérive s'accumulerait sur
/// 48 unités sans qu'aucun critère ne l'attrape. La lecture se fait par `-ss` **avant** `-i`
/// (mesuré sur le binaire embarqué : le début de la tranche tombe exactement sur l'échantillon
/// demandé), et la copie est `-c copy` — aucun ré-encodage.
///
/// **L'audio ne traverse jamais notre processus** : `ffmpeg` lit le WAV et écrit la tranche ;
/// nous ne touchons que des en-têtes (voir ``align(_:toSamples:index:)``).
enum UnitSlicer {
    /// Une tranche écrite : l'unité du plan et le fichier qui la porte.
    struct Slice: Equatable {
        /// Le rang de l'unité dans le plan (0-based, l'ordre de `VideoTranscriptionPlan.units`).
        var index: Int
        /// Le début absolu de l'unité, en secondes de l'audio décodé — **la même valeur** que
        /// `UnitBoundary.start`, donc l'offset du recollage des horodatages (§2.1).
        var start: Double
        /// La durée **exacte** de l'unité, en secondes : c'est le nombre d'échantillons réellement
        /// écrits dans `url` (voir ``align(_:toSamples:index:)``). La somme de ces durées vaut la
        /// durée du WAV, à l'échantillon près.
        var duration: Double
        /// Le fichier écrit.
        var url: URL
    }

    /// Ce qui peut empêcher une tranche d'être produite. Aucun de ces cas ne se tait : une tranche
    /// manquante ou trop courte deviendrait un trou dans les horodatages, et le recollage
    /// (`début_unitié + horodatage_local`) rendrait ce trou invisible.
    enum Failure: Error, Equatable {
        case cannotStart(index: Int, executable: String, reason: String)
        case failed(index: Int, exitCode: Int32, excerpt: String)
        case timedOut(index: Int, excerpt: String)
        /// La tranche n'est pas du PCM 16 bits mono : ce n'est pas la sortie du décodage (§2.1),
        /// donc la grille d'échantillons ne veut rien dire.
        case notSixteenBitMono(index: Int, channels: Int, bitsPerSample: Int)
        /// Les en-têtes RIFF de la tranche sont illisibles : mieux vaut le dire que de rendre un
        /// fichier dont on ne sait rien.
        case malformedWav(index: Int, reason: String)
        /// `ffmpeg` a écrit **moins** d'échantillons que l'unité n'en demande : le fichier est plus
        /// court que le plan, donc une seconde manquerait à la couverture.
        case shortSlice(index: Int, samples: Int, written: Int)
    }

    /// Le nom d'une tranche : `0000.wav`, `0042.wav`, `1234.wav` — **la convention du répertoire de
    /// travail du lot 2** (`TranscriptWorkDirectory.unitURL(index:)`), qui est le seul endroit où
    /// les tranches vivent (`<base>/work/<jobID>/units/`, §2.4). Elle est répétée ici parce que ce
    /// fichier-ci n'a pas de dépendance sur le type du lot 2 : l'appelant donne le dossier, et les
    /// URL rendues dans ``Slice`` sont la vérité — il n'a pas à les reconstruire.
    static func fileName(index: Int) -> String {
        String(format: "%04d.wav", index)
    }

    /// Écrit une tranche par unité, dans l'ordre du plan.
    ///
    /// - Parameters:
    ///   - wav: le WAV **décodé** 16 kHz mono (§2.1) — jamais la source compressée.
    ///   - units: le plan du lot 3 (`VideoTranscriptionPlan.units(duration:silences:nominal:)`).
    ///   - unitsDirectory: `<base>/work/<jobID>/units/` (§2.4). Créé si besoin : une reprise
    ///     (statut `inProgress`) repasse par ici sans rien casser.
    ///   - ffmpeg: le binaire embarqué (lot 5) — jamais un nom résolu par le `PATH` (critère 4).
    /// - Returns: les tranches écrites, dans l'ordre des unités, avec la durée **réellement**
    ///   écrite (voir ``align(_:toSamples:index:)``).
    static func write(
        wav: URL,
        units: [UnitBoundary],
        into unitsDirectory: URL,
        ffmpeg: URL,
        timeout: TimeInterval = 900
    ) throws -> [Slice] {
        try FileManager.default.createDirectory(
            at: unitsDirectory, withIntermediateDirectories: true)

        var slices: [Slice] = []
        for (index, unit) in units.enumerated() {
            let url = unitsDirectory.appendingPathComponent(fileName(index: index))
            // `FfmpegCommand.slice` fige la forme de l'appel (`-ss` avant `-i`, `-t`, `-c copy`) :
            // elle n'est pas réécrite ici (règle 9).
            let invocation = FfmpegCommand.slice(
                wav, at: unit.start, duration: unit.duration, to: url, ffmpeg: ffmpeg)
            try run(invocation, index: index, timeout: timeout)

            let samples = Self.samples(of: unit.duration)
            try align(url, toSamples: samples, index: index)
            slices.append(
                Slice(
                    index: index,
                    start: unit.start,
                    duration: unit.duration,
                    url: url))
        }
        return slices
    }

    /// Le nombre d'échantillons que l'unité demande, sur la grille de `VideoTranscriptionPlan`
    /// (le lot 3 garantit que `duration` y est déjà, à l'arrondi flottant près).
    private static func samples(of duration: Double) -> Int {
        Int((duration * VideoTranscriptionPlan.sampleRate).rounded())
    }

    /// Lance une invocation et refuse tout ce qui n'est pas un succès franc.
    private static func run(
        _ invocation: FfmpegCommand.Invocation, index: Int, timeout: TimeInterval
    ) throws {
        let result: SubprocessResult
        do {
            result = try Subprocess.run(
                invocation.executable, arguments: invocation.arguments, timeout: timeout)
        } catch let error as SubprocessError {
            switch error {
            case let .launchFailed(executable, reason):
                throw Failure.cannotStart(index: index, executable: executable, reason: reason)
            }
        } catch {
            throw Failure.cannotStart(
                index: index, executable: invocation.executable.path,
                reason: error.localizedDescription)
        }
        if result.timedOut {
            throw Failure.timedOut(index: index, excerpt: excerpt(result.stderr))
        }
        guard result.exitCode == 0 else {
            throw Failure.failed(
                index: index, exitCode: result.exitCode, excerpt: excerpt(result.stderr))
        }
    }

    /// Ramène la tranche écrite à **exactement** le nombre d'échantillons que son unité demande.
    ///
    /// **Pourquoi c'est nécessaire, et ce n'est pas une précaution de style.** `-t` avec `-c copy`
    /// ne coupe pas au milieu d'un paquet : `ffmpeg` écrit le dernier paquet entier. Mesuré sur le
    /// binaire embarqué, WAV 16 kHz mono (paquets de 1024 échantillons) : 300 s demandées →
    /// 300,032 s écrites, 102,599 s demandées → 102,656 s écrites. Sans cette remise au pas, deux
    /// tranches voisines se **recouvrent** de 0 à 64 ms — le début de la suivante serait transcrit
    /// deux fois — et la somme des durées des fichiers dépasserait la durée du WAV, alors que le
    /// plan du lot 3, lui, la couvre exactement. La tranche est donc coupée sur son dernier
    /// échantillon réel.
    ///
    /// **Aucun octet d'audio n'est lu.** On lit les en-têtes RIFF (au plus quelques dizaines
    /// d'octets, dans les 16 Kio du début), on tronque le fichier au bon octet, et on réécrit les
    /// deux longueurs (RIFF et `data`). Le PCM n'est jamais parcouru — c'est la même contrainte que
    /// celle qui interdit de charger le WAV décodé entier.
    private static func align(_ url: URL, toSamples samples: Int, index: Int) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw Failure.malformedWav(index: index, reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        let header: Data
        do {
            header = try handle.read(upToCount: Self.headerWindow) ?? Data()
        } catch {
            throw Failure.malformedWav(index: index, reason: error.localizedDescription)
        }
        let layout = try chunkLayout(header, index: index)

        guard layout.channels == 1, layout.bitsPerSample == 16 else {
            throw Failure.notSixteenBitMono(
                index: index, channels: layout.channels, bitsPerSample: layout.bitsPerSample)
        }

        let bytesPerSample = 2
        let expected = samples * bytesPerSample
        guard layout.dataSize >= expected else {
            throw Failure.shortSlice(index: index, samples: samples, written: layout.dataSize / bytesPerSample)
        }
        // Déjà exact : ne pas réécrire un fichier qu'on n'a pas à toucher (une tranche déjà
        // correcte ne se réécrit pas, et l'écriture reste ainsi une opération rare).
        guard layout.dataSize > expected else { return }

        do {
            try handle.truncate(atOffset: UInt64(layout.dataOffset + expected))
            // Les deux longueurs de l'en-tête : la taille RIFF (octets qui suivent les 8 premiers)
            // et la taille du bloc `data`. Rien d'autre ne dépend du nombre d'échantillons.
            try write(
                UInt32(layout.dataOffset + expected - 8), into: handle, at: 4)
            try write(UInt32(expected), into: handle, at: layout.dataOffset - 4)
        } catch {
            throw Failure.malformedWav(index: index, reason: error.localizedDescription)
        }
    }

    /// La fenêtre des en-têtes RIFF lue par ``align(_:toSamples:index:)`` : `ffmpeg` place `fmt `
    /// et `data` dans les premiers centaines d'octets (un éventuel bloc `LIST`/`INFO` les sépare),
    /// jamais au-delà de quelques Kio.
    private static let headerWindow = 16 * 1024

    /// Ce qu'un en-tête WAV dit du bloc `data` et du format.
    private struct ChunkLayout {
        var dataOffset: Int
        var dataSize: Int
        var channels: Int
        var bitsPerSample: Int
    }

    /// Parcourt les blocs RIFF de `header` et rend l'emplacement du bloc `data` (offset du premier
    /// échantillon, taille déclarée) et le format du flux.
    private static func chunkLayout(_ header: Data, index: Int) throws -> ChunkLayout {
        func uint32(at offset: Int) -> Int? {
            guard offset + 4 <= header.count else { return nil }
            return Int(
                UInt32(header[offset]) | UInt32(header[offset + 1]) << 8
                    | UInt32(header[offset + 2]) << 16 | UInt32(header[offset + 3]) << 24)
        }
        func uint16(at offset: Int) -> Int? {
            guard offset + 2 <= header.count else { return nil }
            return Int(UInt16(header[offset]) | UInt16(header[offset + 1]) << 8)
        }
        func identifier(at offset: Int) -> String? {
            guard offset + 4 <= header.count else { return nil }
            return String(decoding: header[offset..<(offset + 4)], as: UTF8.self)
        }

        guard header.count >= 12, identifier(at: 0) == "RIFF", identifier(at: 8) == "WAVE" else {
            throw Failure.malformedWav(index: index, reason: "en-tête RIFF/WAVE absent")
        }

        var channels: Int?
        var bitsPerSample: Int?
        var position = 12
        while let identifier = identifier(at: position) {
            guard let size = uint32(at: position + 4) else { break }
            let payload = position + 8
            if identifier == "fmt " {
                channels = uint16(at: payload + 2)
                bitsPerSample = uint16(at: payload + 14)
            }
            if identifier == "data" {
                guard let channels, let bitsPerSample else {
                    throw Failure.malformedWav(index: index, reason: "bloc data avant le bloc fmt")
                }
                return ChunkLayout(
                    dataOffset: payload, dataSize: size,
                    channels: channels, bitsPerSample: bitsPerSample)
            }
            // Les blocs RIFF sont alignés sur un nombre pair d'octets.
            position = payload + size + (size % 2)
        }
        throw Failure.malformedWav(
            index: index, reason: "bloc data introuvable dans les \(headerWindow) premiers octets")
    }

    /// Écrit un entier 32 bits **petit-boutiste**, comme le veut RIFF.
    private static func write(_ value: UInt32, into handle: FileHandle, at offset: Int) throws {
        var little = value.littleEndian
        let bytes = withUnsafeBytes(of: &little) { Data($0) }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: bytes)
    }

    /// Un extrait de `stderr`, borné, sur le même motif que ``SilenceMapBuilder`` (lot 4 borne le
    /// bloc copié, pas la valeur d'erreur).
    private static func excerpt(_ stderr: String) -> String {
        String(stderr.prefix(2_000))
    }
}
