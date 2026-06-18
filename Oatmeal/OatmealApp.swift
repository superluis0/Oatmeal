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
            ActionItem.self, Highlight.self, MeetingPrep.self, SavedReport.self
        ])
        // Keep the store in the app's OWN namespaced subdirectory rather than the
        // shared Application Support root, so no other process's files can collide
        // with or touch the SQLite store (a leading suspect in the recurring Code 256
        // "file couldn't be opened" store failures). Relocate any legacy AS-root store
        // into it once (when safe), then open whatever the effective location is.
        migrateStoreToNamespacedDir()
        let storeURL = StorageManager.storeURL()
        let config = storeURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // NEVER delete user data on a schema/migration failure. Move the
            // existing store aside (timestamped) so it stays on disk for recovery,
            // then start fresh — `StoreBackup.restoreIfEmpty` repopulates from the
            // latest JSON backup on launch.
            Log.error("ModelContainer open failed; moving store aside", "store", error)
            moveStoreAside(storeURL: storeURL)
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
                OpenLogsMenuItem()
                Button("Reveal Logs in Finder") {
                    if let dir = Log.logDirectory {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
        }

        // A dedicated, resizable window for reading the diagnostic log with
        // structure — severity badges, search, and a warnings/errors filter.
        // Opened from Settings → Privacy and the app menu; closed by default.
        Window("Oatmeal Logs", id: "logs") {
            LogViewerView()
        }
        .defaultSize(width: 840, height: 640)

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
        KeyboardShortcuts.onKeyUp(for: .quickAsk) {
            Task { @MainActor in
                guard AppSettings.globalHotkeysEnabled else { return }
                QuickAskController.shared.toggle()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .copyRecap) {
            Task { @MainActor in
                guard AppSettings.globalHotkeysEnabled else { return }
                RecapPaste.pasteLatestRecap()
            }
        }

        // Watch the MCP command inbox for guarded agent writes (no-op unless enabled).
        MCPCommandInbox.shared.start(context: container.mainContext)

        // Refresh the agent read-mirror at launch so an MCP client (Claude, etc.) sees
        // data current with edits made in a previous session — not just the last
        // recording. AppDelegate also refreshes it when Oatmeal loses focus (i.e. when
        // you switch over to your agent).
        Task(priority: .utility) { @MainActor in MCPExport.syncIfNeeded(context: container.mainContext) }
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

    /// Wait briefly for the app to finish launching so App Intents (which may have
    /// just launched the app via `openAppWhenRun`) can read the live store. Returns
    /// nil if it never becomes available.
    func awaitContext() async -> ModelContext? {
        for _ in 0..<60 {
            if let context { return context }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return context
    }
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

/// A menu command that opens the dedicated Logs window. `openWindow` is only
/// available to a `View`, not a bare scene's `.commands` closure, so this tiny
/// wrapper carries it into the app menu.
private struct OpenLogsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("View Logs…") { openWindow(id: "logs") }
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

    /// Refresh the agent read-mirror whenever Oatmeal loses focus — typically right
    /// before the user switches to their MCP client — so it reflects this session's
    /// edits. Throttled, so rapid app-switching doesn't re-serialize repeatedly.
    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let ctx = AppLifecycle.shared.context else { return }
            MCPExport.syncIfNeeded(context: ctx)
        }
    }
}

/// Renames the SwiftData store files aside (never deletes) so a fresh container can
/// be created while the old data stays on disk for recovery. Operates on the
/// resolved store location (namespaced when available, else the legacy AS-root
/// `default.store`), moving the store and its `-shm`/`-wal` sidecars together.
private func moveStoreAside(storeURL: URL?) {
    let fm = FileManager.default
    let store: URL
    if let storeURL {
        store = storeURL
    } else if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        store = appSupport.appendingPathComponent("default.store")
    } else {
        return
    }
    let dir = store.deletingLastPathComponent()
    let base = store.lastPathComponent
    let stamp = Int(Date().timeIntervalSince1970)
    for suffix in ["", "-shm", "-wal"] {
        let src = dir.appendingPathComponent(base + suffix)
        guard fm.fileExists(atPath: src.path) else { continue }
        let dst = dir.appendingPathComponent("\(base)\(suffix).movedaside-\(stamp)")
        try? fm.moveItem(at: src, to: dst)
    }
}

/// One-time relocation of a legacy store from the shared Application Support root
/// (`…/default.store`) into the app's namespaced subdirectory (`…/Oatmeal/default.store`).
/// Always ensures the namespaced dir exists (CoreData won't create intermediate dirs),
/// then moves the legacy store + its sidecars in when it's SAFE to do so. Runs at launch.
/// No-op once migrated or on a fresh install. When relocation is deferred or fails, the
/// legacy store stays put and `StorageManager.storeURL()` keeps resolving to it, so the
/// real data is never abandoned. The JSON backup is the final backstop.
private func migrateStoreToNamespacedDir() {
    let fm = FileManager.default
    guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let newDir = appSupport.appendingPathComponent("Oatmeal", isDirectory: true)
    // Ensure the namespaced dir exists so a fresh install / post-migration open has
    // somewhere to create or find the store.
    try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

    let namespaced = newDir.appendingPathComponent("default.store")
    let legacy = appSupport.appendingPathComponent("default.store")
    // Already migrated, or a fresh install (no legacy store) → nothing to move.
    guard !fm.fileExists(atPath: namespaced.path), fm.fileExists(atPath: legacy.path) else { return }

    // Only relocate from a CHECKPOINTED store: a non-empty `-wal` means uncommitted
    // frames (e.g. after a crash). Moving only some of the files could split the db
    // from its WAL, so defer to a later, clean launch — until then we keep opening the
    // legacy store in place (see StorageManager.storeURL).
    let legacyWAL = appSupport.appendingPathComponent("default.store-wal")
    if let size = (try? fm.attributesOfItem(atPath: legacyWAL.path))?[.size] as? Int, size > 0 {
        Log.warn("store relocation deferred — WAL not checkpointed (\(size)B); using legacy store", "store")
        return
    }
    do {
        for suffix in ["", "-wal", "-shm"] {
            let src = appSupport.appendingPathComponent("default.store\(suffix)")
            let dst = newDir.appendingPathComponent("default.store\(suffix)")
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try fm.moveItem(at: src, to: dst)
        }
        Log.warn("Relocated store to namespaced dir \(newDir.path)", "store")
    } catch {
        // Leave the legacy store in place; storeURL() keeps resolving to it and the
        // open-failure path + JSON backup recover if needed.
        Log.error("store relocation failed; using legacy location", "store", error)
    }
}
