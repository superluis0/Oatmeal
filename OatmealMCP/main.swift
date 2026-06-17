import Foundation

// Minimal MCP (Model Context Protocol) server over stdio for Oatmeal.
// Reads the read-only JSON mirror written by the app and exposes meeting data
// to agents (Claude Desktop, etc.). Newline-delimited JSON-RPC 2.0.

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func mirrorURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Oatmeal/mcp-meetings.json")
}

func loadMeetings() -> [[String: Any]] {
    guard let url = mirrorURL(),
          let data = try? Data(contentsOf: url),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return arr
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func respond(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func respondError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func textResult(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]]]
}

func supportDir() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Oatmeal", isDirectory: true)
}

/// True when the user has enabled MCP writes in Oatmeal (the app maintains this flag file).
func writeEnabled() -> Bool {
    guard let f = supportDir()?.appendingPathComponent("mcp-write-enabled") else { return false }
    return FileManager.default.fileExists(atPath: f.path)
}

/// Drop a command into the app's inbox for it to apply (guarded writes).
func queueCommand(_ cmd: [String: Any]) -> Bool {
    guard let inbox = supportDir()?.appendingPathComponent("mcp-commands", isDirectory: true),
          let data = try? JSONSerialization.data(withJSONObject: cmd) else { return false }
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
    return (try? data.write(to: inbox.appendingPathComponent(name))) != nil
}

// MARK: - Tool definitions

let tools: [[String: Any]] = [
    [
        "name": "list_meetings",
        "description": "List all recorded meetings (title, date, attendees, tags).",
        "inputSchema": ["type": "object", "properties": [:]]
    ],
    [
        "name": "get_meeting",
        "description": "Get full details (summary, notes, transcript) for a meeting by id or exact title.",
        "inputSchema": [
            "type": "object",
            "properties": ["query": ["type": "string", "description": "Meeting id (UUID) or title"]],
            "required": ["query"]
        ]
    ],
    [
        "name": "search_meetings",
        "description": "Search meetings by keyword across titles, notes, and transcripts.",
        "inputSchema": [
            "type": "object",
            "properties": ["query": ["type": "string", "description": "Search text"]],
            "required": ["query"]
        ]
    ],
    [
        "name": "get_action_items",
        "description": "List action items across meetings — by default only OPEN (not done). Optional owner filter.",
        "inputSchema": ["type": "object", "properties": [
            "owner": ["type": "string", "description": "Only items owned by this person (optional)"],
            "include_done": ["type": "boolean", "description": "Include completed items (default false)"]
        ]]
    ],
    [
        "name": "get_commitments",
        "description": "Open action items grouped by owner — who owes what. Optional person filter.",
        "inputSchema": ["type": "object", "properties": [
            "person": ["type": "string", "description": "Only this person's commitments (optional)"]
        ]]
    ],
    [
        "name": "append_note",
        "description": "Append a note to a meeting by id. Requires the user to have enabled MCP writes in Oatmeal.",
        "inputSchema": ["type": "object", "properties": [
            "meeting_id": ["type": "string", "description": "Meeting id (UUID)"],
            "text": ["type": "string", "description": "Note text to append"]
        ], "required": ["meeting_id", "text"]]
    ]
]

// MARK: - Tool handlers

func meetingSummaryLine(_ m: [String: Any]) -> String {
    let title = m["title"] as? String ?? "Untitled"
    let date = m["date"] as? String ?? ""
    let attendees = (m["attendees"] as? [String])?.joined(separator: ", ") ?? ""
    let id = m["id"] as? String ?? ""
    var line = "- \(title) (\(date)) [id: \(id)]"
    if !attendees.isEmpty { line += " — \(attendees)" }
    return line
}

func meetingDetail(_ m: [String: Any]) -> String {
    let title = m["title"] as? String ?? "Untitled"
    let date = m["date"] as? String ?? ""
    let attendees = (m["attendees"] as? [String])?.joined(separator: ", ") ?? ""
    let summary = m["summary"] as? String ?? ""
    let keyPoints = (m["keyPoints"] as? [String])?.map { "- \($0)" }.joined(separator: "\n") ?? ""
    let actionItems = (m["actionItems"] as? [String])?.map { "- \($0)" }.joined(separator: "\n") ?? ""
    let notes = m["notes"] as? String ?? ""
    let transcript = m["transcript"] as? String ?? ""
    var out = "# \(title)\nDate: \(date)\n"
    if !attendees.isEmpty { out += "Attendees: \(attendees)\n" }
    if !summary.isEmpty { out += "\n## Summary\n\(summary)\n" }
    if !keyPoints.isEmpty { out += "\n## Key Points\n\(keyPoints)\n" }
    if !actionItems.isEmpty { out += "\n## Action Items\n\(actionItems)\n" }
    if !notes.isEmpty { out += "\n## Notes\n\(notes)\n" }
    if !transcript.isEmpty { out += "\n## Transcript\n\(transcript)\n" }
    return out
}

func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
    let meetings = loadMeetings()
    switch name {
    case "list_meetings":
        if meetings.isEmpty { return textResult("No meetings recorded yet.") }
        return textResult(meetings.map(meetingSummaryLine).joined(separator: "\n"))

    case "get_meeting":
        let q = (arguments["query"] as? String ?? "").lowercased()
        if let m = meetings.first(where: {
            ($0["id"] as? String)?.lowercased() == q
            || ($0["title"] as? String)?.lowercased() == q
        }) {
            return textResult(meetingDetail(m))
        }
        return textResult("No meeting found matching “\(arguments["query"] as? String ?? "")”.")

    case "search_meetings":
        let q = (arguments["query"] as? String ?? "").lowercased()
        guard !q.isEmpty else { return textResult("Provide a search query.") }
        let hits = meetings.filter { m in
            let hay = [
                m["title"] as? String ?? "",
                m["notes"] as? String ?? "",
                m["summary"] as? String ?? "",
                m["transcript"] as? String ?? ""
            ].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
        if hits.isEmpty { return textResult("No meetings matched “\(arguments["query"] as? String ?? "")”.") }
        return textResult(hits.map(meetingSummaryLine).joined(separator: "\n"))

    case "get_action_items":
        let owner = (arguments["owner"] as? String ?? "").lowercased()
        let includeDone = arguments["include_done"] as? Bool ?? false
        var lines: [String] = []
        for m in meetings {
            let title = m["title"] as? String ?? "Untitled"
            for t in (m["tasks"] as? [[String: Any]] ?? []) {
                let done = t["done"] as? Bool ?? false
                if !includeDone && done { continue }
                let tOwner = t["owner"] as? String ?? ""
                if !owner.isEmpty && !tOwner.lowercased().contains(owner) { continue }
                let mark = done ? "[x]" : "[ ]"
                let who = tOwner.isEmpty ? "" : " — \(tOwner)"
                lines.append("\(mark) \(t["text"] as? String ?? "")\(who)  ·  \(title)")
            }
        }
        return textResult(lines.isEmpty ? "No matching action items." : lines.joined(separator: "\n"))

    case "get_commitments":
        let person = (arguments["person"] as? String ?? "").lowercased()
        var byOwner: [String: [String]] = [:]
        for m in meetings {
            let title = m["title"] as? String ?? "Untitled"
            for t in (m["tasks"] as? [[String: Any]] ?? []) where !((t["done"] as? Bool) ?? false) {
                let o = t["owner"] as? String ?? ""
                let owner = o.isEmpty ? "Unassigned" : o
                if !person.isEmpty && !owner.lowercased().contains(person) { continue }
                byOwner[owner, default: []].append("• \(t["text"] as? String ?? "")  (\(title))")
            }
        }
        if byOwner.isEmpty { return textResult("No open commitments.") }
        return textResult(byOwner.sorted { $0.key < $1.key }
            .map { "\($0.key):\n" + $0.value.joined(separator: "\n") }
            .joined(separator: "\n\n"))

    case "append_note":
        guard writeEnabled() else {
            return textResult("Writing is turned off. Enable \u{201C}Let the MCP server write\u{201D} in Oatmeal → Settings → Automation, then try again.")
        }
        let mid = arguments["meeting_id"] as? String ?? ""
        let text = arguments["text"] as? String ?? ""
        guard !mid.isEmpty, !text.isEmpty else { return textResult("Provide meeting_id and text.") }
        guard meetings.contains(where: { ($0["id"] as? String)?.lowercased() == mid.lowercased() }) else {
            return textResult("No meeting with id \(mid).")
        }
        return textResult(queueCommand(["op": "append_note", "meetingId": mid, "text": text])
            ? "Queued — Oatmeal will append the note shortly."
            : "Couldn't queue the note.")

    default:
        return textResult("Unknown tool: \(name)")
    }
}

// MARK: - JSON-RPC loop

func handle(_ msg: [String: Any]) {
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]

    switch method {
    case "initialize":
        guard let id else { return }
        respond(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "oatmeal", "version": "1.0.0"]
        ])

    case "tools/list":
        guard let id else { return }
        respond(id: id, result: ["tools": tools])

    case "tools/call":
        guard let id else { return }
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        respond(id: id, result: callTool(name: name, arguments: args))

    case "ping":
        if let id { respond(id: id, result: [:]) }

    default:
        // Notifications (no id) need no response.
        if let id { respondError(id: id, code: -32601, message: "Method not found: \(method)") }
    }
}

log("oatmeal-mcp started")
while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    handle(msg)
}
