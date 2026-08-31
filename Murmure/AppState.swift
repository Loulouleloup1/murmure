import MurmureCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle, recording, transcribing, inserting, failed
    }

    @Published var status: Status = .idle

    /// Set once, at launch, when Carbon refuses ⌥Space. There is no retry: the combination is
    /// taken for as long as the other application holds it, and a dead key with no explanation is
    /// exactly what task 4 refused to ship.
    @Published var hotkeyUnavailable = false

    /// The clipboard was not handed back intact. Cleared when the next dictation starts.
    @Published var clipboardWarning: String?

    /// Why the last dictation failed, in the user's words. Cleared when the next one starts.
    @Published var lastFailureMessage: String?

    var menuBarSymbol: String {
        switch status {
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "hourglass"
        case .inserting: "arrow.down.doc"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// Task 6's `RestoreOutcome` reaches a human here. A dictation that pasted correctly can still
    /// have destroyed what Louis had copied, and the menu is lot 1's only place to say so.
    /// Surfacing this in the notch belongs to the UI lot; dropping it on the floor does not.
    func noteClipboard(_ outcome: PasteboardSnapshot.RestoreOutcome) {
        switch outcome {
        case .restored:
            clipboardWarning = nil
        case let .restoredPartially(lost, captured, lostTypes):
            // Task 6 fix round 2 folded TYPE-level loss into this same case, so that `.restored`
            // again means what its doc says. An item that survived amputated -- an eager `.string`
            // kept, its unfulfilled `.rtf` promise gone forever -- arrives here with `lost == 0`
            // and a non-empty `lostTypes`. The old shape reported that as `.restored` and this
            // switch cleared the warning at the exact moment content had been destroyed.
            // NOT a `switch` on `(lost, captured)`: `case (_, captured)` would BIND a new
            // `captured` and match everything, silently. An if-expression compares, a case pattern
            // binds.
            clipboardWarning = if lost == 0 {
                "Presse-papiers restauré en partie (formats perdus : \(lostTypes.count))"
            } else if lost == captured {
                "Presse-papiers perdu (\(lost) élément(s) non restaurables)"
            } else {
                "Presse-papiers partiellement restauré (\(lost)/\(captured) perdus)"
            }
        case .declinedPasteboardChanged:
            // Measured cross-process, after two wrong descriptions of this case: it means exactly
            // what it says. The third party's newer copy is in place and wins; our write was
            // refused (`setString` returned false, the counter was already theirs) and the
            // pre-dictation contents are deliberately not restored over it.
            clipboardWarning = "Presse-papiers modifié pendant la dictée — contenu antérieur non restauré"
        case .writeFailed:
            clipboardWarning = "Restauration du presse-papiers échouée"
        }
    }
}
