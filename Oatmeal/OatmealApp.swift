import SwiftUI
import SwiftData
import KeyboardShortcuts
import UserNotifications
import AppKit

@main
struct OatmealApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = RecordingCoordinator()
    @State private var detector = MeetingDetector()
    @State private var shortcutsRegistered = false

    /// Stable id for the main window so the floating panel can reopen it after
    /// it's been closed.
    static let mainWindowID = "main"

    var sharedModelContainer: ModelContainer = {
        Log.start()
        let schema = Schema([
            Meeting.self, TranscriptSegment.self, Summary.self,
            Attendee.self, ChatMessage.self, Folder.self,
            CustomTemplate.self, Recipe.self, ChatSession.self, EmbeddingChunk.self,
            ActionItem.self, Highlight.self, MeetingPrep.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // NEVER delete user data on a schema/migration failure. Move the
            // existing store aside (timestamped) so it stays on disk for recovery,
            // then start fresh — `StoreBackup.restoreIfEmpty` repopulates from the
            // latest JSON backup on launch.
            Log.error("ModelContainer open failed; moving store aside", "store", error)
            moveStoreAside()
            do {
                let c = try ModelContainer(for: schema, configurations: [config])
                Log.warn("Recreated store after moving the previous one aside", "store")
                return c
            } catch {
                Log.error("ModelContainer recreation failed", "store", error)
                fatalError("Could not create ModelContainer after moving store aside: \(error)")
            }
        }
    }()

    var body: some Scene {
        // A single, addressable main window (not a WindowGroup) so it can be
        // reopened by id after the user closes it — e.g. from the floating panel.
        Window("Oatmeal", id: Self.mainWindowID) {
            RootView(coordinator: coordinator, detector: detector)
                .background(WindowConfigurator())
                .onAppear { registerShortcuts() }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Standard "Check for Updates…" under the app menu — drives Sparkle's
            // one-click install flow (see UpdateChecker).
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.shared.checkForUpdates() }
            }
        }

        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
                .modelContainer(sharedModelContainer)
        } label: {
            Image(systemName: coordinator.isRecording ? "record.circle.fill" : "waveform")
        }

        Settings {
            SettingsView()
                .modelContainer(sharedModelContainer)
        }
    }

    private func registerShortcuts() {
        guard !shortcutsRegistered else { return }
        shortcutsRegistered = true
        let container = sharedModelContainer

        // Let the AppKit delegate reach the coordinator/context so quitting
        // mid-recording can stop and save first (see AppDelegate).
        AppLifecycle.shared.coordinator = coordinator
        AppLifecycle.shared.context = container.mainContext

        // Start Sparkle's updater so automatic checks are scheduled from launch.
        UpdateChecker.shared.startUpdater()

        // Pre-meeting notifications → start recording on tap. Record the SPECIFIC
        // meeting the reminder was for (resolved from its event id), not whichever
        // event the calendar would auto-pick when meetings overlap.
        UNUserNotificationCenter.current().delegate = NotificationCoordinator.shared
        NotificationCoordinator.shared.onStartRecording = { eventID in
            Task { @MainActor in
                let event = eventID.flatMap { CalendarService().upcomingMeeting(withID: $0) }
                await coordinator.start(context: container.mainContext, event: event)
            }
        }
        Task { await ReminderScheduler.refresh() }

        // Recover meetings if the store came up empty (e.g. after a store reset),
        // then write a fresh full backup. This is the safety net against data loss.
        let restored = StoreBackup.restoreIfEmpty(context: container.mainContext)
        if restored > 0 {
            Log.warn("Restored \(restored) meeting(s) from backup", "store")
            // The just-imported objects are fragile to read in this same runloop
            // turn — reindex + snapshot on the NEXT turn, after the import settles.
            DispatchQueue.main.async {
                StoreBackup.reindexAll(context: container.mainContext)
                StoreBackup.snapshot(context: container.mainContext)
            }
        } else {
            // Defer off the launch path so the snapshot (which now writes its bytes
            // on a background queue) doesn't compete with first paint.
            Task(priority: .utility) { @MainActor in
                StoreBackup.snapshot(context: container.mainContext)
            }
        }
        if let crash = Log.consumeLastCrash() {
            Log.warn("Previous session ended in a crash:\n\(crash)", "crash")
            Log.lastCrashReport = crash
        }

        // Keep the local calendar synced so new meetings appear over time.
        CalendarRefresher.shared.start()

        // Prune old audio per the retention setting.
        if let meetings = try? container.mainContext.fetch(FetchDescriptor<Meeting>()) {
            StorageManager.pruneOldAudio(meetings: meetings, context: container.mainContext)
        }

        // Warm the speech models in the background so the first Record tap is
        // instant — but only once they've downloaded before, so we never kick off
        // the large first-run download before the user has chosen to record.
        if AppSettings.modelsPreparedBefore {
            coordinator.prewarm()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { @MainActor in
                let ctx = container.mainContext
                if coordinator.isRecording {
                    await coordinator.stop(context: ctx)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    await coordinator.start(context: ctx)
                }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .markMoment) {
            Task { @MainActor in coordinator.markHighlight(context: container.mainContext) }
        }
    }
}

/// Bridges the SwiftUI coordinator/context to the AppKit `AppDelegate`, so a quit
/// that lands mid-recording can stop and save first instead of dropping it.
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()
    weak var coordinator: RecordingCoordinator?
    var context: ModelContext?
    private init() {}
}

/// Reopens the main window on demand. `NSApp.activate` alone can't recreate a
/// closed SwiftUI window, so the window's content registers a SwiftUI
/// `openWindow` closure here that survives the window being closed.
@MainActor
final class MainWindowAccess {
    static let shared = MainWindowAccess()
    var openMain: (() -> Void)?
    private init() {}

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        openMain?()
    }
}

/// Guards against quitting mid-recording (or mid-processing) and silently losing
/// the in-progress meeting — the floating panel makes it easy to ⌘Q with no main
/// window in sight.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let coord = AppLifecycle.shared.coordinator else { return .terminateNow }

            if coord.isRecording {
                let alert = NSAlert()
                alert.messageText = "Oatmeal is still recording"
                alert.informativeText = "Quitting will stop the recording and process this meeting first."
                alert.addButton(withTitle: "Stop & Quit")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
                guard let ctx = AppLifecycle.shared.context else { return .terminateNow }
                // Stop (which saves audio + runs processing), then let the quit proceed.
                Task { @MainActor in
                    await coord.stop(context: ctx)
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                // Failsafe: if processing is slow or a hung LLM stalls stop(), don't
                // wedge the app in "terminating" limbo. The transcript is already
                // saved before processing, so a cut-off only skips the summary.
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }

            if coord.isBusy {
                let alert = NSAlert()
                alert.messageText = "Oatmeal is still finishing this meeting"
                alert.informativeText = "It's transcribing and summarizing. Quitting now may lose the summary."
                alert.addButton(withTitle: "Wait")
                alert.addButton(withTitle: "Quit Anyway")
                return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
            }

            return .terminateNow
        }
    }
}

/// Renames the default SwiftData store files aside (never deletes) so a fresh
/// container can be created while the old data stays on disk for recovery.
private func moveStoreAside() {
    let fm = FileManager.default
    guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let stamp = Int(Date().timeIntervalSince1970)
    for name in ["default.store", "default.store-shm", "default.store-wal"] {
        let src = appSupport.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { continue }
        let dst = appSupport.appendingPathComponent("\(name).movedaside-\(stamp)")
        try? fm.moveItem(at: src, to: dst)
    }
}
