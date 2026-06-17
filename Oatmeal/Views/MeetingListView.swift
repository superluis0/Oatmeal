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
    /// Owned by ContentView so every delete goes through the same soft-delete
    /// (5-second undo window, logging, selection clearing). Deleting + saving
    /// directly from here invalidates the model while the detail pane may still
    /// be rendering it — the cause of a SwiftData deleted-object crash.
    var onDelete: (Meeting) -> Void
    @Environment(\.modelContext) private var context
    @State private var updateChecker = UpdateChecker.shared

    /// Open-task badge count, maintained by SwiftData rather than recomputed by
    /// reducing over every meeting's action items on each render (which fired on
    /// every audio frame during recording). Matches the Tasks view's notion of
    /// "open" (not done) and mirrors its `@Query`-then-count approach.
    @Query(filter: #Predicate<ActionItem> { !$0.isDone }) private var openActionItems: [ActionItem]

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folderTarget: Meeting?
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    /// Folders the user has collapsed (default: expanded). Per-session.
    @State private var collapsedFolders: Set<PersistentIdentifier> = []
    @State private var unfiledExpanded = true
    /// The folder currently hovered during a drag, for the drop highlight.
    @State private var dropTargetFolder: PersistentIdentifier?
    @State private var unfiledIsTarget = false

    /// Same key AppSettings.inPersonMode reads — @AppStorage keeps this control
    /// and the Settings-window toggle in sync live.
    @AppStorage("inPersonMode") private var inPersonMode = false

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            VStack(spacing: Theme.Space.xs) {
                recordButton
                meetingModePicker
                HStack(spacing: Theme.Space.xs) {
                    SidebarChip(title: "Upcoming", systemImage: "calendar", action: onUpcoming)
                    SidebarChip(title: "Ask", systemImage: "sparkles", action: onAskOatmeal)
                    SidebarChip(title: "Tasks", systemImage: "checklist", badge: openActionItems.count, action: onTasks)
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
                    // Show every folder (even empty ones) as a collapsible, drop-target
                    // section so meetings can be dragged into a freshly-made folder.
                    ForEach(folders) { folder in
                        let items = meetings.filter { $0.folder?.persistentModelID == folder.persistentModelID }
                        Section(isExpanded: expandBinding(folder.persistentModelID)) {
                            if items.isEmpty {
                                Text("Drag meetings here")
                                    .font(.system(size: Appearance.shared.scaled(11)))
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                ForEach(items) { row($0) }
                            }
                        } header: {
                            folderHeader(folder, count: items.count)
                        }
                    }
                    let unfiled = meetings.filter { $0.folder == nil }
                    if !unfiled.isEmpty {
                        Section(isExpanded: $unfiledExpanded) {
                            ForEach(unfiled) { row($0) }
                        } header: {
                            unfiledHeader(count: unfiled.count)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                // A warm first-run nudge instead of a blank list.
                if meetings.isEmpty && !coordinator.isRecording && !coordinator.isBusy {
                    OatEmptyState(
                        icon: "waveform",
                        title: "No meetings yet",
                        message: "Press ⌘R or tap New Recording above to capture your first."
                    )
                    .padding()
                    .allowsHitTesting(false)
                }
            }

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
                    folderTarget = nil
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("Create a folder to group meetings")
            }
            ToolbarItem {
                Button {
                    MarkdownExporter.exportVault(meetings)
                } label: {
                    Label("Export All", systemImage: "square.and.arrow.up")
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
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("Folder name", text: $renameText)
            Button("Save") { renameFolder() }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        let isSelected = selection?.persistentModelID == meeting.persistentModelID
        // A plain, tagged row — deliberately NOT a NavigationLink. The detail pane
        // is driven entirely by `selection` (ContentView has no
        // navigationDestination for Meeting), so wrapping the row in a
        // NavigationLink added a second, competing selection mechanism: the link
        // captured the click for a navigation that goes nowhere while
        // `List(selection:)` updated a beat later — which is why the first click on
        // a meeting often left the detail blank until you clicked away and back.
        // `.tag` + `List(selection:)` is the single, reliable source of selection.
        return VStack(alignment: .leading, spacing: 3) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(meeting)
        // `.draggable` (not `.onDrag`) so single-click selection still opens the row —
        // `.onDrag` swallows the click inside a List(selection:) on macOS.
        .draggable(meeting.id.uuidString)
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
            if let update = updateChecker.available {
                Button {
                    UpdateChecker.shared.checkForUpdates()
                } label: {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .updatePulse()
                .help("Oatmeal \(update.version) is available — click to install")
            }
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
                HStack(spacing: Theme.Space.xs) {
                    RecordOrb(level: coordinator.audioLevel,
                              isActive: true,
                              size: 12)
                    Label("Stop Recording", systemImage: "stop.fill")
                }
                .frame(maxWidth: .infinity)
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

    /// Online call vs in-person meeting. Front and center because it changes how
    /// speakers are identified: in person, everyone shares the Mac's mic, so the
    /// mic audio is diarized into multiple speakers instead of all being "Me".
    /// Editable during a recording too — it's applied when the transcript is
    /// finalized at stop, so a forgotten switch can still be fixed mid-meeting.
    private var meetingModePicker: some View {
        Picker("Meeting type", selection: $inPersonMode) {
            Label("Online call", systemImage: "video").tag(false)
            Label("In person", systemImage: "person.2").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help(inPersonMode
              ? "In person: everyone shares this Mac's mic, so it's split into separate speakers."
              : "Online call: your mic is you; the other side comes in through system audio.")
    }

    // MARK: - Actions

    private func assign(_ meeting: Meeting, to folder: Folder?) {
        meeting.folder = folder
        // Reveal where it landed if that folder was collapsed.
        if let folder { collapsedFolders.remove(folder.persistentModelID) }
        SafeStore.save(context, "folder-assign")
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
        SafeStore.save(context, "folder-create")
    }

    private func renameFolder() {
        guard let folder = renamingFolder else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renamingFolder = nil
        guard !name.isEmpty else { return }
        folder.name = name
        SafeStore.save(context, "folder-rename")
    }

    /// Deletes the folder only — its meetings keep their data and fall back to
    /// "Unfiled" (the `Meeting.folder` relationship is `.nullify`).
    private func deleteFolder(_ folder: Folder) {
        context.delete(folder)
        SafeStore.save(context, "folder-delete")
    }

    // MARK: - Folder UI helpers

    private func expandBinding(_ id: PersistentIdentifier) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(id) },
            set: { isOpen in
                if isOpen { collapsedFolders.remove(id) } else { collapsedFolders.insert(id) }
            }
        )
    }

    @ViewBuilder
    private func folderHeader(_ folder: Folder, count: Int) -> some View {
        HStack(spacing: 6) {
            SectionLabel(text: folder.name)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: Appearance.shared.scaled(10), weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(dropTargetFolder == folder.persistentModelID ? Theme.accentSoft : Color.clear)
        )
        .dropDestination(for: String.self) { ids, _ in
            handleDropIDs(ids, to: folder)
        } isTargeted: { hovering in
            dropTargetFolder = hovering ? folder.persistentModelID : nil
        }
        .contextMenu {
            Button("Rename\u{2026}") { renameText = folder.name; renamingFolder = folder }
            Button("Delete Folder", role: .destructive) { deleteFolder(folder) }
        }
    }

    @ViewBuilder
    private func unfiledHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Unfiled")
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(unfiledIsTarget ? Theme.accentSoft : Color.clear)
        )
        .dropDestination(for: String.self) { ids, _ in
            handleDropIDs(ids, to: nil)
        } isTargeted: { hovering in
            unfiledIsTarget = hovering
        }
    }

    /// (Re)assign the dropped meeting id(s) to `folder` (nil = Unfiled). `.draggable`
    /// delivers the ids directly, so no async NSItemProvider loading is needed.
    private func handleDropIDs(_ ids: [String], to folder: Folder?) -> Bool {
        var assigned = false
        for raw in ids {
            guard let uuid = UUID(uuidString: raw),
                  let meeting = meetings.first(where: { $0.id == uuid }) else { continue }
            assign(meeting, to: folder)
            assigned = true
        }
        return assigned
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
        onDelete(meeting)
    }

    private func delete(at offsets: IndexSet, in list: [Meeting]) {
        for index in offsets { delete(list[index]) }
    }
}
