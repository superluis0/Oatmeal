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
            return false
        }
        return true
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
