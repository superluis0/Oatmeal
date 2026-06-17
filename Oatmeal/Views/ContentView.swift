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
    /// Mirrors Sparkle's update state so the floating update banner appears the
    /// moment a new version is found.
    @State private var updateChecker = UpdateChecker.shared
    /// Per-session dismissal of the update banner ("Later"). Resets next launch, so
    /// a pending update gently re-surfaces; the sidebar pill is the always-on reminder.
    @State private var updateBannerDismissed = false
    /// Surfaces a restart prompt when the persistent store fails at the SQLite level
    /// mid-session — better than limping on toward a fault-fulfillment trap.
    @State private var storeHealth = StoreHealth.shared
    /// "What's new" card shown once after an update (first launch on a new version).
    @State private var whatsNew: WhatsNewInfo?

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
                    onOpenMeeting: { selection = $0 },
                    momentQuery: searchMode == .semantic ? debouncedSearch : "")
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
            showWhatsNewIfUpdated()
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
        .alert("Oatmeal needs a restart", isPresented: Binding(
            get: { storeHealth.degraded }, set: { if !$0 { storeHealth.degraded = false } }
        )) {
            Button("Quit Oatmeal") { NSApp.terminate(nil) }
            Button("Later", role: .cancel) { storeHealth.degraded = false }
        } message: {
            Text("Oatmeal had trouble saving to its database. Quit and reopen to recover your meetings from the latest backup — your data is safe.")
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
        // A prominent, friendly notice that floats above the whole window when a
        // new version is ready — the in-app counterpart to Sparkle's (now
        // suppressed) modal. "Update Now" hands off to Sparkle's install flow.
        .overlay(alignment: .top) {
            if let release = updateChecker.available, !updateBannerDismissed {
                UpdateBanner(
                    version: release.version,
                    onUpdate: { UpdateChecker.shared.checkForUpdates() },
                    onLater: { updateBannerDismissed = true }
                )
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
                .zIndex(20)
            }
        }
        .sheet(item: $whatsNew) { info in
            WhatsNewSheet(currentVersion: info.version) { whatsNew = nil }
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

    /// On the first launch after the app's version changes, surface the "What's new"
    /// card once. Skips fresh installs — only fires on a genuine update from a known
    /// prior version.
    private func showWhatsNewIfUpdated() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let prior = AppSettings.lastSeenVersion
        if !v.isEmpty { AppSettings.lastSeenVersion = v }
        guard !prior.isEmpty, prior != v, AppSettings.hasOnboarded,
              WhatsNew.hasEntry(for: v) else { return }
        whatsNew = WhatsNewInfo(version: v)
    }

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
            // Clear any reference to `prior` (it may still be the selection, with an
            // open detail/triage sheet bound to it) BEFORE invalidating it, and defer
            // the delete to the next main-actor turn so the selection-clear render
            // lands first — otherwise a mid-layout read of the just-deleted meeting
            // can trap.
            if selection?.id == prior.id { selection = nil }
            Task { @MainActor in
                if prior.isAlive { MeetingStore.delete(prior, context: context) }
            }
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

/// The floating "Update available" banner shown at the top of the main window when
/// Sparkle finds a newer release. Cozy and accent-tinted, gently animated in
/// (respecting Reduce Motion). "Update Now" hands off to Sparkle's signed,
/// one-click install flow via `checkForUpdates()`.
private struct UpdateBanner: View {
    let version: String
    var onUpdate: () -> Void
    var onLater: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 40, height: 40)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available")
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Oatmeal \(version) is ready — installs in a tap.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.md)
            Button("Later", action: onLater)
                .buttonStyle(OatGhostButton())
            Button(action: onUpdate) {
                Label("Update Now", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(OatPrimaryButton())
        }
        .padding(.vertical, Theme.Space.sm)
        .padding(.horizontal, Theme.Space.md)
        .frame(maxWidth: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Theme.accent.opacity(0.22), radius: 20, y: 8)
        .offset(y: (shown || reduceMotion) ? 0 : -90)
        .opacity((shown || reduceMotion) ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { shown = true }
        }
    }
}
