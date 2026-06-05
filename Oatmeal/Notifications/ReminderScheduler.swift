import Foundation
import UserNotifications
import AppKit

/// Handles the "Start Recording" action on pre-meeting notifications.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    static let startActionID = "START_RECORDING"
    static let categoryID = "PRE_MEETING"

    /// Set by the app; invoked when the user taps "Start Recording". The argument
    /// is the calendar event id this reminder was for (nil if it can't be parsed),
    /// so the app records THAT meeting rather than re-picking from overlaps.
    var onStartRecording: ((String?) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.startActionID || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // Request ids are created as "oatmeal-<eventID>" (see scheduling below).
            let requestID = response.notification.request.identifier
            let eventID = requestID.hasPrefix("oatmeal-") ? String(requestID.dropFirst("oatmeal-".count)) : nil
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.onStartRecording?(eventID)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Schedules a local notification shortly before each upcoming calendar meeting.
@MainActor
enum ReminderScheduler {
    private static let calendar = CalendarService()

    static func refresh() async {
        let center = UNUserNotificationCenter.current()

        guard AppSettings.preMeetingReminders else {
            center.removeAllPendingNotificationRequests()
            return
        }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        registerCategory(center)

        guard await calendar.requestAccess() else { return }
        let events = calendar.upcomingEvents(within: 4 * 3600)

        center.removeAllPendingNotificationRequests()
        let now = Date()
        for event in events {
            let fireDate = event.startDate.addingTimeInterval(-60)  // 1 min before
            let interval = fireDate.timeIntervalSince(now)
            guard interval > 5 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Meeting starting soon"
            content.body = event.title
            content.categoryIdentifier = NotificationCoordinator.categoryID
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: "oatmeal-\(event.id)", content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    private static func registerCategory(_ center: UNUserNotificationCenter) {
        let start = UNNotificationAction(
            identifier: NotificationCoordinator.startActionID,
            title: "Start Recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: NotificationCoordinator.categoryID,
            actions: [start],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}
