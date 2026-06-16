import Foundation
import os
import Darwin

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

    // MARK: - Structured entries (for the in-app log viewer)

    /// Severity of a parsed line. The on-disk format stays plain and human-readable
    /// (`timestamp [LEVEL] [category] message`); this just turns it back into a
    /// structured record so the in-app viewer can badge, filter, and group it.
    enum Level: String, CaseIterable, Sendable {
        case info = "INFO", warn = "WARN", error = "ERROR", crash = "CRASH"
    }

    /// One parsed log line. Multi-line writes (notably crash backtraces) are folded
    /// into a single entry's `message`.
    struct Entry: Identifiable, Sendable {
        let id: Int
        let timestamp: String
        let date: Date?
        let level: Level
        let category: String?
        var message: String
        /// True for the "──── Oatmeal x.y.z launched ────" banner, which the viewer
        /// renders as a session divider rather than a normal row.
        var isSessionBanner: Bool
    }

    /// Compiled once. The viewer re-parses the file on open/refresh (not per line),
    /// so a single shared regex is plenty.
    private static let lineParser = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) \[([A-Z]+)\](?: \[([^\]]+)\])? ?(.*)$"#
    )

    /// Parse the previous (post-rotation) and current log files into structured
    /// entries, oldest first. Lines that don't start with a timestamp (crash
    /// backtrace frames, wrapped text) fold into the preceding entry's message.
    /// Returns at most `maxEntries`, dropping the oldest beyond that.
    ///
    /// Safe to call off the main actor — it only reads files and `Log` statics.
    static func recentEntries(maxEntries: Int = 2000) -> [Entry] {
        var text = ""
        if let prev = logDirectory?.appendingPathComponent("oatmeal.prev.log"),
           let s = try? String(contentsOf: prev, encoding: .utf8) {
            text += s
        }
        if let url = logURL, let s = try? String(contentsOf: url, encoding: .utf8) {
            text += s
        }
        guard !text.isEmpty else { return [] }

        var entries: [Entry] = []
        var nextID = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let parsed = parse(line) {
                let banner = parsed.level == .info && parsed.message.hasPrefix("────")
                entries.append(Entry(id: nextID, timestamp: parsed.timestamp,
                                     date: parseDate(parsed.timestamp), level: parsed.level,
                                     category: parsed.category, message: parsed.message,
                                     isSessionBanner: banner))
                nextID += 1
            } else if !entries.isEmpty {
                // Continuation line (crash backtrace frame, etc.) — fold into the
                // entry it belongs to.
                entries[entries.count - 1].message += "\n" + line
            }
        }
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        for i in entries.indices {
            entries[i].message = entries[i].message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return entries
    }

    private static func parse(_ line: String) -> (timestamp: String, level: Level, category: String?, message: String)? {
        guard let lineParser else { return nil }
        let ns = line as NSString
        guard let m = lineParser.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 5,
              let level = Level(rawValue: ns.substring(with: m.range(at: 2))) else { return nil }
        let ts = ns.substring(with: m.range(at: 1))
        let catRange = m.range(at: 3)
        let category = catRange.location == NSNotFound ? nil : ns.substring(with: catRange)
        let msgRange = m.range(at: 4)
        let message = msgRange.location == NSNotFound ? "" : ns.substring(with: msgRange)
        return (ts, level, category, message)
    }

    private static func parseDate(_ ts: String) -> Date? { timestampFormatter.date(from: ts) }

    /// A paste-able diagnostics report — a structured header (build, macOS, device,
    /// and a recent error/warning tally) followed by the last ~80 log lines
    /// (breadcrumbs only; never transcripts or audio) — for sending to support.
    static func diagnosticsSummary() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let device = sysctlString("hw.model") ?? "Mac"
        let arch = sysctlString("hw.machine") ?? "?"

        let entries = recentEntries(maxEntries: 600)
        let warnings = entries.filter { $0.level == .warn }.count
        let errors = entries.filter { $0.level == .error || $0.level == .crash }.count

        var out = "Oatmeal \(v) (\(b))\n"
        out += "macOS \(os)\n"
        out += "Device: \(device) · \(arch)\n"
        out += "Generated: \(timestampFormatter.string(from: Date()))\n"
        out += "Recent: \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")"
        if lastCrashReport != nil { out += " · previous session ended in a crash" }
        out += "\n"

        if let url = logURL, let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            let recent = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(80)
            out += "\n— Recent log —\n" + recent.joined(separator: "\n")
        }
        return out
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
        // POSIX locale so the numeric pattern round-trips identically regardless of
        // the user's region — important now that we also *parse* timestamps back
        // (see `recentEntries`), not just format them.
        f.locale = Locale(identifier: "en_US_POSIX")
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

    /// Read a string-valued sysctl (e.g. `hw.model`, `hw.machine`) for the support
    /// header. Returns nil if the key is missing or unreadable.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
