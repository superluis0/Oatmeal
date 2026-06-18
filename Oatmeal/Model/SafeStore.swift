import Foundation
import SwiftData

/// Best-effort SwiftData saves. SwiftData/CoreData can raise Objective-C
/// exceptions (e.g. saving a relationship to a row that was deleted) which Swift
/// can't catch with `try?`. This routes the save through an ObjC `@try/@catch`
/// and, on failure, rolls back the offending change and logs it.
///
/// IMPORTANT LIMITATION: the ObjC catch only helps when the exception is raised
/// *before* the work crosses into CoreData's `performBlockAndWait`. An exception
/// thrown *inside* the save (the common case) is rethrown by `performBlockAndWait`
/// and unwinds back through SwiftData's own Swift frames before it can reach this
/// `@catch` — and an ObjC exception unwinding through Swift frames calls
/// `std::terminate`, aborting the app regardless. So this is NOT a guarantee.
/// The real protection is to avoid making `save()` throw: never call it
/// re-entrantly from inside a SwiftUI update/layout pass (defer such saves to the
/// next main-actor turn — see `MeetingDetailView.renameSpeaker`).
@MainActor
enum SafeStore {

    /// Save the context, catching both Swift errors and ObjC exceptions.
    /// Returns true on success.
    @discardableResult
    static func save(_ context: ModelContext, _ context_label: String = "") -> Bool {
        var swiftError: Error?
        let exception = ExceptionCatcher.catch {
            do { try context.save() } catch { swiftError = error }
        }
        if let exception {
            Log.error("save raised an exception (\(context_label)): \(exception.name.rawValue) — \(exception.reason ?? "")", "store")
            // Discard the bad pending change so the context isn't left wedged.
            ExceptionCatcher.catch { context.rollback() }
            return false
        }
        if let swiftError {
            Log.error("save failed (\(context_label))", "store", swiftError)
            // A store-LEVEL failure (the SQLite file can't be opened/written) means
            // the database is no longer trustworthy — continuing to read model
            // objects can hit a fault-fulfillment trap. Flag it so the UI prompts a
            // restart, which recovers from the latest backup on relaunch. This is
            // distinct from an ordinary per-object validation error.
            let ns = swiftError as NSError
            if ns.code == 256 || ns.userInfo["NSSQLiteErrorDomain"] != nil
                || (134_000...134_999).contains(ns.code) {
                // Log the underlying error chain + on-disk diagnostics ONCE (first
                // failure) so a crash report tells us WHY the SQLite file couldn't be
                // opened — the sqlite extended result code and any nested POSIX/OSStatus
                // reason the bare Code 256 hides, plus whether the file is missing,
                // locked, huge, or out of disk — instead of guessing.
                if !StoreHealth.shared.degraded {
                    Log.error("store appears unreadable (\(context_label)) — \(errorDiagnostics(ns)) — \(storeDiagnostics()) — prompting restart", "store")
                }
                StoreHealth.shared.degraded = true
            }
            return false
        }
        return true
    }

    /// On-disk facts about the SwiftData store, for diagnosing store-level failures:
    /// where it lives, whether each file exists + its size, and free disk space.
    /// Reads the store location from the single source of truth (`StorageManager`),
    /// so it tracks the namespaced relocation automatically.
    private static func storeDiagnostics() -> String {
        let fm = FileManager.default
        guard let store = StorageManager.storeURL() else { return "store=unavailable" }
        let dir = store.deletingLastPathComponent()
        let base = store.lastPathComponent
        func info(_ suffix: String) -> String {
            let url = dir.appendingPathComponent(base + suffix)
            guard fm.fileExists(atPath: url.path) else { return "\(base + suffix):missing" }
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
            return "\(base + suffix):\(size)B"
        }
        var free = "?"
        if let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = vals.volumeAvailableCapacityForImportantUsage {
            free = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return "dir=\(dir.path) [\(info("")), \(info("-wal")), \(info("-shm"))] freeDisk=\(free)"
    }

    /// Pulls the real cause out of a store error that surfaces as the generic
    /// Code 256: the sqlite primary/extended result codes and any nested
    /// `NSUnderlyingError` chain (often a POSIX/OSStatus reason the bare code hides).
    /// Logged once on the first store-level failure so the next crash report names
    /// the actual cause instead of leaving us to guess.
    private static func errorDiagnostics(_ error: NSError) -> String {
        var parts = ["\(error.domain):\(error.code)"]
        if let sqlite = error.userInfo["NSSQLiteErrorDomain"] { parts.append("sqlite=\(sqlite)") }
        if let path = error.userInfo[NSFilePathErrorKey] as? String { parts.append("path=\(path)") }
        var under = error.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let u = under, depth < 4 {
            parts.append("under=\(u.domain):\(u.code)")
            if let sqlite = u.userInfo["NSSQLiteErrorDomain"] { parts.append("sqlite=\(sqlite)") }
            under = u.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " ")
    }

    private static var pendingSave: Task<Void, Never>?

    /// Schedule a save on a LATER main-actor turn instead of right now. Use this
    /// for any save triggered by a SwiftUI view update — a binding `set:` closure,
    /// `.onChange`, `.onSubmit`, or an editor callback — where calling `save()`
    /// synchronously re-enters SwiftData mid-update and can abort the app (see the
    /// type doc above). The work hops past the current update/layout, so the save
    /// commits cleanly.
    ///
    /// Successive calls coalesce: a short debounce collapses a burst of edits (e.g.
    /// per-keystroke transcript or notes editing) into a single save shortly after
    /// the last change. Autosave still covers anything in flight, so a coalesced
    /// call that never fires (rapid quit) loses nothing.
    static func saveSoon(_ context: ModelContext, _ context_label: String = "") {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            save(context, context_label)
        }
    }
}

/// Observable health flag for the persistent store. Set when a save fails at the
/// SQLite/store level (not a normal per-object error) — at that point the store
/// can't be trusted and reading model objects may trap, so the UI surfaces a
/// "restart to recover" prompt (see `ContentView`). Recovery itself is automatic
/// on the next launch via `StoreBackup`.
@MainActor
@Observable
final class StoreHealth {
    static let shared = StoreHealth()
    var degraded = false
    private init() {}
}
