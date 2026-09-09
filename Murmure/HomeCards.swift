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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .animation(.easeInOut(duration: 0.25), value: value)
            // The caption line is always laid out (a single space when there is no footnote) so the
            // four tiles share one height regardless of which ones have a footnote.
            Text(footnote ?? " ").font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: HomeLayout.statCardHeight)
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

/// Small hover tooltip shared by the heatmap and the hour profile: a bold headline over a
/// secondary detail line, clamped inside the chart's plot area by its caller.
struct ChartTip: View {
    let line1: String
    let line2: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line1).font(.caption).bold().foregroundStyle(Color(role: .primaryText))
            Text(line2).font(.caption).foregroundStyle(Color(role: .secondaryText))
        }
        .padding(8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(role: .cardBackground))
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06))
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(role: .hairline), lineWidth: 1)))
        .fixedSize()
    }
}

/// Clamps a tooltip of `size` anchored near `pointer` so it stays inside `bounds`, offset slightly
/// down-right of the pointer (or up-left when that would overflow).
private func clampedTipCenter(pointer: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
    guard size != .zero else { return pointer }
    var x = pointer.x + 12
    var y = pointer.y + 12
    if x + size.width > bounds.maxX { x = pointer.x - 12 - size.width }
    if y + size.height > bounds.maxY { y = pointer.y - 12 - size.height }
    x = min(max(x, bounds.minX), bounds.maxX - size.width)
    y = min(max(y, bounds.minY), bounds.maxY - size.height)
    return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
}

struct HeatmapCard: View {
    let days: [DictationStatistics.HeatmapDay]
    let dictations: Int

    @State private var hoverDay: DictationStatistics.HeatmapDay?
    @State private var hoverLocation: CGPoint = .zero
    @State private var tipSize: CGSize = .zero

    private static let monthFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM"; return f }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Calendar.autoupdatingCurrent.locale
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private var monthLabels: [(column: Int, text: String)] {
        // Label a column when its first day is the first Monday that falls within a month's first week.
        // Keyed by year+month (not month alone): over a 364-day span the current month and the
        // month-a-year-ago share the same `.month` component, and a bare month key would let the
        // older one claim the label, silently dropping the current month's.
        var seen = Set<Int>()
        var labels: [(Int, String)] = []
        for day in days where day.row == 0 {
            let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: day.day)
            let key = (components.year ?? 0) * 100 + (components.month ?? 0)
            if (components.day ?? 0) <= 7, !seen.contains(key) {
                seen.insert(key); labels.append((day.column, Self.monthFormatter.string(from: day.day)))
            }
        }
        return labels
    }

    /// The cell rectangle in view-local coordinates, matching the `RectangleMark` bounds exactly.
    private func cellFrame(for day: DictationStatistics.HeatmapDay, proxy: ChartProxy,
                           plotFrame: CGRect) -> CGRect? {
        guard let x0 = proxy.position(forX: Double(day.column) + 0.1),
              let x1 = proxy.position(forX: Double(day.column) + 0.9),
              let y0 = proxy.position(forY: Double(6 - day.row) + 0.1),
              let y1 = proxy.position(forY: Double(7 - day.row) - 0.1) else { return nil }
        return CGRect(x: plotFrame.minX + min(x0, x1), y: plotFrame.minY + min(y0, y1),
                      width: abs(x1 - x0), height: abs(y1 - y0))
    }

    private func tipLines(for day: DictationStatistics.HeatmapDay) -> (String, String) {
        let line1 = Self.dayFormatter.string(from: day.day)
        guard day.dictations > 0 else { return (line1, "No dictation") }
        let dictationWord = day.dictations == 1 ? "dictation" : "dictations"
        let wordWord = day.words == 1 ? "word" : "words"
        return (line1, "\(StatisticsFormatting.count(day.dictations)) \(dictationWord) · "
                + "\(StatisticsFormatting.count(day.words)) \(wordWord)")
    }

    var body: some View {
        HomeCard(title: "Activity", caption: "Last 52 weeks · \(StatisticsFormatting.count(dictations)) dictations") {
            chart
        }
    }

    private var chart: some View {
        let base = Chart(days, id: \.day) { day in
            RectangleMark(
                xStart: .value("Week", Double(day.column) + 0.1), xEnd: .value("Week", Double(day.column) + 0.9),
                yStart: .value("Day", Double(6 - day.row) + 0.1), yEnd: .value("Day", Double(7 - day.row) - 0.1))
            .foregroundStyle(HeatStyle.color(level: day.level))
            .cornerRadius(2)
        }
        return base
            .chartXAxis {
                AxisMarks(values: monthLabels.map { Double($0.column) }) { value in
                    if let column = value.as(Double.self),
                       let label = monthLabels.first(where: { Double($0.column) == column }) {
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
            .chartXScale(domain: 0.0...52.0)
            .chartYScale(domain: 0.0...7.0)
            .chartLegend(.hidden)
            .frame(width: 52 * (HomeLayout.heatmapCellSize + HomeLayout.heatmapCellGap),
                   height: 7 * (HomeLayout.heatmapCellSize + HomeLayout.heatmapCellGap) + 24)
            .frame(maxWidth: .infinity, alignment: .center)
            .chartPlotStyle { $0.padding(.zero) }
            .chartOverlay { proxy in overlay(proxy: proxy) }
    }

    @ViewBuilder
    private func overlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let plotFrame: CGRect = proxy.plotFrame.map { geo[$0] } ?? .zero
            hoverLayer(proxy: proxy, plotFrame: plotFrame)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in handleHover(phase, proxy: proxy, plotFrame: plotFrame) }
        }
    }

    @ViewBuilder
    private func hoverLayer(proxy: ChartProxy, plotFrame: CGRect) -> some View {
        if let hoverDay, let cell = cellFrame(for: hoverDay, proxy: proxy, plotFrame: plotFrame) {
            HeatmapHoverContent(cell: cell, lines: tipLines(for: hoverDay), hoverLocation: hoverLocation,
                               plotFrame: plotFrame, tipSize: $tipSize)
        }
    }

    private func handleHover(_ phase: HoverPhase, proxy: ChartProxy, plotFrame: CGRect) {
        switch phase {
        case .active(let location):
            hoverLocation = location
            let xInPlot = location.x - plotFrame.minX
            let yInPlot = location.y - plotFrame.minY
            guard let xVal: Double = proxy.value(atX: xInPlot),
                  let yVal: Double = proxy.value(atY: yInPlot) else {
                withAnimation(.easeInOut(duration: 0.12)) { hoverDay = nil }
                return
            }
            let column = Int(floor(xVal))
            let row = 6 - Int(floor(yVal))
            let match = days.first { $0.column == column && $0.row == row }
            withAnimation(.easeInOut(duration: 0.12)) { hoverDay = match }
        case .ended:
            withAnimation(.easeInOut(duration: 0.12)) { hoverDay = nil }
        }
    }
}

/// The stroked hovered cell plus its `ChartTip`, extracted into its own view so the surrounding
/// `chartOverlay` closure stays small enough for the type checker.
private struct HeatmapHoverContent: View {
    let cell: CGRect
    let lines: (String, String)
    let hoverLocation: CGPoint
    let plotFrame: CGRect
    @Binding var tipSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color(role: .primaryText).opacity(0.6), lineWidth: 1)
                .frame(width: cell.width, height: cell.height)
                .position(x: cell.midX, y: cell.midY)
            ChartTip(line1: lines.0, line2: lines.1)
                .background(GeometryReader { tipGeo in
                    Color.clear.onAppear { tipSize = tipGeo.size }
                        .onChange(of: tipGeo.size) { _, newValue in tipSize = newValue }
                })
                .opacity(tipSize == .zero ? 0 : 1)
                .position(clampedTipCenter(pointer: hoverLocation, size: tipSize, bounds: plotFrame))
        }
    }
}

struct HourProfileCard: View {
    let hours: [Int]

    @State private var hoveredHour: Int?
    @State private var hoverLocation: CGPoint = .zero
    @State private var tipSize: CGSize = .zero

    private func tipLines(for hour: Int) -> (String, String) {
        let line1 = String(format: "%02d:00 – %02d:59", hour, hour)
        let count = hours[hour]
        let line2 = count == 0 ? "No dictation" : "\(StatisticsFormatting.count(count)) \(count == 1 ? "dictation" : "dictations")"
        return (line1, line2)
    }

    var body: some View {
        HomeCard(title: "When you dictate", caption: nil) {
            chart
        }
    }

    private var chart: some View {
        let base = Chart(Array(hours.enumerated()), id: \.offset) { hour, count in
            BarMark(x: .value("Hour", hour), y: .value("Dictations", count))
                .foregroundStyle(HeatStyle.color(level: count == 0 ? 0 : 3))
                .opacity(hoveredHour == nil || hoveredHour == hour ? 1 : 0.55)
                .cornerRadius(2)
        }
        return base
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0)h").font(.system(size: 10)) } } }
            .chartYAxis(.hidden)
            .frame(height: 96)
            .chartOverlay { proxy in overlay(proxy: proxy) }
    }

    @ViewBuilder
    private func overlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let plotFrame: CGRect = proxy.plotFrame.map { geo[$0] } ?? .zero
            hoverLayer(plotFrame: plotFrame)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in handleHover(phase, proxy: proxy, plotFrame: plotFrame) }
        }
    }

    @ViewBuilder
    private func hoverLayer(plotFrame: CGRect) -> some View {
        if let hoveredHour {
            HourProfileHoverContent(lines: tipLines(for: hoveredHour), hoverLocation: hoverLocation,
                                    plotFrame: plotFrame, tipSize: $tipSize)
        }
    }

    private func handleHover(_ phase: HoverPhase, proxy: ChartProxy, plotFrame: CGRect) {
        switch phase {
        case .active(let location):
            hoverLocation = location
            let xInPlot = location.x - plotFrame.minX
            guard let xVal: Double = proxy.value(atX: xInPlot) else {
                withAnimation(.easeInOut(duration: 0.12)) { hoveredHour = nil }
                return
            }
            let hour = Int(xVal.rounded())
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredHour = (0...23).contains(hour) ? hour : nil
            }
        case .ended:
            withAnimation(.easeInOut(duration: 0.12)) { hoveredHour = nil }
        }
    }
}

/// The `ChartTip` for the hovered hour bar, extracted into its own view so the surrounding
/// `chartOverlay` closure stays small enough for the type checker.
private struct HourProfileHoverContent: View {
    let lines: (String, String)
    let hoverLocation: CGPoint
    let plotFrame: CGRect
    @Binding var tipSize: CGSize

    var body: some View {
        ChartTip(line1: lines.0, line2: lines.1)
            .background(GeometryReader { tipGeo in
                Color.clear.onAppear { tipSize = tipGeo.size }
                    .onChange(of: tipGeo.size) { _, newValue in tipSize = newValue }
            })
            .opacity(tipSize == .zero ? 0 : 1)
            .position(clampedTipCenter(pointer: hoverLocation, size: tipSize, bounds: plotFrame))
    }
}

struct StreakCard: View {
    let streak: DictationStatistics.Streak
    var body: some View {
        HomeCard(title: "Streak", caption: "All time") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "flame")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(HeatStyle.color(level: streak.current > 0 ? 4 : 0))
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
                .frame(width: 96, alignment: .trailing)
            // Always lay out the date column, even when there is no day: an empty label with the
            // same frame keeps dash rows and dated rows aligned rather than shifting the value
            // column when a record is missing.
            Text(day.map { Self.dayFormatter.string(from: $0) } ?? "")
                .font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
                .frame(width: 96, alignment: .trailing)
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
                .help("\(StatisticsFormatting.count(app.words)) words · \(StatisticsFormatting.duration(app.spokenSeconds))")
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
