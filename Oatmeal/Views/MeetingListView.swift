import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct MeetingListView: View {
    /// Already filtered by the search field in ContentView.
    let meetings: [Meeting]
    let folders: [Folder]
    @Binding var selection: Meeting?
    let coordinator: RecordingCoordinator
    var onAskOatmeal: () -> Void
    var onPeople: () -> Void
    var onTasks: () -> Void
    var onUpcoming: () -> Void
    var onDigest: () -> Void
    var onDecisions: () -> Void = {}
    @Environment(\.modelContext) private var context

    private var openTaskCount: Int {
        meetings.reduce(0) { total, meeting in
            // Skip any meeting that's been deleted out from under the @Query
            // snapshot — touching its relationships would trap in SwiftData.
            meeting.modelContext != nil ? total + meeting.openActionItemCount : total
        }
    }

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folderTarget: Meeting?

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            VStack(spacing: Theme.Space.xs) {
                recordButton
                HStack(spacing: Theme.Space.xs) {
                    SidebarChip(title: "Upcoming", systemImage: "calendar", action: onUpcoming)
                    SidebarChip(title: "Ask", systemImage: "sparkles", action: onAskOatmeal)
                    SidebarChip(title: "Tasks", systemImage: "checklist", badge: openTaskCount, action: onTasks)
                    SidebarChip(title: "People", systemImage: "person.2", action: onPeople)
                }
                HStack(spacing: Theme.Space.xs) {
                    SidebarChip(title: "Digest", systemImage: "doc.text.magnifyingglass", action: onDigest)
                    SidebarChip(title: "Decisions", systemImage: "checkmark.seal", action: onDecisions)
                    SidebarChip(title: "Import", systemImage: "square.and.arrow.down", action: importAudio)
                        .disabled(coordinator.isBusy || coordinator.isRecording)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.bottom, Theme.Space.sm)
            List(selection: $selection) {
                if folders.isEmpty {
                    ForEach(meetings) { row($0) }
                        .onDelete { delete(at: $0, in: meetings) }
                } else {
                    ForEach(folders) { folder in
                        let items = meetings.filter { $0.folder?.persistentModelID == folder.persistentModelID }
                        if !items.isEmpty {
                            Section { ForEach(items) { row($0) } }
                            header: { SectionLabel(text: folder.name) }
                        }
                    }
                    let unfiled = meetings.filter { $0.folder == nil }
                    if !unfiled.isEmpty {
                        Section { ForEach(unfiled) { row($0) } }
                        header: { SectionLabel(text: "Unfiled") }
                    }
                }
            }
            .scrollContentBackground(.hidden)

            Divider().overlay(Theme.hairline)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(OatGhostButton())
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs)
        }
        .background(Theme.bg)
        .navigationTitle("Oatmeal")
        .toolbar {
            ToolbarItem {
                Button {
                    MarkdownExporter.exportVault(meetings)
                } label: {
                    Label("Export All", systemImage: "folder.badge.plus")
                }
                .help("Export all shown meetings to a Markdown folder")
                .disabled(meetings.isEmpty)
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        let isSelected = selection?.persistentModelID == meeting.persistentModelID
        return NavigationLink(value: meeting) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: Appearance.shared.scaled(14), weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : Theme.textPrimary)
                HStack(spacing: 5) {
                    Text(meeting.date, format: .dateTime.month().day().hour().minute())
                    if meeting.duration > 0 {
                        Text("·")
                        Text(meeting.durationLabel)
                    }
                }
                .font(.system(size: Appearance.shared.scaled(11)))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.textSecondary)
                if !meeting.tags.isEmpty {
                    Text(meeting.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.system(size: Appearance.shared.scaled(10)))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Theme.accent)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
        }
        .tag(meeting)
        .contextMenu {
            Menu("Move to Folder") {
                Button("None") { assign(meeting, to: nil) }
                ForEach(folders) { f in
                    Button(f.name) { assign(meeting, to: f) }
                }
                Divider()
                Button("New Folder…") {
                    folderTarget = meeting
                    showNewFolder = true
                }
            }
            Button("Delete", role: .destructive) { delete(meeting) }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 26, height: 26)
            Text("Oatmeal")
                .font(.system(.title3).weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
    }

    @ViewBuilder
    private var recordButton: some View {
        if coordinator.isRecording {
            Button {
                Task { await coordinator.stop(context: context) }
            } label: {
                Label("Stop Recording", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(OatPrimaryButton(fullWidth: true))
            .overlay(recordBorder)
        } else {
            Button {
                Task { await coordinator.start(context: context) }
            } label: {
                Label(coordinator.isBusy ? "Working…" : "New Recording",
                      systemImage: coordinator.isBusy ? "hourglass" : "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OatPrimaryButton(fullWidth: true))
            .overlay(recordBorder)
            .disabled(coordinator.isBusy)
        }
    }

    private var recordBorder: some View {
        SnakeBorder(
            color: Appearance.shared.recordBorderColor,
            rainbow: Appearance.shared.recordBorderRainbow,
            cornerRadius: Theme.Radius.md,
            active: coordinator.isRecording
        )
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func assign(_ meeting: Meeting, to folder: Folder?) {
        meeting.folder = folder
        try? context.save()
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        let folder = Folder(name: name)
        context.insert(folder)
        if let target = folderTarget {
            target.folder = folder
            folderTarget = nil
        }
        try? context.save()
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await coordinator.importAudio(url: url, context: context) }
        }
    }

    private func delete(_ meeting: Meeting) {
        if selection?.persistentModelID == meeting.persistentModelID { selection = nil }
        MeetingStore.delete(meeting, context: context)
    }

    private func delete(at offsets: IndexSet, in list: [Meeting]) {
        for index in offsets { delete(list[index]) }
    }
}
