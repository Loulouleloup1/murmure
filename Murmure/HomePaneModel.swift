import Foundation
import MurmureCore
import os

/// Thin: fetches the text-free projection, computes off the main actor, publishes. Every rule is
/// in `DictationStatistics`; this file only decides when to recompute.
@MainActor
final class HomePaneModel: ObservableObject {
    @Published private(set) var statistics: DictationStatistics?
    /// The last error's description, when `statisticsRows()` threw; cleared on the next successful
    /// load. Lets the view distinguish "nothing recorded yet" from "the archive could not be read".
    @Published private(set) var problem: String?
    @Published var period: StatisticsPeriod {
        didSet { if oldValue != period { settings.homeStatisticsPeriod = period; reload() } }
    }
    @Published var typingWordsPerMinute: Int {
        didSet { if oldValue != typingWordsPerMinute { settings.typingWordsPerMinute = typingWordsPerMinute; reload() } }
    }

    private let store: HistoryStore?
    private let settings: AppSettings
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "home")
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    init(store: HistoryStore?, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.period = settings.homeStatisticsPeriod
        self.typingWordsPerMinute = settings.typingWordsPerMinute
    }

    func reload() {
        loadTask?.cancel()
        guard let store else { statistics = nil; problem = nil; return }
        generation += 1
        let expected = generation
        let period = period
        let typing = typingWordsPerMinute
        loadTask = Task.detached(priority: .userInitiated) { [log] in
            let result: DictationStatistics?
            var failure: String?
            do {
                let rows = try store.statisticsRows()
                result = DictationStatistics.compute(rows: rows, period: period, now: Date(),
                                                     calendar: .autoupdatingCurrent,
                                                     typingWordsPerMinute: typing)
            } catch {
                log.error("statistics not computed: \(error.localizedDescription, privacy: .public)")
                result = nil
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == expected else { return }
                self.statistics = result
                self.problem = failure
            }
        }
    }
}
