import Foundation
import os

/// Lightweight, robust diagnostics: structured breadcrumbs to the unified log
/// (Console.app) AND to a rotating file in Application Support, plus crash capture
/// (uncaught Obj-C exceptions and fatal signals — including the SIGTRAP that Swift
/// precondition failures raise). The file survives a crash, so the next launch can
/// surface "Oatmeal quit unexpectedly last time" with the backtrace.
enum Log {
    private static let osLog = Logger(subsystem: "com.oatmeal.Oatmeal", category: "app")
    private static let queue = DispatchQueue(label: "com.oatmeal.log")
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let maxBytes = 2_000_000
    nonisolated(unsafe) private static var started = false
    /// Set on launch if the previous session crashed, for one-time UI surfacing.
    nonisolated(unsafe) static var lastCrashReport: String?

    static var logDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Oatmeal/Logs", isDirectory: true)
    }
    private static var logURL: URL? { logDirectory?.appendingPathComponent("oatmeal.log") }
    private static var crashMarkerURL: URL? { logDirectory?.appendingPathComponent("did-crash") }

    // MARK: - Lifecycle

    /// Open the log file, install crash handlers, and record launch. Idempotent.
    static func start() {
        guard !started else { return }
        started = true
        openFile()
        installCrashHandlers()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        info("──────── Oatmeal \(v) (\(b)) launched ────────")
    }

    /// If the previous run left a crash marker, return its contents and clear it.
    static func consumeLastCrash() -> String? {
        guard let url = crashMarkerURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: url)
        return text
    }

    // MARK: - Levels

    static func info(_ message: String, _ category: String = "app") { emit("INFO", category, message) }
    static func warn(_ message: String, _ category: String = "app") { emit("WARN", category, message) }
    static func error(_ message: String, _ category: String = "app", _ error: Error? = nil) {
        let suffix = error.map { " — \($0)" } ?? ""
        emit("ERROR", category, message + suffix)
    }

    // MARK: - Internals

    private static func emit(_ level: String, _ category: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] [\(category)] \(message)"
        switch level {
        case "ERROR": osLog.error("\(line, privacy: .public)")
        case "WARN": osLog.warning("\(line, privacy: .public)")
        default: osLog.info("\(line, privacy: .public)")
        }
        queue.async { appendToFile(line + "\n") }
    }

    /// One shared formatter: `DateFormatter` is expensive to allocate and its
    /// formatting methods are thread-safe once configured, so a single static
    /// instance serves every log line (all emitted on `Log.queue`).
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    private static func openFile() {
        guard let dir = logDirectory, let url = logURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()  // position at EOF for appending; offset unused
    }

    private static func appendToFile(_ text: String) {
        guard let handle, let data = text.data(using: .utf8) else { return }
        handle.write(data)
        // Rotate when too large: keep one previous generation.
        if let size = try? handle.offset(), size > maxBytes { rotate() }
    }

    private static func rotate() {
        guard let dir = logDirectory, let url = logURL else { return }
        try? handle?.close()
        let prev = dir.appendingPathComponent("oatmeal.prev.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    // MARK: - Crash capture

    private static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let bt = exception.callStackSymbols.joined(separator: "\n")
            Log.writeCrash("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "")\n\(bt)")
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { received in
                let bt = Thread.callStackSymbols.joined(separator: "\n")
                Log.writeCrash("Fatal signal \(received)\n\(bt)")
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Best-effort synchronous crash write (also drops a marker for next launch).
    /// Not strictly async-signal-safe, but reliable enough for a local diagnostics tool.
    private static func writeCrash(_ details: String) {
        let block = "\n\(timestamp()) [CRASH] \(details)\n"
        if let handle, let data = block.data(using: .utf8) {
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        }
        if let marker = crashMarkerURL, let data = block.data(using: .utf8) {
            try? data.write(to: marker)
        }
    }
}
