import Foundation
import AppKit
import UniformTypeIdentifiers

/// Renders a meeting to Markdown and exports it to a file or the clipboard.
@MainActor
enum MarkdownExporter {

    static func markdown(for meeting: Meeting) -> String {
        var out = "# \(meeting.title)\n\n"
        out += meeting.date.formatted(date: .abbreviated, time: .shortened) + "\n\n"

        if !meeting.attendees.isEmpty {
            out += "**Attendees:** " + meeting.attendees.map(\.name).joined(separator: ", ") + "\n\n"
        }
        if !meeting.enhancedNotes.isEmpty {
            out += "## Notes\n\n\(meeting.enhancedNotes)\n\n"
        }
        if let s = meeting.summary {
            if !s.text.isEmpty { out += "## Summary\n\n\(s.text)\n\n" }
            if !s.keyPoints.isEmpty {
                out += "## Key Points\n\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            if !s.actionItems.isEmpty {
                out += "## Action Items\n\n" + s.actionItems.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        if !meeting.segments.isEmpty {
            out += "## Transcript\n\n"
            for seg in meeting.orderedSegments {
                out += "**\(meeting.displayName(for: seg.speaker)):** \(seg.text)\n\n"
            }
        }
        return out
    }

    static func copyToPasteboard(_ meeting: Meeting) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown(for: meeting), forType: .string)
    }

    /// A clean, shareable recap — title, date, attendees, summary, key points, and
    /// action items, but NO transcript or raw notes, so it's safe to paste into Slack
    /// or an email. Prefers the structured action items (with owners) when present.
    static func recap(for meeting: Meeting) -> String {
        var out = "# \(meeting.title)\n\n"
        out += meeting.date.formatted(date: .abbreviated, time: .shortened) + "\n\n"
        if !meeting.attendees.isEmpty {
            out += "**Attendees:** " + meeting.attendees.map(\.name).joined(separator: ", ") + "\n\n"
        }
        if let s = meeting.summary {
            if !s.text.isEmpty { out += "## Summary\n\n\(s.text)\n\n" }
            if !s.keyPoints.isEmpty {
                out += "## Key Points\n\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        let tasks = meeting.liveActionItems
        if !tasks.isEmpty {
            // Build line-by-line with simple statements — the one-expression `map`
            // version pinned Swift's type-checker (fine locally, timed out in CI).
            out += "## Action Items\n\n"
            for item in tasks {
                let body = item.isDone ? "~~\(item.text)~~" : item.text
                let owner = item.owner.map { " — \($0)" } ?? ""
                out += "- \(body)\(owner)\n"
            }
            out += "\n"
        } else if let s = meeting.summary, !s.actionItems.isEmpty {
            out += "## Action Items\n\n" + s.actionItems.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    static func copyRecap(_ meeting: Meeting) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(recap(for: meeting), forType: .string)
    }

    static func exportToFile(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = sanitized(meeting.title) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown(for: meeting).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            reportFailure("Couldn't save the file: \(error.localizedDescription)")
        }
    }

    static func exportPDF(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sanitized(meeting.title) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let info = NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
        let contentWidth = info.paperSize.width - info.leftMargin - info.rightMargin

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 1))
        textView.string = markdown(for: meeting)
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.sizeToFit()

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() {
            reportFailure("Couldn't create the PDF.")
        }
    }

    /// Exports one Markdown file per meeting (with YAML frontmatter) into a folder —
    /// an Obsidian/Notion-friendly vault.
    static func exportVault(_ meetings: [Meeting]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var failures = 0
        for m in meetings {
            let url = dir.appendingPathComponent(sanitized(m.title) + ".md")
            do {
                try markdownWithFrontmatter(m).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                failures += 1
                Log.error("vault export failed for \(m.title)", "export", error)
            }
        }
        if failures > 0 {
            reportFailure("\(failures) of \(meetings.count) meeting\(meetings.count == 1 ? "" : "s") couldn't be written — check the folder's permissions and free space.")
        }
    }

    /// Surfaces an export failure with an alert instead of letting it vanish silently.
    private static func reportFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func markdownWithFrontmatter(_ meeting: Meeting) -> String {
        let attendees = meeting.attendees.map { "\"\(yaml($0.name))\"" }.joined(separator: ", ")
        let tags = meeting.tags.map { "\"\(yaml($0))\"" }.joined(separator: ", ")
        var fm = "---\n"
        fm += "title: \"\(yaml(meeting.title))\"\n"
        fm += "date: \(ISO8601DateFormatter().string(from: meeting.date))\n"
        if !attendees.isEmpty { fm += "attendees: [\(attendees)]\n" }
        if !tags.isEmpty { fm += "tags: [\(tags)]\n" }
        fm += "---\n\n"
        return fm + markdown(for: meeting)
    }

    /// Escapes a value for use inside a double-quoted YAML string so a title with
    /// quotes/newlines can't break (or inject keys into) the frontmatter.
    private static func yaml(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }

    /// Produces a safe, single-component filename. Strips path separators (so a
    /// title like `../../evil` can't traverse out of the chosen folder), drops
    /// leading dots (no hidden files), and falls back to a default when empty.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\u{0}"))
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n\r"))
        return cleaned.isEmpty ? "Meeting" : cleaned
    }
}
