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
