import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle, recording, transcribing, inserting, failed
    }

    @Published var status: Status = .idle

    var menuBarSymbol: String {
        switch status {
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "hourglass"
        case .inserting: "arrow.down.doc"
        case .failed: "exclamationmark.triangle"
        }
    }
}
