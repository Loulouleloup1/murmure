import Foundation

/// Display strings for the Home figures. Pure so the rounding rules are pinned by tests rather
/// than rediscovered in a view.
public enum StatisticsFormatting {
    public static let dash = "—"

    public static func minutes(_ minutes: Double?) -> String {
        guard let minutes else { return dash }
        let whole = Int(minutes.rounded(.toNearestOrAwayFromZero))
        let sign = whole < 0 ? "−" : ""
        let magnitude = abs(whole)
        if magnitude < 60 { return "\(sign)\(magnitude) min" }
        return "\(sign)\(magnitude / 60)h \(String(format: "%02d", magnitude % 60))min"
    }

    public static func wordsPerMinute(_ wpm: Double?) -> String {
        guard let wpm else { return dash }
        return String(Int(wpm.rounded()))
    }

    public static func count(_ n: Int, locale: Locale = Locale(identifier: "en_GB")) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(String(format: "%02d", (total % 3600) / 60)) min"
    }
}
