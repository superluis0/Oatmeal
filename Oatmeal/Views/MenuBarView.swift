import SwiftUI
import SwiftData
import AppKit

/// The menu-bar dropdown: record controls + quick access, sharing the app's
/// single RecordingCoordinator so it stays in sync with the main window.
struct MenuBarView: View {
    @Bindable var coordinator: RecordingCoordinator
    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]

    var body: some View {
        if coordinator.isRecording {
            Text("Recording · \(timeString(coordinator.elapsed))")
            Button("Stop Recording") {
                Task { await coordinator.stop(context: context) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        } else {
            Button(coordinator.isBusy ? "Working…" : "New Recording") {
                openMainWindow()
                Task { await coordinator.start(context: context) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(coordinator.isBusy)
        }

        Divider()

        Button("Open Oatmeal") { openMainWindow() }

        if !recent.isEmpty {
            Divider()
            ForEach(recent) { meeting in
                Button(meeting.title) { openMainWindow() }
            }
        }

        Divider()
        Button("Quit Oatmeal") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var recent: [Meeting] { Array(meetings.prefix(5)) }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
