import Foundation
import MurmureCore

/// Loading the transcription model once, from a script, and saying out loud how long it takes.
///
/// **The measurement this exists for.** A first install on a second Mac spent 423 s inside the
/// first dictation -- `transcriptionSeconds = 423.47`, read out of the history afterwards -- and
/// looked exactly like a crash. It was not transcription: `sample` showed the thread parked in
/// `MLModel.modelWithContentsOfURL` -> `MLE5ProgramLibrary.prepareAndReturnError` for 2046 samples
/// out of 2046, with `ANECompilerService` at 100 % CPU and Murmure itself at 2 %, waiting. That is
/// CoreML compiling the model for this machine's neural engine, and Argmax documents the same cost
/// for this exact variant -- 440 s on an M4 Pro 48 GB, 560 s on an M2 Pro 32 GB, then 3-5 s on
/// every load after (WhisperKit#309). It is the nominal price of the variant, not a slow machine.
///
/// `ab090d5` made the wait legible -- the card now says "Loading model" instead of "Transcribing".
/// This moves it. At the end of an install somebody expects to wait; at their first dictation they
/// expect a sentence.
///
/// **Why a flag on this binary rather than a script that loads the model itself.** The alternatives
/// were a `swift`-run snippet or a `swiftc`-compiled helper against WhisperKit, and both lose the
/// same thing twice over. They would re-state the load -- variant, `downloadBase`, `modelFolder`,
/// every argument of `WhisperKit.init` -- in a second place that has to stay in step with
/// `WhisperKitEngine.load` and cannot be made to, and a warm-up that compiles a *different*
/// configuration warms nothing while reporting that it did. And they would run as a different,
/// ad-hoc-signed executable, where the compiled artefact's reuse by the real app is one more thing
/// nobody has measured. Going through `WhisperKitEngine.prepare()` inside the app bundle that
/// `install.sh` just signed means the warm-up is the same code, in the same binary, under the same
/// signature, reading the same store. There is nothing left to keep in step.
///
/// It never touches AppKit: `Launch` answers the flag before `MurmureApp.init` exists, so no ⌥Space
/// registration, no menu bar item, and above all no Accessibility prompt happens in a child process
/// of a shell script.
enum ModelWarmup {
    /// The argument that asks for this instead of the app. Spelled once, here; `scripts/bootstrap.sh`
    /// passes it and `Launch` reads it.
    static let flag = "--prepare-model"

    /// Loads the model and exits -- 0 when it loaded, 1 with the reason on stderr when it did not.
    ///
    /// **Nothing here needs cleaning up if it is interrupted, and that is a property of the load
    /// rather than a promise made about it.** The Hub downloads into a `.incomplete` file and
    /// resumes from it, so a ⌃C during the transfer costs nothing; a ⌃C during the compilation
    /// throws the compilation away and the next load starts it again -- which is exactly what the
    /// second Mac did twice, unknowingly, turning seven minutes into a perceived half hour. The
    /// script says so before it starts, and so does the app while it runs.
    ///
    /// `dispatchMain()` rather than a semaphore the main thread waits on: `report` is `@MainActor`
    /// and `WhisperKitEngine` awaits the hop, so a blocked main thread is a deadlock and not a
    /// wait. It never returns, which is why the exits below are inside the task.
    static func run() -> Never {
        say("Loading the transcription model, which compiles it for this machine.")
        let started = Date()
        let engine = WhisperKitEngine(progress: DecodeProgressBox()) { preparation in
            announce(preparation)
        }
        Task {
            do {
                try await engine.prepare()
                let seconds = Date().timeIntervalSince(started)
                say(String(format: "Done in %.0f s. Every later load takes seconds.", seconds))
                exit(0)
            } catch {
                let line = "    \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(line.utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// The last completed tenth announced, so that a download reporting every second for minutes
    /// prints eleven lines rather than a hundred. `-1` because 0 % is itself worth saying once.
    @MainActor private static var announcedTenths = -1

    /// The same `ModelPreparation` the notch and the panel are drawn from, said in a terminal.
    ///
    /// The sentences are longer than `StatusPanelText`'s because the surface is: a 158 pt slot has
    /// room for "Loading model" and a terminal has room for what that costs and why.
    @MainActor private static func announce(_ preparation: ModelPreparation?) {
        switch preparation {
        case .downloading(let download):
            let tenth = download.percent / 10
            guard tenth > announcedTenths else { return }
            announcedTenths = tenth
            say("Downloading model \(download.percent)%")
        case .loading:
            say("Compiling for the neural engine. On a FIRST run this takes minutes, holds")
            say("ANECompilerService at 100 % CPU and makes the whole machine feel slow.")
        case nil:
            break
        }
    }

    /// Indented four spaces to sit under `bootstrap.sh`'s own step headings, and flushed because
    /// stdout is block-buffered the moment this runs anywhere but a terminal -- a progress line
    /// held in a buffer until the process exits is a progress line that never existed.
    private static func say(_ line: String) {
        print("    \(line)")
        fflush(stdout)
    }
}
