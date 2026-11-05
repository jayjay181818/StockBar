import Foundation

// MARK: - Chart Time Range Start Dates

extension ChartTimeRange {
    func startDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: -1, to: now) ?? now
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all:
            return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        case .custom:
            // Custom range handled by PerformanceChartView customStartDate
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        }
    }
}
