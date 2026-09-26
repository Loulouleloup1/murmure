import Foundation
import MurmureCore

/// The first use of `yt-dlp`: fetch the official binary, lift its quarantine, sign it ad-hoc --
/// and update it when an acquisition fails (plan §4 lot 6, SPEC criteria 5 and 6, decision R5).
///
/// **This file lives in the app target and therefore has no tests, and that is a property of the
/// target rather than an omission** (the same statement `EmbeddedTools.swift` makes for itself):
/// the app has no test bundle, so nothing here can be covered by `swift test`. The *decisions*
/// this file obeys are not taken here -- `AcquisitionDiagnostics.bootstrapStep(for:)` says
/// install-or-reuse, `recoveryStep(updateAlreadyAttempted:)` says update-or-report, and
/// `ytDlpDownloadURL` is the pinned address. All three are in `MurmureCore`, all three are
/// covered, and this file only executes what they decided.
///
/// **Why the quarantine has to be lifted at all, and why it is not silent (R5).** `curl` does not
/// set the quarantine attribute; `URLSession` does (measured, plan §8). So an application that
/// downloads this way deliberately removes an attribute macOS put there on purpose -- and the
/// user is told what is being downloaded rather than discovering it from a Gatekeeper dialog.
/// ``Step`` is that announcement: it is emitted *before* the download starts, not after it
/// finished.
///
/// **Why ad-hoc signing is not optional.** On arm64 a downloaded executable that is not signed
/// does not run at all (`code object is not signed at all`, measured and restated by
/// `scripts/checks/ytdlp-bootstrap.sh`). An unsigned binary would therefore pass every check
/// except the one that matters -- it would be installed and unusable.
///
/// **What is never done here.** No JavaScript runtime is fetched or embedded (plan §2.3: adding
/// Deno is a second third-party binary with its own quarantine, signature, update and JIT
/// authorisation, for a benefit never observed on our sources). And no output is journaled: the
/// steps below carry byte counts and versions, never file contents.
enum YtDlpInstaller {
    /// What the application tells the user while it works (R5: never silent).
    enum Step: Equatable {
        /// Asking the installed binary for its version -- nothing is downloaded when it answers.
        case checkingExisting
        /// The download has *started*, and this is what it is fetching. Emitted before the first
        /// byte, so the announcement cannot be skipped by a failure.
        case announcingDownload(URL)
        case downloading(receivedBytes: Int64, expectedBytes: Int64?)
        /// `xattr -d com.apple.quarantine` has run and there is nothing left to lift.
        case quarantineLifted
        /// `codesign --force --sign -` has run.
        case signedAdHoc
        /// The installed binary is being replaced by a newer release (`-U`).
        case updating
        /// Terminal state: the binary at its place answers its version.
        case ready(version: String)
    }

    /// A step that could not be completed. `Subprocess` already refuses to *launch*, so what is
    /// left to report is a non-zero exit code or an unusable result.
    struct Failure: Error, Equatable {
        let step: String
        let message: String
    }

    /// Absolute paths, never names resolved through `PATH`: the two helpers below are system
    /// tools, and looking them up in the user's environment would make the outcome depend on it
    /// (`Subprocess` refuses the `PATH` for the same reason).
    private static let xattr = URL(fileURLWithPath: "/usr/bin/xattr")
    private static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")

    /// What the installer **observes** before it acts (criterion 6).
    ///
    /// `--version` is what makes `present` mean something: a file that is there but cannot be
    /// executed -- unsigned, quarantined, truncated by an interrupted download -- is `absent`, so
    /// the next acquisition reinstalls it instead of failing forever against a broken binary.
    static func state(of binary: URL) -> AcquisitionDiagnostics.ToolState {
        version(of: binary).map { .present(version: $0) } ?? .absent
    }

    /// The version the binary at this path reports, or `nil` when there is nothing usable there.
    static func version(of binary: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        guard let result = try? Subprocess.run(binary, arguments: ["--version"], timeout: 60),
            result.exitCode == 0
        else { return nil }
        let line = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? nil : line
    }

    /// Downloads the pinned official binary, lifts its quarantine and signs it ad-hoc.
    ///
    /// Called **only** when `state(of:)` answered `.absent` -- that is criterion 6's "no
    /// re-download" half, and it is enforced by the caller rather than by a guard here, so the
    /// decision stays testable in `MurmureCore`.
    @discardableResult
    static func install(
        onto binary: URL = EmbeddedTools.ytDlp(),
        onStep: @escaping (Step) -> Void = { _ in }
    ) async throws -> AcquisitionDiagnostics.ToolState {
        onStep(.checkingExisting)
        // The announcement comes first, and it names what is about to be fetched: this is the
        // whole of R5, and putting it after the download would make it a receipt rather than a
        // notice.
        onStep(.announcingDownload(AcquisitionDiagnostics.ytDlpDownloadURL))

        let downloader = Downloader(url: AcquisitionDiagnostics.ytDlpDownloadURL) { received, expected in
            onStep(.downloading(receivedBytes: received, expectedBytes: expected))
        }
        let temporary = try await downloader.start()

        guard let http = downloader.response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(
                step: "download",
                message:
                    "HTTP \((downloader.response as? HTTPURLResponse)?.statusCode ?? -1) for "
                    + AcquisitionDiagnostics.ytDlpDownloadURL.absoluteString)
        }

        let tools = binary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: binary.path) {
            try FileManager.default.removeItem(at: binary)
        }
        try FileManager.default.moveItem(at: temporary, to: binary)
        // An executable bit is part of the download having produced a *program*; the mode of a
        // file dropped by `URLSession` follows the umask and is not guaranteed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path)

        try liftQuarantine(of: binary, onStep: onStep)
        try signAdHoc(binary, onStep: onStep)

        guard let version = version(of: binary) else {
            throw Failure(
                step: "verify",
                message: "the installed binary at \(binary.path) does not answer --version")
        }
        onStep(.ready(version: version))
        return .present(version: version)
    }

    /// Replaces the binary with the latest release (`-U`) and **re-applies both attributes**.
    ///
    /// The re-application is not defensive: `-U` writes a new file, and a new file carries neither
    /// the ad-hoc signature of the old one nor (when the updater wrote through a downloaded
    /// payload) its absence of quarantine. Skipping it would leave a binary that no longer runs,
    /// which is strictly worse than the stale one it replaced.
    @discardableResult
    static func update(
        onto binary: URL = EmbeddedTools.ytDlp(),
        onStep: @escaping (Step) -> Void = { _ in }
    ) async throws -> AcquisitionDiagnostics.ToolState {
        onStep(.updating)
        let result = try Subprocess.run(binary, arguments: ["-U"], timeout: 600)
        // A failed `-U` is not thrown: the caller is on its way to announcing an acquisition
        // failure anyway, and replacing that diagnosis with "the update failed" would hide the
        // source's own error. What is thrown is a binary that no longer works afterwards.
        if result.exitCode == 0 {
            try liftQuarantine(of: binary, onStep: onStep)
            try signAdHoc(binary, onStep: onStep)
        }
        guard let version = version(of: binary) else {
            throw Failure(
                step: "update",
                message:
                    "yt-dlp -U exited \(result.exitCode) and the binary at \(binary.path) no longer "
                    + "answers --version")
        }
        onStep(.ready(version: version))
        return .present(version: version)
    }

    // MARK: - The two attributes macOS cares about

    /// `xattr -d com.apple.quarantine`. A binary with no quarantine attribute makes `xattr` exit
    /// non-zero with `No such xattr` -- that is success, not a failure, and it is the one message
    /// this check tolerates.
    private static func liftQuarantine(of binary: URL, onStep: (Step) -> Void) throws {
        let result = try Subprocess.run(
            xattr, arguments: ["-d", "com.apple.quarantine", binary.path], timeout: 30)
        let text = result.stderr + result.stdout
        guard result.exitCode == 0 || text.lowercased().contains("no such xattr") else {
            throw Failure(
                step: "quarantine",
                message:
                    "xattr -d com.apple.quarantine exited \(result.exitCode): "
                    + String(text.prefix(200)))
        }
        onStep(.quarantineLifted)
    }

    /// `codesign --force --sign -`: the ad-hoc signature an arm64 executable needs to run at all.
    private static func signAdHoc(_ binary: URL, onStep: (Step) -> Void) throws {
        let result = try Subprocess.run(
            codesign, arguments: ["--force", "--sign", "-", binary.path], timeout: 120)
        guard result.exitCode == 0 else {
            throw Failure(
                step: "signature",
                message:
                    "codesign --force --sign - exited \(result.exitCode): "
                    + String((result.stderr + result.stdout).prefix(200)))
        }
        onStep(.signedAdHoc)
    }
}

/// Fetches the binary and reports every byte count while it is happening.
///
/// **Why not the async `URLSession.download(for:delegate:)`.** That call takes a
/// `URLSessionTaskDelegate`, and the per-chunk callback (`didWriteData`) belongs to
/// `URLSessionDownloadDelegate`: a task delegate is never handed the byte counts. Measured on the
/// first real acquisition -- the download of 36.9 MB reported *no* progress step at all, only the
/// announcement and the final `ready`. That is not "progression visible" (criterion 5), so the
/// session owns a delegate that is actually told, and the async shape is rebuilt on a
/// continuation.
///
/// `location` is deleted as soon as `didFinishDownloadingTo` returns: the file is moved out of the
/// way there, and the caller is handed that copy rather than a path that no longer exists.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let report: (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var moved: URL?
    private var moveFailure: Error?

    private lazy var session = URLSession(
        // Ephemeral: a 37 MB executable has no business staying in the shared cache.
        configuration: .ephemeral, delegate: self, delegateQueue: nil)

    /// The transfer's HTTP response, readable once ``start()`` has returned.
    private(set) var response: URLResponse?

    init(url: URL, report: @escaping (Int64, Int64?) -> Void) {
        self.url = url
        self.report = report
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        // GitHub answers with a redirect and the final response sometimes omits the length: an
        // unknown total is reported as `nil` rather than as a zero the interface would draw.
        report(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmure-yt-dlp-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            moved = kept
        } catch {
            moveFailure = error
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        response = task.response
        session.finishTasksAndInvalidate()
        let continuation = self.continuation
        self.continuation = nil
        if let error {
            continuation?.resume(throwing: error)
            return
        }
        if let moveFailure {
            continuation?.resume(throwing: moveFailure)
            return
        }
        guard let moved else {
            continuation?.resume(
                throwing: YtDlpInstaller.Failure(
                    step: "download", message: "the transfer finished without a file"))
            return
        }
        continuation?.resume(returning: moved)
    }
}
