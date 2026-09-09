import AppKit
import Charts
import MurmureCore
import SwiftUI

struct HomeCard<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                Spacer()
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
                }
            }
            content
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
                .overlay(RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(role: .hairline), lineWidth: 1)))
    }
}

struct StatCard: View {
    let label: String
    let value: String
    var footnote: String? = nil
    var accessory: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(role: .secondaryText))
                Spacer()
                accessory
            }
            Text(value)
                .font(.system(size: HomeLayout.figureFontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(role: .primaryText))
                .contentTransition(.numericText())
            if let footnote {
                Text(footnote).font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
            }
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
                .overlay(RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(role: .hairline), lineWidth: 1)))
    }
}

enum HeatStyle {
    static func color(level: Int) -> Color {
        guard level > 0 else { return Color(role: .hairline) }
        let brightness = HomeLayout.heatBrightness[min(level, HomeLayout.heatBrightness.count) - 1]
        return Color(hue: NotchAppearance.accentHue, saturation: NotchAppearance.accentSaturation,
                     brightness: brightness)
    }
}

struct HeatmapCard: View {
    let days: [DictationStatistics.HeatmapDay]
    let dictations: Int

    private var monthLabels: [(column: Int, text: String)] {
        // Label a column when its first day is the first Monday that falls within a month's first week.
        var seen = Set<Int>()
        var labels: [(Int, String)] = []
        let formatter = DateFormatter(); formatter.dateFormat = "MMM"
        for day in days where day.row == 0 {
            let month = Calendar.autoupdatingCurrent.component(.month, from: day.day)
            let dayOfMonth = Calendar.autoupdatingCurrent.component(.day, from: day.day)
            if dayOfMonth <= 7, !seen.contains(month) {
                seen.insert(month); labels.append((day.column, formatter.string(from: day.day)))
            }
        }
        return labels
    }

    var body: some View {
        HomeCard(title: "Activity", caption: "Last 52 weeks · \(StatisticsFormatting.count(dictations)) dictations") {
            Chart(days, id: \.day) { day in
                RectangleMark(
                    xStart: .value("Week", Double(day.column) + 0.1), xEnd: .value("Week", Double(day.column) + 0.9),
                    yStart: .value("Day", Double(6 - day.row) + 0.1), yEnd: .value("Day", Double(7 - day.row) - 0.1))
                .foregroundStyle(HeatStyle.color(level: day.level))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: monthLabels.map(\.column)) { value in
                    if let column = value.as(Int.self), let label = monthLabels.first(where: { $0.column == column }) {
                        AxisValueLabel { Text(label.text).font(.system(size: 10)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [6.5, 4.5, 2.5]) { value in
                    AxisValueLabel {
                        Text(value.as(Double.self) == 6.5 ? "Mon" : value.as(Double.self) == 4.5 ? "Wed" : "Fri")
                            .font(.system(size: 10))
                    }
                }
            }
            .chartXScale(domain: 0...52)
            .chartYScale(domain: 0...7)
            .chartLegend(.hidden)
            .frame(height: 7 * (HomeLayout.heatmapCellSize + HomeLayout.heatmapCellGap) + 24)
            .chartPlotStyle { $0.padding(.zero) }
        }
    }
}

struct HourProfileCard: View {
    let hours: [Int]
    var body: some View {
        HomeCard(title: "When you dictate", caption: nil) {
            Chart(Array(hours.enumerated()), id: \.offset) { hour, count in
                BarMark(x: .value("Hour", hour), y: .value("Dictations", count))
                    .foregroundStyle(HeatStyle.color(level: count == 0 ? 0 : 3))
                    .cornerRadius(2)
            }
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0)h").font(.system(size: 10)) } } }
            .chartYAxis(.hidden)
            .frame(height: 96)
        }
    }
}

struct StreakCard: View {
    let streak: DictationStatistics.Streak
    var body: some View {
        HomeCard(title: "Streak", caption: "All time") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "flame").foregroundStyle(HeatStyle.color(level: streak.current > 0 ? 4 : 0))
                Text("\(streak.current)").font(.system(size: HomeLayout.figureFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                Text(streak.current == 1 ? "day" : "days").foregroundStyle(Color(role: .secondaryText))
            }
            Text("Longest: \(streak.longest) \(streak.longest == 1 ? "day" : "days")")
                .font(.system(size: 12)).foregroundStyle(Color(role: .secondaryText))
        }
    }
}

struct RecordsCard: View {
    let records: DictationStatistics.Records
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()

    var body: some View {
        HomeCard(title: "Records", caption: "All time") {
            row("Longest dictation",
                records.longestDictationSeconds.map { StatisticsFormatting.duration($0.value) },
                records.longestDictationSeconds?.day)
            row("Biggest day",
                records.mostWordsInADay.map { "\(StatisticsFormatting.count($0.value)) words" },
                records.mostWordsInADay?.day)
            row("Fastest",
                records.fastestWordsPerMinute.map { "\(StatisticsFormatting.wordsPerMinute($0.value)) wpm" },
                records.fastestWordsPerMinute?.day)
        }
    }

    private func row(_ label: String, _ value: String?, _ day: Date?) -> some View {
        HStack {
            Text(label).foregroundStyle(Color(role: .secondaryText))
            Spacer()
            Text(value ?? StatisticsFormatting.dash).monospacedDigit().foregroundStyle(Color(role: .primaryText))
            if let day {
                Text(Self.dayFormatter.string(from: day)).font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
                    .frame(width: 96, alignment: .trailing)
            }
        }
        .font(.system(size: 12))
    }
}

struct TopApplicationsCard: View {
    let applications: [DictationStatistics.Application]
    var body: some View {
        HomeCard(title: "Top applications", caption: nil) {
            if applications.isEmpty {
                Text(StatisticsFormatting.dash).foregroundStyle(Color(role: .secondaryText))
            }
            let maxCount = applications.first?.dictations ?? 1
            ForEach(applications, id: \.bundleID) { app in
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(for: app.bundleID)).resizable().frame(width: 18, height: 18)
                    Text(app.name).font(.system(size: 12)).foregroundStyle(Color(role: .primaryText)).lineLimit(1)
                    Spacer(minLength: 8)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(HeatStyle.color(level: 3))
                            .frame(width: proxy.size.width * CGFloat(app.dictations) / CGFloat(maxCount))
                    }
                    .frame(width: 120, height: 6)
                    Text(StatisticsFormatting.count(app.dictations)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Color(role: .secondaryText)).frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    /// The app's icon if it is installed, else a generic one. Read-only lookup, no launch.
    private static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
