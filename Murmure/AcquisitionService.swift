import Foundation
import MurmureCore

/// What a failed acquisition hands to the interface: the message that names the cause, and the
/// block the user copies in one click (SPEC criterion 7 and the tour 4 decision -- "show the raw
/// information with a copy button").
///
/// **It is an `Error` and not a value the caller inspects afterwards**, because the two travel
/// together: a caller that caught this has nothing left to continue with, and a caller that did
/// not catch it cannot show a block for a failure it does not know about.
///
/// The type does not compose the text -- `AcquisitionDiagnostics.failureReport` does -- and it
/// splits that report rather than re-writing it. The composition is the core's contract and is
/// frozen there ("the message, a blank line, the raw block"), so none of the three classification
/// sentences exists twice.
struct AcquisitionProblem: Error, Equatable {
    /// The sentence the panel shows as its headline.
    let message: String
    /// The whole report, message included: this is what the copy button delivers.
    let block: String

    init(report: String) {
        // The message is the report's first paragraph. `failureReport` writes the three sentences
        // as single lines, and `AcquisitionBootstrapDiagnosticsTests` keeps the block's own shape
        // honest; splitting on the blank line therefore cannot eat half a sentence.
        if let blank = report.range(of: "\n\n") {
            message = String(report[report.startIndex..<blank.lowerBound])
        } else {
            message = report
        }
        block = report
    }
}

/// Turning a source into an audio file, for the case where the source is a link and for the case
/// where it is a file on disk (plan §4 lot 6, SPEC criteria 1, 2, 3, 5, 6 and 8).
///
/// **One code path for YouTube and X.** `YtDlpCommand.download(_:toolsDirectory:into:)` is given
/// the source and returns either an invocation or a local file; nothing here branches on which
/// site a URL belongs to, and criterion 2 is that absence of a branch.
///
/// **A local file never reaches `yt-dlp`, and that is structural rather than conditional.** The
/// file case returns before the installer is consulted and before any `Process` exists, so there
/// is no socket to open -- criterion 3 is held by the shape of the code, not by a flag someone
/// could flip. The lot 4 contract already pins the same thing from the other side: for a local
/// path, `YtDlpCommand` builds no argument vector at all.
///
/// **One invocation, metadata included.** `--write-info-json` makes `yt-dlp` write the metadata
/// while it downloads; a second call to read the duration would pay the measured 13-16 s of
/// PyInstaller startup twice for one fact (plan §8).
enum AcquisitionService {
    /// What the acquisition produced, and what the caller still has to decide with it.
    struct Acquired: Equatable {
        let source: TranscriptSource
        /// The audio the transcription will read: the downloaded file, or the local one.
        let audio: URL
        /// The metadata read from the *same* invocation, or `nil` for a local file -- nothing
        /// announced a duration for a file nobody fetched, and inventing one would break
        /// criterion 1's ± 1 s comparison.
        let metadata: YtDlpMetadata?
        /// The optional subtitle choices, provenance included, default first (criterion 8).
        let subtitles: [AcquisitionDiagnostics.SubtitleOption]
        /// What actually runs for this acquisition, resolved from the user's selection.
        let choice: AcquisitionDiagnostics.SubtitleChoice
        /// The job's working directory, kept for the resume path (plan §2.4).
        let workDirectory: URL
    }

    /// What the caller can show while the acquisition runs (R5: the download is announced, never
    /// silent; criterion 5: the progress of the first use is visible).
    enum Event: Equatable {
        case started(source: String)
        /// Announced **before** the first byte of `yt-dlp` is fetched.
        case installing(reason: String)
        case installer(YtDlpInstaller.Step)
        /// The version already present is reused: no re-download (criterion 6).
        case reusing(version: String)
        /// `-U` is being attempted before the failure is announced (criterion 6).
        case updatingBeforeFailure(version: String)
        /// One line of `yt-dlp`'s own progress on `stdout`.
        case progress(line: String)
        case acquired(seconds: Double?)
        /// A local file: no network was touched (criterion 3).
        case localFileWithoutNetwork(path: String)
    }

    /// Acquires `source` into `workDirectory`.
    ///
    /// - Parameter subtitle: the option the user selected, or `nil` when there was no explicit
    ///   choice -- which is the default and is resolved by
    ///   `AcquisitionDiagnostics.subtitleChoice(for:)`, not here.
    static func acquire(
        _ source: TranscriptSource,
        into workDirectory: URL,
        applicationSupport: URL = Storage.url(),
        subtitle: AcquisitionDiagnostics.SubtitleOption? = nil,
        onEvent: @escaping (Event) -> Void = { _ in }
    ) async throws -> Acquired {
        let label = source.url?.absoluteString ?? source.path ?? ""
        onEvent(.started(source: label))

        let binary = EmbeddedTools.ytDlp(in: applicationSupport)
        let action = try YtDlpCommand.download(
            source, toolsDirectory: binary.deletingLastPathComponent(), into: workDirectory)

        // MARK: The local case, which stops before any process exists
        //
        // Criterion 3: nothing below this `switch` runs for a file on disk. There is no installer
        // to consult (a local file needs no tool at all), no invocation, and therefore no socket.
        if case let .localFile(file) = action {
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw AcquisitionProblem(
                    report: AcquisitionDiagnostics.failureReport(
                        kind: .localFileUnreadable,
                        source: label,
                        ytDlpVersion: "",
                        exitCode: 1,
                        stderr: "no such readable file: \(label)\n",
                        redacting: [workDirectory.path]))
            }
            onEvent(.localFileWithoutNetwork(path: file.path))
            return Acquired(
                source: source,
                audio: file,
                metadata: nil,
                subtitles: [localTranscription],
                choice: AcquisitionDiagnostics.subtitleChoice(for: nil),
                workDirectory: workDirectory)
        }
        guard case let .download(invocation) = action else {
            // Unreachable: `YtDlpCommand.Action` has two cases and the first one is handled above.
            // Kept as a throw rather than a `fatalError`, because an app that aborts is worse than
            // an app that reports (plan §7.1 rule 3).
            throw AcquisitionProblem(
                report: AcquisitionDiagnostics.failureReport(
                    kind: .localFileUnreadable,
                    source: label,
                    ytDlpVersion: "",
                    exitCode: 1,
                    stderr: "the source produced neither an invocation nor a local file\n",
                    redacting: [workDirectory.path]))
        }

        // MARK: First use (criterion 5) and no re-download (criterion 6)
        //
        // The decision is `AcquisitionDiagnostics.bootstrapStep`, which is covered by tests; what
        // follows is only its execution.
        switch AcquisitionDiagnostics.bootstrapStep(for: YtDlpInstaller.state(of: binary)) {
        case .install:
            onEvent(.installing(reason: "yt-dlp is not installed at \(binary.path)"))
            do {
                _ = try await YtDlpInstaller.install(
                    onto: binary, onStep: { onEvent(.installer($0)) })
            } catch {
                // `.toolNotInstalled`, and it is *not* routed through `recoveryStep`: a tool that
                // was never installed has nothing to update, and "the update failed" would send
                // the user down the wrong path (`AcquisitionDiagnostics.FailureKind`).
                throw AcquisitionProblem(
                    report: AcquisitionDiagnostics.failureReport(
                        kind: .toolNotInstalled,
                        source: label,
                        ytDlpVersion: "",
                        exitCode: 1,
                        stderr: "\(error)\n",
                        redacting: [workDirectory.path]))
            }
        case .reuse:
            if case let .present(version) = YtDlpInstaller.state(of: binary) {
                onEvent(.reusing(version: version))
            }
        case .update, .report:
            // Neither is reachable from here: `bootstrapStep` returns them only for the state of a
            // tool that already failed an acquisition, which is `recoveryStep`'s half below.
            break
        }

        // MARK: One invocation: metadata and audio together
        var result = try run(invocation, timeout: Self.downloadTimeout, onEvent: onEvent)
        if result.exitCode != 0 {
            // Criterion 6: the update is attempted **before** the failure is announced, and it is
            // attempted once -- `recoveryStep` is what says so, and it is what stops a durably
            // unreachable source from looping the application on `-U`.
            if AcquisitionDiagnostics.recoveryStep(updateAlreadyAttempted: false) == .update {
                onEvent(.updatingBeforeFailure(version: YtDlpInstaller.version(of: binary) ?? ""))
                _ = try? await YtDlpInstaller.update(
                    onto: binary, onStep: { onEvent(.installer($0)) })
                result = try run(invocation, timeout: Self.downloadTimeout, onEvent: onEvent)
            }
            if result.exitCode != 0 {
                throw AcquisitionProblem(
                    report: AcquisitionDiagnostics.failureReport(
                        kind: .sourceUnavailable,
                        source: label,
                        // The version **as observed**, never inferred from the download URL: it is
                        // the whole point of the block the user pastes to their agent.
                        ytDlpVersion: YtDlpInstaller.version(of: binary) ?? "",
                        exitCode: result.exitCode,
                        stderr: result.stderr,
                        redacting: [workDirectory.path, invocation.infoJSON.path]))
            }
        }

        // MARK: Metadata, read from the file the *same* invocation wrote
        let metadata = try YtDlpCommand.metadata(Data(contentsOf: invocation.infoJSON))
        let audio = try audioFile(in: workDirectory)
        let options = AcquisitionDiagnostics.subtitleOptions(from: metadata)
        // Criterion 8: without an explicit choice, what runs is the local transcription. The
        // decision is the core's; the service only carries it.
        let choice = AcquisitionDiagnostics.subtitleChoice(for: subtitle)
        onEvent(.acquired(seconds: metadata.duration))
        return Acquired(
            source: source,
            audio: audio,
            metadata: metadata,
            subtitles: options,
            choice: choice,
            workDirectory: workDirectory)
    }

    /// The only subtitle option a source on disk can offer: our own transcription.
    private static let localTranscription = AcquisitionDiagnostics.SubtitleOption(
        language: nil, provenance: .local, label: "Local transcription (local)")

    /// Long enough for a long video on a slow link, and bounded so a hung `yt-dlp` is a failure
    /// with a block rather than a process the app waits on forever.
    private static let downloadTimeout: TimeInterval = 900

    private static func run(
        _ invocation: YtDlpCommand.Invocation, timeout: TimeInterval,
        onEvent: @escaping (Event) -> Void
    ) throws -> SubprocessResult {
        try Subprocess.run(
            invocation.executable,
            arguments: invocation.arguments,
            timeout: timeout,
            // `yt-dlp` writes its progress on `stdout` (`--newline`): forwarded as it arrives, so
            // the acquisition has a visible progression and not just a spinner.
            currentDirectory: invocation.workingDirectory,
            onLine: { onEvent(.progress(line: $0)) })
    }

    /// The audio `yt-dlp` wrote into the job's directory: `source.<ext>`, never the
    /// `source.info.json` that came with it.
    private static func audioFile(in directory: URL) throws -> URL {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard
            let name = names.first(where: {
                $0.hasPrefix("source.") && !$0.hasSuffix(".info.json")
            })
        else {
            throw AcquisitionProblem(
                report: AcquisitionDiagnostics.failureReport(
                    kind: .sourceUnavailable,
                    source: directory.path,
                    ytDlpVersion: "",
                    exitCode: 0,
                    stderr: "yt-dlp exited 0 but wrote no audio file in \(directory.path)\n",
                    redacting: [directory.path]))
        }
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
