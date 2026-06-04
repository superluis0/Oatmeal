import Foundation
import SwiftData

/// Crash-proof SwiftData saves. SwiftData/CoreData can raise Objective-C
/// exceptions (e.g. saving a relationship to a row that was deleted) which Swift
/// cannot catch with `try?` — they abort the app. This routes saves through an
/// ObjC exception bridge and, on failure, rolls back the offending change and
/// logs it instead of crashing.
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
}
