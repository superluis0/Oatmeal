import Foundation
import SwiftData

/// Lets the local MCP server (a separate process) make GUARDED writes back into the
/// live store, on-device. The MCP drops a command JSON into an inbox directory; the
/// app — **only while the user has enabled MCP writes** — picks it up, applies it,
/// deletes it, and re-syncs the read mirror. A flag file tells the MCP whether
/// writes are currently allowed (so it can refuse with a helpful message when off).
@MainActor
final class MCPCommandInbox {
    static let shared = MCPCommandInbox()
    private var timer: Timer?
    private weak var context: ModelContext?

    private static var supportDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Oatmeal", isDirectory: true)
    }
    private static var inboxDir: URL? { supportDir?.appendingPathComponent("mcp-commands", isDirectory: true) }
    private static var enabledFlag: URL? { supportDir?.appendingPathComponent("mcp-write-enabled") }

    /// Call once at launch with the live context.
    func start(context: ModelContext) {
        self.context = context
        setEnabled(AppSettings.mcpWriteEnabled)
    }

    /// Reflect the Settings toggle: maintain the flag file the MCP checks, and start
    /// or stop polling the inbox.
    func setEnabled(_ on: Bool) {
        guard let flag = Self.enabledFlag, let inbox = Self.inboxDir else { return }
        timer?.invalidate(); timer = nil
        if on {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: Data())
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: flag.path)
            processInbox()   // apply anything queued while writes were off
            let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in MCPCommandInbox.shared.processInbox() }
            }
            timer = t
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    private func processInbox() {
        guard AppSettings.mcpWriteEnabled, let inbox = Self.inboxDir, let context else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        var changed = false
        for file in files {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = cmd["op"] as? String else { continue }
            if apply(op: op, cmd: cmd, context: context) { changed = true }
        }
        if changed {
            SafeStore.save(context, "mcp-command")
            MCPExport.sync(context: context)
        }
    }

    private func apply(op: String, cmd: [String: Any], context: ModelContext) -> Bool {
        switch op {
        case "append_note":
            guard let idStr = cmd["meetingId"] as? String, let uuid = UUID(uuidString: idStr),
                  let text = (cmd["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let meeting = meeting(uuid, context) else { return false }
            meeting.notes = meeting.notes.isEmpty ? text : meeting.notes + "\n\n\u{2014} via agent \u{2014}\n" + text
            Log.info("MCP append_note applied to \(meeting.title)", "mcp")
            return true
        default:
            Log.warn("MCP unknown command op: \(op)", "mcp")
            return false
        }
    }

    private func meeting(_ id: UUID, _ context: ModelContext) -> Meeting? {
        let d = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d))?.first
    }
}
