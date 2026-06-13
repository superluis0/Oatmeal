import Foundation
import EventKit

/// Optional one-way sync of action items into an "Oatmeal" Apple Reminders list.
/// Fully on-device via EventKit. No-op unless the user enables it in Settings.
@MainActor
enum RemindersService {
    private static let store = EKEventStore()
    private static let listName = "Oatmeal"

    static func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .denied, .restricted: return false
        default: return (try? await store.requestFullAccessToReminders()) ?? false
        }
    }

    /// Push every open, not-yet-synced action item into the Oatmeal list.
    static func syncAll(meetings: [Meeting], context: ModelContextRef) async {
        guard AppSettings.syncReminders, await requestAccess(), let list = oatmealList() else { return }
        for meeting in meetings {
            for item in meeting.actionItems where !item.isDone && item.reminderID == nil {
                if let id = createReminder(item.text, due: item.dueDate, in: list) { item.reminderID = id }
            }
        }
        context.save()
    }

    /// Reflect an in-app completion toggle onto the synced reminder.
    static func syncCompletion(of item: ActionItem) {
        guard AppSettings.syncReminders, let id = item.reminderID,
              let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = item.isDone
        try? store.save(reminder, commit: true)
    }

    private static func oatmealList() -> EKCalendar? {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
            return existing
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = listName
        calendar.source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first
        try? store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private static func createReminder(_ title: String, due: Date?, in list: EKCalendar) -> String? {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        // Only report the id on a successful save — otherwise the caller persists
        // `reminderID` and treats the item as synced, so it's never retried even
        // though no reminder was actually created.
        do {
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        } catch {
            Log.error("failed to save reminder", "reminders", error)
            return nil
        }
    }
}

/// Tiny wrapper so `syncAll` can persist without importing SwiftData here.
struct ModelContextRef {
    let save: () -> Void
}
