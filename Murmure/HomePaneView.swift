import MurmureCore
import SwiftUI

struct HomePaneView: View {
    @ObservedObject var model: HomePaneModel
    @EnvironmentObject private var appState: AppState
    @State private var showsTypingPopover = false

    var body: some View {
        Group {
            if let stats = model.statistics, stats.hasAnyDictation {
                ScrollView {
                    VStack(alignment: .leading, spacing: HomeLayout.gridSpacing) {
                        header
                        figures(stats)
                        HeatmapCard(days: stats.heatmap, dictations: stats.heatmap.reduce(0) { $0 + $1.dictations })
                        HStack(alignment: .top, spacing: HomeLayout.gridSpacing) {
                            HourProfileCard(hours: stats.hourProfile)
                            StreakCard(streak: stats.streak)
                        }
                        HStack(alignment: .top, spacing: HomeLayout.gridSpacing) {
                            RecordsCard(records: stats.records)
                            TopApplicationsCard(applications: stats.topApplications)
                        }
                    }
                    .frame(maxWidth: HomeLayout.contentMaxWidth)
                    .padding(HomeLayout.panePadding)
                    .frame(maxWidth: .infinity)
                }
            } else if model.statistics != nil {
                ContentUnavailableView("No dictation yet", systemImage: "waveform",
                                       description: Text("Press your shortcut and speak. Your statistics will appear here."))
            } else {
                Color.clear
            }
        }
        .background(Color(role: .paneBackground))
        .onAppear { model.reload() }
        .onChange(of: appState.historyRevision) { _, _ in model.reload() }
    }

    private var header: some View {
        HStack {
            Text("Home").font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            Spacer()
            Picker("Period", selection: $model.period) {
                ForEach(StatisticsPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
        }
    }

    private func figures(_ stats: DictationStatistics) -> some View {
        HStack(alignment: .top, spacing: HomeLayout.gridSpacing) {
            StatCard(label: "Average WPM", value: StatisticsFormatting.wordsPerMinute(stats.averageWordsPerMinute))
            StatCard(label: "Words", value: StatisticsFormatting.count(stats.words), footnote: wordsFootnote(stats))
            StatCard(label: "Applications", value: StatisticsFormatting.count(stats.applicationCount))
            StatCard(label: "Time saved", value: StatisticsFormatting.minutes(stats.timeSavedMinutes),
                     footnote: "vs typing at \(model.typingWordsPerMinute) wpm",
                     accessory: AnyView(typingGear))
        }
    }

    private func wordsFootnote(_ stats: DictationStatistics) -> String? {
        guard let since = stats.wordCountsSince else { return nil }
        let start = stats.period.start(now: Date(), calendar: .autoupdatingCurrent)
        guard start == nil || start! < since else { return nil }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return "counted since \(f.string(from: since))"
    }

    private var typingGear: some View {
        Button { showsTypingPopover.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(role: .secondaryText))
        .popover(isPresented: $showsTypingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Typing speed used for the comparison").font(.system(size: 12, weight: .semibold))
                HStack {
                    Slider(value: Binding(get: { Double(model.typingWordsPerMinute) },
                                          set: { model.typingWordsPerMinute = Int($0.rounded()) }),
                           in: Double(AppSettings.typingWordsPerMinuteRange.lowerBound)...Double(AppSettings.typingWordsPerMinuteRange.upperBound),
                           step: 5)
                    Stepper("\(model.typingWordsPerMinute) wpm", value: $model.typingWordsPerMinute,
                            in: AppSettings.typingWordsPerMinuteRange, step: 5).monospacedDigit()
                }
                Text("Time saved = time to type the words at this speed, minus time spent speaking.")
                    .font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}
