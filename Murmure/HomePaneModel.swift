import Foundation
import MurmureCore
import os

/// Thin: fetches the text-free projection, computes off the main actor, publishes. Every rule is
/// in `DictationStatistics`; this file only decides when to recompute.
@MainActor
final class HomePaneModel: ObservableObject {
    @Published private(set) var statistics: DictationStatistics?
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

    init(store: HistoryStore?, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.period = settings.homeStatisticsPeriod
        self.typingWordsPerMinute = settings.typingWordsPerMinute
    }

    func reload() {
        guard let store else { statistics = nil; return }
        generation += 1
        let expected = generation
        let period = period
        let typing = typingWordsPerMinute
        Task.detached(priority: .userInitiated) { [log] in
            let result: DictationStatistics?
            do {
                let rows = try store.statisticsRows()
                result = DictationStatistics.compute(rows: rows, period: period, now: Date(),
                                                     calendar: .autoupdatingCurrent,
                                                     typingWordsPerMinute: typing)
            } catch {
                log.error("statistics not computed: \(error.localizedDescription, privacy: .public)")
                result = nil
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == expected else { return }
                self.statistics = result
            }
        }
    }
}
