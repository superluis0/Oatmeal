import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A cozy, structured reader for Oatmeal's diagnostic log. The log file itself is
/// plain text (and still openable in any editor via "Reveal in Finder"); this view
/// just gives it structure — color-coded severities, category chips, search, a
/// warnings-and-errors filter, expandable crash backtraces, and one-tap actions for
/// copying or saving a support-ready report.
///
/// Everything shown is a breadcrumb (what the app did, when) — never audio,
/// transcripts, or note content. Lives in its own window (`id: "logs"`), reachable
/// from Settings → Privacy and the app menu.
struct LogViewerView: View {
    @State private var entries: [Log.Entry] = []
    @State private var search = ""
    @State private var levelFilter: LevelFilter = .all
    @State private var loading = true
    @State private var copied = false
    /// Mirror the main window's appearance — this window is its own scene, so it
    /// won't inherit the app's light/dark preference unless we apply it here too.
    @State private var appearance = Appearance.shared

    /// Coarse severity filter — the two views that actually matter for support.
    enum LevelFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case problems = "Warnings & errors"
        var id: String { rawValue }
    }

    /// Newest first: the most recent breadcrumbs are what you reach for when
    /// something just went wrong, so they shouldn't require a scroll.
    private var filtered: [Log.Entry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [Log.Entry] = []
        for entry in entries.reversed() where matches(entry, query: q) {
            result.append(entry)
        }
        return result
    }

    private func matches(_ entry: Log.Entry, query q: String) -> Bool {
        if levelFilter == .problems {
            let isProblem = entry.level == .warn || entry.level == .error || entry.level == .crash
            if !isProblem { return false }
        }
        if q.isEmpty { return true }
        if entry.message.lowercased().contains(q) { return true }
        if let category = entry.category, category.lowercased().contains(q) { return true }
        return entry.timestamp.contains(q)
    }

    private var problemCount: Int {
        entries.filter { $0.level == .error || $0.level == .crash }.count
    }
    private var warningCount: Int {
        entries.filter { $0.level == .warn }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(minWidth: 640, idealWidth: 840, minHeight: 460, idealHeight: 640)
        .background(Theme.bg)
        .fontDesign(appearance.fontDesign)
        .preferredColorScheme(appearance.colorScheme)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logs").font(.system(.title2).weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                actions
            }
            HStack(spacing: Theme.Space.sm) {
                searchField
                Picker("", selection: $levelFilter) {
                    ForEach(LevelFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(Theme.Space.lg)
    }

    private var subtitle: String {
        if loading { return "Loading…" }
        if entries.isEmpty { return "No activity logged yet" }
        var parts = ["\(entries.count) entr\(entries.count == 1 ? "y" : "ies")"]
        if problemCount > 0 { parts.append("\(problemCount) error\(problemCount == 1 ? "" : "s")") }
        if warningCount > 0 { parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }
        if Log.lastCrashReport != nil { parts.append("last session crashed") }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.xs) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Log.diagnosticsSummary(), forType: .string)
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { copied = false }
                }
            } label: {
                Label(copied ? "Copied ✓" : "Copy report",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(OatSecondaryButton())

            iconButton("square.and.arrow.down", help: "Save report…", action: saveReport)
            iconButton("folder", help: "Reveal log files in Finder", action: revealInFinder)
            iconButton("arrow.clockwise", help: "Refresh") { Task { await load() } }
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .foregroundStyle(Theme.textSecondary)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField("Search logs", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(.callout))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceAlt, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            OatEmptyState(icon: "doc.text.magnifyingglass",
                          title: "No logs yet",
                          message: "Oatmeal records what it does here — launches, recordings, and anything that goes wrong. There's nothing to show yet.")
        } else if filtered.isEmpty {
            OatEmptyState(icon: "line.3.horizontal.decrease.circle",
                          title: "Nothing matches",
                          message: search.isEmpty
                            ? "No warnings or errors — that's a good sign."
                            : "No log entries match “\(search)”.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        if entry.isSessionBanner {
                            SessionDivider(text: entry.bannerText)
                        } else {
                            LogRow(entry: entry)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.xs)
            }
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        let parsed = await Task.detached(priority: .userInitiated) { Log.recentEntries() }.value
        entries = parsed
        loading = false
    }

    // MARK: - Actions

    private func revealInFinder() {
        guard let dir = Log.logDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Oatmeal-log.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Save Diagnostics Report"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Log.diagnosticsSummary().write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Row

private struct LogRow: View {
    let entry: Log.Entry

    /// Crash backtraces (and any folded multi-line message) collapse to one line
    /// until expanded, so a single crash doesn't flood the list.
    private var isMultiline: Bool { entry.message.contains("\n") }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(entry.level.tint)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.shortTime)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    if entry.level != .info {
                        Text(entry.level.label)
                            .font(.system(.caption2).weight(.bold))
                            .foregroundStyle(entry.level.tint)
                    }
                    if let category = entry.category, category != "app" {
                        Text(category)
                            .font(.system(.caption2).weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.surfaceAlt, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                message
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, Theme.Space.xs)
        .background(entry.level.rowTint, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .textSelection(.enabled)
    }

    @ViewBuilder private var message: some View {
        if isMultiline {
            DisclosureGroup {
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Text(entry.firstLine)
                    .font(.system(.callout))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .tint(Theme.textSecondary)
        } else {
            Text(entry.message)
                .font(.system(.callout))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Session divider

private struct SessionDivider: View {
    let text: String
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            line
            Text(text)
                .font(.system(.caption2).weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            line
        }
        .padding(.vertical, Theme.Space.sm)
    }
    private var line: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

// MARK: - Level styling (kept in the view layer so Log stays UI-free)

private extension Log.Level {
    var label: String {
        switch self {
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .crash: return "CRASH"
        }
    }

    var tint: Color {
        switch self {
        case .info: return Theme.textTertiary
        case .warn: return .adaptive(light: 0xC7892B, dark: 0xE0A33C)
        case .error: return Theme.danger
        case .crash: return .adaptive(light: 0xB23A2A, dark: 0xE2705E)
        }
    }

    /// A whisper of background tint so problems stand out without shouting.
    var rowTint: Color {
        switch self {
        case .info, .warn: return .clear
        case .error: return Theme.danger.opacity(0.06)
        case .crash: return Theme.danger.opacity(0.10)
        }
    }
}

// MARK: - Entry display helpers

private extension Log.Entry {
    var shortTime: String {
        if let date { return Self.timeFormatter.string(from: date) }
        // Fall back to the time slice of "yyyy-MM-dd HH:mm:ss.SSS".
        let parts = timestamp.split(separator: " ")
        return parts.count == 2 ? String(parts[1].prefix(8)) : timestamp
    }

    var firstLine: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message }

    /// The launch banner with its box-drawing rule stripped → "Oatmeal x.y.z (b) launched".
    var bannerText: String {
        message.trimmingCharacters(in: CharacterSet(charactersIn: "─ "))
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
