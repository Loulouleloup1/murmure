import Foundation

/// The window the Home figures are computed over. The period ends at `now` and starts at a local
/// midnight, so "7 days" is today plus the six days before it.
public enum StatisticsPeriod: String, CaseIterable, Sendable {
    case last7Days
    case last30Days
    case last12Months
    case allTime

    public var title: String {
        switch self {
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        case .last12Months: "12 months"
        case .allTime: "All time"
        }
    }

    /// Inclusive start of the period, or nil for all time.
    public func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .last7Days: return calendar.date(byAdding: .day, value: -6, to: today)
        case .last30Days: return calendar.date(byAdding: .day, value: -29, to: today)
        case .last12Months: return calendar.date(byAdding: .month, value: -12, to: today)
        case .allTime: return nil
        }
    }
}
