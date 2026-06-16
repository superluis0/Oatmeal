import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var coordinator: RecordingCoordinator
    var detector: MeetingDetector
    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \Folder.createdAt) private var folders: [Folder]
    @State private var selection: Meeting?
    @State private var searchText = ""
    /// Debounced mirror of `searchText` that actually drives filtering, so we don't
    /// scan every meeting's transcript on each keystroke. Empty queries apply
    /// immediately (instant clear); non-empty ones settle after a short pause.
    @State private var debouncedSearch = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var showGlobalChat = false
    @State private var showPeople = false
    @State private var showTasks = false
    @State private var showUpcoming = false
    @State private var showDigest = false
    @State private var showDecisions = false
    @State private var showPalette = false
    @State private var pendingChatPrompt: String?
    @State private var pendingDelete: Meeting?
    @State private var deleteTask: Task<Void, Never>?
    @State private var justRecordedID: UUID?
    @State private var crashNotice: String?
    /// Monotonic counter that fires the meeting-saved celebration once per bump.
    @State private var celebrationTick = 0
    /// The milestone card to show (with confetti) at meeting-count milestones.
    @State private var milestone: MilestoneMessage?

    private func resetDestinations() {
        showGlobalChat = false; showPeople = false; showTasks = false
        showUpcoming = false; showDigest = false; showDecisions = false
    }

    /// Open the global "Ask Oatmeal" chat with a question prefilled and auto-sent.
    private func ask(_ prompt: String) {
        resetDestinations()
        pendingChatPrompt = prompt
        showGlobalChat = true
    }
    @State private var searchMode: SearchMode = .keyword

    enum SearchMode: Hashable { case keyword, semantic }

    private var showDetectionBanner: Bool {
        detector.suggestionActive && !coordinator.isRecording && !coordinator.isBusy
    }

    /// Meetings minus any pending (soft) delete awaiting undo.
    private var visibleMeetings: [Meeting] {
        guard let pending = pendingDelete else { return meetings }
        return meetings.filter { $0.id != pending.id }
    }

    private var filteredMeetings: [Meeting] {
        let meetings = visibleMeetings
        let q = debouncedSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings }
        if searchMode == .semantic && SemanticIndex.isAvailable {
            let index = SemanticIndex(context: context)
            index.ensureIndexed(meetings)
            let ranked = index.search(debouncedSearch)
            var rank: [UUID: Int] = [:]
            for (i, id) in ranked.enumerated() { rank[id] = i }
            return meetings
                .filter { rank[$0.id] != nil }
                .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        }
        return meetings.filter { m in
            m.title.lowercased().contains(q)
            || m.notes.lowercased().contains(q)
            || m.enhancedNotes.lowercased().contains(q)
            || m.tags.contains { $0.lowercased().contains(q) }
            || m.transcriptText.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            MeetingListView(
                meetings: filteredMeetings,
                folders: folders,
                selection: $selection,
                coordinator: coordinator,
                onAskOatmeal: { pendingChatPrompt = nil; resetDestinations(); showGlobalChat = true },
                onPeople: { resetDestinations(); showPeople = true },
                onTasks: { resetDestinations(); showTasks = true },
                onUpcoming: { resetDestinations(); showUpcoming = true },
                onDigest: { resetDestinations(); showDigest = true },
                onDecisions: { resetDestinations(); showDecisions = true },
                onDelete: requestDelete
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
            .onChange(of: searchText) { _, newValue in
                searchDebounce?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                // Clearing applies instantly; a real query settles briefly so each
                // keystroke doesn't trigger a fresh scan of every transcript.
                if trimmed.isEmpty { debouncedSearch = ""; return }
                searchDebounce = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard !Task.isCancelled else { return }
                    debouncedSearch = newValue
                }
            }
            .searchScopes($searchMode) {
                Text("Keyword").tag(SearchMode.keyword)
                Text("Semantic").tag(SearchMode.semantic)
            }
        } detail: {
            if coordinator.isRecording || coordinator.isBusy {
                RecordingView(coordinator: coordinator)
            } else if showGlobalChat {
                GlobalChatView(
                    onOpenMeeting: { selection = $0; showGlobalChat = false },
                    initialQuestion: pendingChatPrompt
                )
                .id(pendingChatPrompt)
            } else if showPeople {
                PeopleView(
                    onOpenMeeting: { selection = $0; showPeople = false },
                    onAsk: { ask($0) }
                )
            } else if showTasks {
                TasksView(onOpenMeeting: { selection = $0; showTasks = false })
            } else if showUpcoming {
                UpcomingView(coordinator: coordinator, onOpenMeeting: { selection = $0; showUpcoming = false })
            } else if showDigest {
                DigestView(onOpenMeeting: { selection = $0; showDigest = false })
            } else if showDecisions {
                DecisionsView(onOpenMeeting: { selection = $0; showDecisions = false })
            } else if let meeting = selection, meeting.modelContext != nil {
                // Pass only the stable id (always safe to read, even on a deleted
                // object); the container resolves the live meeting from @Query.
                MeetingDetailContainer(
                    meetingID: meeting.persistentModelID,
                    coordinator: coordinator,
                    justRecordedID: justRecordedID,
                    onConsumedAutoWrapUp: { justRecordedID = nil },
                    onDelete: { requestDelete($0) },
                    onOpenMeeting: { selection = $0 })
            } else {
                OatEmptyState(
                    icon: "waveform",
                    title: "Nothing selected yet",
                    message: "Start a new recording, import audio, or pick a past meeting. Press ⌘K to search or run any command."
                )
                .background(Theme.bg)
            }
        }
        .tint(Theme.accent)
        .fontDesign(Appearance.shared.fontDesign)
        .dynamicTypeSize(Appearance.shared.dynamicTypeSize)
        .groupBoxStyle(OatGroupBoxStyle())
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { if case .error = coordinator.phase { return true } else { return false } },
                set: { _ in coordinator.dismissError() }
            )
        ) {
            Button("OK", role: .cancel) { coordinator.dismissError() }
        } message: {
            if case .error(let msg) = coordinator.phase {
                Text(msg)
            }
        }
        .alert("Screen Recording is off", isPresented: $coordinator.pendingScreenRecordingDecision) {
            Button("Open Settings") { coordinator.openScreenRecordingSettings() }
            Button("Record mic only") { Task { await coordinator.startMicOnlyAfterPrompt(context: context) } }
            Button("Cancel", role: .cancel) { coordinator.pendingScreenRecordingDecision = false }
        } message: {
            Text("Oatmeal captures the other participants through Screen Recording, which is currently off (or needs a quit + relaunch to take effect). Without it, only your microphone is recorded. Open Settings to fix it, or record just your mic.")
        }
        .onChange(of: coordinator.phase) { oldValue, newValue in
            // Only treat as "just recorded" when the PREVIOUS phase was an active
            // capture (recording/processing) — so a cancelled prepare, or opening an
            // old meeting, never triggers the wrap-up.
            let wasMidCapture: Bool
            switch oldValue {
            case .recording, .processing: wasMidCapture = true
            default: wasMidCapture = false
            }
            if newValue == .idle, let last = meetings.first {
                if wasMidCapture {
                    justRecordedID = last.id
                    // Confetti is reserved for meeting-count milestones (every-save
                    // confetti gets old). Fire once per milestone ever — a stored
                    // marker stops deleting + re-recording from replaying it, and stops
                    // existing users getting a retroactive blast on update. (Discards/
                    // errors don't land here — they go to .error, not .idle.)
                    let n = meetings.count
                    if Milestone.counts.contains(n), n > AppSettings.lastCelebratedMilestone,
                       let message = Milestone.message(for: n) {
                        AppSettings.lastCelebratedMilestone = n
                        celebrationTick += 1
                        milestone = message
                    }
                }
                selection = last
            }
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            if recording {
                if AppSettings.floatingPanelAuto {
                    LiveHUDController.shared.show(coordinator: coordinator, context: context)
                }
            } else {
                LiveHUDController.shared.hide()
            }
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil { resetDestinations() }
        }
        // Drop the selected meeting the instant it's deleted out from under us —
        // by any path — so the detail view can't read a dead SwiftData object
        // during a later layout pass (which traps inside SwiftData).
        .onChange(of: coordinator.lastDiscardedMeetingID) { _, id in
            if let id, selection?.persistentModelID == id { selection = nil }
        }
        .onChange(of: meetings.map(\.persistentModelID)) { _, ids in
            if let sel = selection, !ids.contains(sel.persistentModelID) { selection = nil }
        }
        .safeAreaInset(edge: .top) {
            if showDetectionBanner {
                detectionBanner
            }
        }
        .onAppear {
            detector.startMonitoring()
            if crashNotice == nil, let crash = Log.lastCrashReport {
                crashNotice = crash
                Log.lastCrashReport = nil
            }
            UpdateChecker.shared.checkIfDue()
        }
        .onDisappear { detector.stopMonitoring() }
        .alert("Oatmeal quit unexpectedly last time", isPresented: Binding(
            get: { crashNotice != nil }, set: { if !$0 { crashNotice = nil } }
        )) {
            Button("Reveal Logs") {
                if let dir = Log.logDirectory {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("A crash report was saved to your local logs. Your meetings are safe — they're backed up automatically.")
        }
        .background(shortcutButtons)
        .overlay(alignment: .bottom) { if pendingDelete != nil { undoToast } }
        // A one-shot confetti burst (calm checkmark under reduce-motion) that floats
        // above the whole split view when a meeting is successfully saved.
        .celebration(trigger: celebrationTick)
        .overlay(alignment: .top) {
            if let milestone {
                MilestoneToast(title: milestone.title, message: milestone.body) { self.milestone = nil }
                    .padding(.top, 64)
            }
        }
        .sheet(isPresented: $showPalette) {
            CommandPaletteView(
                meetings: visibleMeetings,
                selectedMeeting: selection,
                isRecording: coordinator.isRecording,
                onSelectMeeting: { selection = $0 },
                onNewRecording: { Task { await coordinator.start(context: context) } },
                onToggleRecording: { toggleRecording() },
                onImportAudio: { importAudio() },
                onExportAll: { MarkdownExporter.exportVault(visibleMeetings) },
                onDeleteMeeting: { requestDelete($0) },
                onAskOatmeal: { pendingChatPrompt = nil; resetDestinations(); showGlobalChat = true },
                onPeople: { resetDestinations(); showPeople = true },
                onTasks: { resetDestinations(); showTasks = true },
                onUpcoming: { resetDestinations(); showUpcoming = true },
                onDigest: { resetDestinations(); showDigest = true },
                onDecisions: { resetDestinations(); showDecisions = true }
            )
        }
    }

    /// Hidden buttons that register app-wide keyboard shortcuts (all modified, so
    /// they never interfere with typing in notes/title fields).
    private var shortcutButtons: some View {
        Group {
            Button("") { showPalette = true }.keyboardShortcut("k", modifiers: .command)
            Button("") { toggleRecording() }.keyboardShortcut("r", modifiers: .command)
            Button("") { Task { await coordinator.start(context: context) } }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { resetDestinations(); showUpcoming = true }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("") { resetDestinations(); showTasks = true }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { resetDestinations(); showPeople = true }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { resetDestinations(); showDigest = true }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { resetDestinations(); showGlobalChat = true }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("") { importAudio() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var undoToast: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "trash").foregroundStyle(Theme.textSecondary)
            Text("Meeting deleted").foregroundStyle(Theme.textPrimary)
            Button("Undo") { undoDelete() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(.system(.subheadline))
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.bottom, Theme.Space.lg)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Actions

    private func toggleRecording() {
        Task {
            if coordinator.isRecording {
                await coordinator.stop(context: context)
            } else {
                await coordinator.start(context: context)
            }
        }
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

    /// Soft-delete with a 5-second undo window before it's committed.
    private func requestDelete(_ meeting: Meeting) {
        Log.info("delete requested: \(meeting.title)", "store")
        if selection?.id == meeting.id { selection = nil }
        deleteTask?.cancel()
        // If another meeting is still waiting out its undo window, commit it now
        // rather than letting the cancel-and-overwrite below drop it — otherwise
        // the first meeting silently reappears (it was never actually deleted).
        if let prior = pendingDelete, prior.id != meeting.id, prior.isAlive {
            MeetingStore.delete(prior, context: context)
        }
        withAnimation { pendingDelete = meeting }
        deleteTask = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return } // cancelled (undo)
            await MainActor.run {
                if let m = pendingDelete {
                    Log.info("delete committed", "store")
                    MeetingStore.delete(m, context: context)
                    withAnimation { pendingDelete = nil }
                }
            }
        }
    }

    private func undoDelete() {
        deleteTask?.cancel()
        withAnimation { pendingDelete = nil }
    }

    private var detectionBanner: some View {
        HStack(spacing: Theme.Space.sm) {
            IconBadge(systemName: "video.fill", size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Meeting in progress").font(.system(.subheadline).weight(.semibold))
                if let title = detector.suggestedTitle {
                    Text(title).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Button("Start Recording") {
                detector.dismissSuggestion()
                Task { await coordinator.start(context: context) }
            }
            .buttonStyle(OatPrimaryButton())
            Button("Dismiss") { detector.dismissSuggestion() }
                .buttonStyle(OatGhostButton())
        }
        .padding(Theme.Space.sm)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
