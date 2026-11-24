import Foundation

enum RotationCadence: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily, hourly, everyHours, onLaunch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: "每天"
        case .hourly: "每小时"
        case .everyHours: "每隔数小时"
        case .onLaunch: "启动时"
        }
    }
}

/// The same calendar calculation is used by the app, helper and Widget extension.
/// This value contains only schedule fields; reading it never changes a due date.
struct RotationSchedule: Codable, Equatable, Sendable {
    var enabled = false
    var cadence = RotationCadence.daily
    var hours = 6
    var dailyMinute = 8 * 60

    func nextDate(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard enabled else { return nil }
        switch cadence {
        case .daily:
            let minute = min(1_439, max(0, dailyMinute))
            return calendar.nextDate(after: date,
                matching: DateComponents(hour: minute / 60, minute: minute % 60),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        case .hourly:
            return date.addingTimeInterval(3_600)
        case .everyHours:
            return date.addingTimeInterval(Double(min(24, max(1, hours))) * 3_600)
        case .onLaunch:
            return nil
        }
    }
}
