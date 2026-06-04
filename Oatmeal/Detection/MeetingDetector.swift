import Foundation
import AppKit

/// Watches for a running meeting app alongside a live calendar event, and raises
/// a non-intrusive "Start recording?" suggestion. Opt-in via AppSettings.
@MainActor
@Observable
final class MeetingDetector {
    /// True when a meeting app is running and a calendar event is live right now.
    var suggestionActive = false
    /// Title of the detected event, for the prompt.
    var suggestedTitle: String?

    private var timer: Timer?
    private let calendar = CalendarService()

    /// Dedicated video-call apps. Browser-based Meet is intentionally excluded
    /// to avoid false positives — the live calendar event is the strong signal.
    private let meetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp"
    ]

    func startMonitoring() {
        timer?.invalidate()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        suggestionActive = false
        suggestedTitle = nil
    }

    func dismissSuggestion() {
        suggestionActive = false
    }

    private func check() {
        guard AppSettings.autoDetectMeetings else {
            suggestionActive = false
            return
        }
        let runningIDs = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        let meetingAppRunning = runningIDs.contains { meetingBundleIDs.contains($0) }
        guard meetingAppRunning, let event = calendar.currentOrUpcomingEvent(within: 60) else {
            suggestionActive = false
            return
        }
        suggestedTitle = event.title
        suggestionActive = true
    }
}
