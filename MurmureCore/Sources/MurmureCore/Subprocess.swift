import Foundation

/// Le résultat d'un sous-processus terminé (plan §4 lot 4).
///
/// Les deux flux sont rendus **séparément et en entier** : `yt-dlp` écrit sa progression sur
/// `stdout` (avec `--newline`, une ligne par état) et `ffmpeg` écrit `silencedetect` sur `stderr`
/// — les mélanger rendrait la carte de silence illisible alors que c'est la seule sortie
/// exploitable de `-af silencedetect`.
public struct SubprocessResult: Equatable {
    /// Le code de sortie du processus. Sur un arrêt par signal, c'est le numéro du signal.
    public var exitCode: Int32
    /// Tout `stdout`, recollé.
    public var stdout: String
    /// Tout `stderr`, recollé. C'est cette chaîne que le bloc de diagnostic du critère 7 borne.
    public var stderr: String
    /// Vrai quand le délai a expiré et que le processus a été arrêté. Les deux flux contiennent
    /// alors ce qui avait été écrit jusque-là : un échec par expiration doit rester diagnosticable.
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Le seul échec que `Subprocess.run` lève : impossible de **lancer** le processus.
///
/// Un code de sortie non nul, un signal ou une expiration ne lèvent pas : ils sont des
/// *résultats*, et l'appelant doit pouvoir les diagnostiquer (critère 7).
public enum SubprocessError: Error, Equatable {
    case launchFailed(executable: String, reason: String)
}

/// Lancer un binaire externe et lire sa sortie (plan §4 lot 4).
///
/// **`onLine` reçoit les lignes de `stdout` au fil de l'eau**, pas à la fin : c'est ce qui rend la
/// progression du critère 18 possible, et un `yt-dlp` qui télécharge 73 Mo ne dit rien avant
/// d'avoir fini. `stderr` n'est pas diffusé ligne à ligne — il est rendu entier dans le résultat
/// (`result.stderr`), parce que ses seuls consommateurs (`silencedetect`, le bloc de diagnostic)
/// en ont besoin complet.
///
/// **L'environnement est celui qu'on donne, pas celui de l'appelant** : `environment` remplace
/// l'environnement hérité. Une acquisition qui partirait avec le `PATH`, les proxies et les
/// jetons de la session de l'utilisateur serait irreproductible, et le critère 3 (« zéro réseau »
/// sur un fichier local) se lirait dans un environnement qu'on ne contrôle pas.
///
/// **Jamais de journalisation du contenu** (AGENTS.md) : cette fonction ne journalise rien
/// elle-même, et le seul endroit où une chaîne de sortie est recopiée est le bloc de diagnostic
/// du critère 7, qui la borne.
public enum Subprocess {
    /// Lance `executable` (un **chemin absolu** : jamais un nom résolu par le `PATH`) et attend
    /// sa fin, au plus `timeout` secondes.
    ///
    /// - Parameter currentDirectory: le répertoire de travail du processus. `nil` laisse celui de
    ///   l'appelant ; l'acquisition, elle, passe le répertoire de travail du *job* (plan §2.4).
    /// - Parameter onLine: appelé pour chaque ligne de `stdout`, sans le saut de ligne final.
    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 300,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        onLine: ((String) -> Void)? = nil
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // `environment` **remplace** l'environnement hérité : ce n'est pas une fusion.
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Un outil qui lirait `stdin` attendrait un terminal qui ne répondra jamais.
        process.standardInput = FileHandle.nullDevice

        let stdout = OutputCapture(onLine: onLine)
        let stderr = OutputCapture(onLine: nil)
        let readers = DispatchGroup()
        read(stdoutPipe, into: stdout, group: readers)
        read(stderrPipe, into: stderr, group: readers)

        // Le gestionnaire est posé **avant** `run()` : un processus déjà terminé au moment où on
        // le poserait ne signalerait jamais sa fin, et l'attente irait jusqu'au délai.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            closeWritingEnds(of: [stdoutPipe, stderrPipe])
            throw SubprocessError.launchFailed(
                executable: executable.path, reason: error.localizedDescription)
        }
        // Le bout d'écriture reste ouvert dans *ce* processus : sans cette fermeture, les lecteurs
        // ne verraient jamais la fin du flux et attendraient indéfiniment.
        closeWritingEnds(of: [stdoutPipe, stderrPipe])

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + Self.terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + Self.terminationGrace)
            }
        }
        // Les deux flux sont à leur fin dès que le processus est parti et que nos bouts d'écriture
        // sont fermés : ce qui avait été écrit jusque-là est dans le résultat, y compris après une
        // expiration (un échec par expiration doit rester diagnosticable).
        readers.wait()
        stdout.deliverTrailingLine()
        stderr.deliverTrailingLine()

        return SubprocessResult(
            exitCode: process.terminationStatus,
            stdout: stdout.text,
            stderr: stderr.text,
            timedOut: timedOut)
    }

    /// Le délai laissé à un processus pour mourir après `terminate()`, puis après `SIGKILL`.
    /// Court : c'est un arrêt, pas une négociation.
    private static let terminationGrace: TimeInterval = 5

    /// Lit un tube jusqu'à sa fin, **sur son propre fil**, et rend chaque morceau au fur et à
    /// mesure. Un seul lecteur par descripteur : c'est ce qui rend l'ordre des lignes déterministe
    /// (deux lecteurs concurrents se partageraient les octets et pourraient les rendre dans le
    /// désordre).
    private static func read(_ pipe: Pipe, into capture: OutputCapture, group: DispatchGroup) {
        group.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count <= 0 { break }
                capture.append(Data(buffer[0..<count]))
            }
            group.leave()
        }
    }

    /// Ferme le bout d'écriture de chaque tube, dans le parent. Le `Process` en a déjà une copie.
    /// Fermer deux fois ne fait rien de nuisible : c'est le cas d'un lancement qui a échoué.
    private static func closeWritingEnds(of pipes: [Pipe]) {
        for pipe in pipes {
            try? pipe.fileHandleForWriting.close()
        }
    }
}

/// Ramasse un flux sortant : le texte entier, et les lignes au fil de l'eau.
///
/// Le verrou n'est pas décoratif : `append(_:)` est appelé depuis le fil de lecture, tandis que
/// `text` et `deliverTrailingLine()` sont lus depuis l'appelant — et `onLine` reçoit les lignes
/// **hors** du verrou, pour qu'un appelant qui ferait un travail lent (interface, écriture) ne
/// bloque pas la lecture du tube.
private final class OutputCapture {
    private let lock = NSLock()
    private var stream = Data()
    private var pending = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    /// Le flux entier, recollé.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.decode(stream)
    }

    func append(_ chunk: Data) {
        var lines: [String] = []
        lock.lock()
        stream.append(chunk)
        pending.append(chunk)
        while let end = pending.firstIndex(of: 0x0A) {
            lines.append(Self.decode(pending[pending.startIndex..<end]))
            pending.removeSubrange(pending.startIndex...end)
        }
        lock.unlock()
        deliver(lines)
    }

    /// Une sortie sans saut de ligne final reste une ligne : elle est rendue à la fin, pas perdue.
    func deliverTrailingLine() {
        lock.lock()
        let tail = pending.isEmpty ? nil : Self.decode(pending)
        pending.removeAll()
        lock.unlock()
        if let tail, !tail.isEmpty { deliver([tail]) }
    }

    private func deliver(_ lines: [String]) {
        guard let onLine else { return }
        for line in lines { onLine(line) }
    }

    /// `\r\n` est ramené à la ligne ; les octets d'une ligne sont décodés **entiers** (jamais un
    /// morceau de tube à la fois), sans quoi un caractère multi-octets coupé en deux se lirait mal.
    private static func decode<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}
