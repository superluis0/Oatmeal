import Foundation
import EventKit

/// Background job that periodically pulls remote calendar changes into the local
/// store so newly-added meetings show up without the user doing anything. When a
/// sync brings in changes, EventKit posts `.EKEventStoreChanged`, which the
/// Upcoming view observes to refresh itself.
@MainActor
final class CalendarRefresher {
    static let shared = CalendarRefresher()

    private let store = EKEventStore()
    private var timer: Timer?

    /// Start periodic syncing (default every 30 minutes).
    func start(interval: TimeInterval = 30 * 60) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        store.refreshSourcesIfNecessary()
    }
}
