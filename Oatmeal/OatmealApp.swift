import SwiftUI
import SwiftData
import KeyboardShortcuts
import UserNotifications

@main
struct OatmealApp: App {
    @State private var coordinator = RecordingCoordinator()
    @State private var detector = MeetingDetector()
    @State private var shortcutsRegistered = false

    var sharedModelContainer: ModelContainer = {
        Log.start()
        let schema = Schema([
            Meeting.self, TranscriptSegment.self, Summary.self,
            Attendee.self, ChatMessage.self, Folder.self,
            CustomTemplate.self, Recipe.self, ChatSession.self, EmbeddingChunk.self,
            ActionItem.self, Highlight.self
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
        WindowGroup {
            RootView(coordinator: coordinator, detector: detector)
                .background(WindowConfigurator())
                .onAppear { registerShortcuts() }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
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

        // Pre-meeting notifications → start recording on tap.
        UNUserNotificationCenter.current().delegate = NotificationCoordinator.shared
        NotificationCoordinator.shared.onStartRecording = {
            Task { @MainActor in await coordinator.start(context: container.mainContext) }
        }
        Task { await ReminderScheduler.refresh() }

        // Recover meetings if the store came up empty (e.g. after a store reset),
        // then write a fresh full backup. This is the safety net against data loss.
        let restored = StoreBackup.restoreIfEmpty(context: container.mainContext)
        if restored > 0 { Log.warn("Restored \(restored) meeting(s) from backup", "store") }
        StoreBackup.snapshot(context: container.mainContext)
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
