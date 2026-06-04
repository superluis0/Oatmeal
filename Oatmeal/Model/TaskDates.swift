import Foundation

/// Date helpers for the task manager: bucketing, quick-set targets, and
/// natural-language parsing ("email Dan by Friday").
enum TaskDates {
    private static var cal: Calendar { Calendar.current }

    static var startOfToday: Date { cal.startOfDay(for: .now) }
    static var endOfToday: Date { cal.date(byAdding: .day, value: 1, to: startOfToday)!.addingTimeInterval(-1) }
    static var endOfWeek: Date { cal.date(byAdding: .day, value: 7, to: startOfToday)!.addingTimeInterval(-1) }

    /// Quick-set targets default to 9am so reminders read sensibly.
    static var today: Date { startOfToday.addingTimeInterval(9 * 3600) }
    static var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: startOfToday)!.addingTimeInterval(9 * 3600) }
    static var nextWeek: Date { cal.date(byAdding: .day, value: 7, to: startOfToday)!.addingTimeInterval(9 * 3600) }

    /// Best-effort natural-language date extraction via NSDataDetector.
    static func parse(_ text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.date
    }

    enum Bucket: String, CaseIterable, Identifiable {
        case overdue = "Overdue"
        case today = "Today"
        case thisWeek = "This Week"
        case later = "Later"
        case noDate = "No Date"
        case snoozed = "Snoozed"
        case done = "Done"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overdue: return "exclamationmark.circle.fill"
            case .today: return "sun.max.fill"
            case .thisWeek: return "calendar"
            case .later: return "calendar.badge.clock"
            case .noDate: return "tray"
            case .snoozed: return "moon.zzz.fill"
            case .done: return "checkmark.circle.fill"
            }
        }
    }

    /// Which bucket an item belongs in right now.
    static func bucket(for item: ActionItem) -> Bucket {
        if item.isDone { return .done }
        if let snz = item.snoozedUntil, snz > .now { return .snoozed }
        guard let due = item.dueDate else { return .noDate }
        if due < startOfToday { return .overdue }
        if due <= endOfToday { return .today }
        if due <= endOfWeek { return .thisWeek }
        return .later
    }
}
