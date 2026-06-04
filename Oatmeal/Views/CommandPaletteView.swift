import SwiftUI
import AppKit

/// A ⌘K command palette: fuzzy-jump to any meeting, or run a quick action —
/// global commands plus context actions for the currently-open meeting.
/// Full keyboard control: type to filter, ↑/↓ to move, ↵ to run, esc to close.
struct CommandPaletteView: View {
    let meetings: [Meeting]
    var selectedMeeting: Meeting?
    var isRecording: Bool
    var onSelectMeeting: (Meeting) -> Void
    var onNewRecording: () -> Void
    var onToggleRecording: () -> Void
    var onImportAudio: () -> Void
    var onExportAll: () -> Void
    var onDeleteMeeting: (Meeting) -> Void
    var onAskOatmeal: () -> Void
    var onPeople: () -> Void
    var onTasks: () -> Void
    var onUpcoming: () -> Void
    var onDigest: () -> Void
    var onDecisions: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String?
        let icon: String
        let section: String
        let run: () -> Void
        init(_ title: String, icon: String, section: String, subtitle: String? = nil, run: @escaping () -> Void) {
            self.title = title; self.icon = icon; self.section = section; self.subtitle = subtitle; self.run = run
        }
    }

    private var allItems: [Item] {
        var items: [Item] = []

        // Recording.
        if isRecording {
            items.append(Item("Stop Recording", icon: "stop.fill", section: "Actions", run: onToggleRecording))
        } else {
            items.append(Item("New Recording", icon: "record.circle.fill", section: "Actions", run: onNewRecording))
        }
        items.append(Item("Import Audio…", icon: "square.and.arrow.down", section: "Actions", run: onImportAudio))

        // Navigation.
        items.append(Item("Upcoming Meetings", icon: "calendar", section: "Go to", run: onUpcoming))
        items.append(Item("Tasks", icon: "checklist", section: "Go to", run: onTasks))
        items.append(Item("People", icon: "person.2", section: "Go to", run: onPeople))
        items.append(Item("Digest", icon: "doc.text.magnifyingglass", section: "Go to", run: onDigest))
        items.append(Item("Decisions", icon: "checkmark.seal", section: "Go to", run: onDecisions))
        items.append(Item("Ask Oatmeal", icon: "sparkles", section: "Go to", run: onAskOatmeal))
        items.append(Item("Settings", icon: "gearshape", section: "Go to", run: openSettings))
        items.append(Item("Export All to Markdown…", icon: "folder.badge.plus", section: "Go to", run: onExportAll))

        // Context actions for the open meeting.
        if let m = selectedMeeting {
            items.append(Item("Copy “\(m.title)” as Markdown", icon: "doc.on.doc", section: "This meeting") {
                MarkdownExporter.copyToPasteboard(m)
            })
            items.append(Item("Export “\(m.title)”…", icon: "square.and.arrow.up", section: "This meeting") {
                MarkdownExporter.exportToFile(m)
            })
            items.append(Item("Delete “\(m.title)”", icon: "trash", section: "This meeting") {
                onDeleteMeeting(m)
            })
        }

        return items
    }

    /// Items (fuzzy-filtered) followed by matching meetings, as one flat list for
    /// arrow-key traversal.
    private var results: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Item] = []
        if q.isEmpty {
            out = allItems
        } else {
            out = allItems
                .compactMap { item in Self.score(item.title, q).map { ($0, item) } }
                .sorted { $0.0 > $1.0 }
                .map { $0.1 }
        }

        let meetingMatches: [Meeting]
        if q.isEmpty {
            meetingMatches = Array(meetings.prefix(6))
        } else {
            meetingMatches = meetings
                .compactMap { m in Self.score(m.title, q).map { ($0, m) } }
                .sorted { $0.0 > $1.0 }
                .prefix(8)
                .map { $0.1 }
        }
        out += meetingMatches.map { m in
            Item(m.title, icon: "waveform", section: "Meetings",
                 subtitle: m.date.formatted(date: .abbreviated, time: .shortened)) {
                onSelectMeeting(m)
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Jump to a meeting or run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.title3))
                    .focused($focused)
                    .onSubmit(runHighlighted)
                    .onChange(of: query) { _, _ in highlighted = 0 }
            }
            .padding(Theme.Space.md)
            Divider().overlay(Theme.hairline)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let items = results
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            if idx == 0 || items[idx - 1].section != item.section {
                                SectionLabel(text: item.section)
                                    .padding(.horizontal, Theme.Space.md)
                                    .padding(.top, Theme.Space.xs)
                            }
                            row(item, isHighlighted: idx == highlighted)
                                .id(idx)
                                .onTapGesture { perform(item.run) }
                                .onHover { if $0 { highlighted = idx } }
                        }
                        if items.isEmpty {
                            Text("No matches").font(.callout).foregroundStyle(Theme.textSecondary)
                                .padding(Theme.Space.md)
                        }
                    }
                    .padding(.bottom, Theme.Space.xs)
                }
                .frame(maxHeight: 380)
                .onChange(of: highlighted) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(width: 580)
        .background(Theme.surface)
        .fontDesign(Appearance.shared.fontDesign)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ item: Item, isHighlighted: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: item.icon).frame(width: 20)
                .foregroundStyle(isHighlighted ? Theme.onAccent : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).foregroundStyle(isHighlighted ? Theme.onAccent : Theme.textPrimary).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption)
                        .foregroundStyle(isHighlighted ? Theme.onAccent.opacity(0.85) : Theme.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .background(isHighlighted ? Theme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .padding(.horizontal, Theme.Space.xs)
        .contentShape(Rectangle())
    }

    private func moveHighlight(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func runHighlighted() {
        let items = results
        guard items.indices.contains(highlighted) else {
            if let first = items.first { perform(first.run) }
            return
        }
        perform(items[highlighted].run)
    }

    private func perform(_ action: () -> Void) {
        action()
        dismiss()
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Lightweight fuzzy subsequence score: higher is better, nil if no match.
    /// Rewards contiguous runs and word-start matches.
    static func score(_ text: String, _ query: String) -> Int? {
        let t = Array(text.lowercased()), q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        var ti = 0, qi = 0, score = 0, streak = 0
        while ti < t.count && qi < q.count {
            if t[ti] == q[qi] {
                score += 1 + streak
                if ti == 0 || t[ti - 1] == " " { score += 3 }
                streak += 1; qi += 1
            } else {
                streak = 0
            }
            ti += 1
        }
        return qi == q.count ? score : nil
    }
}
