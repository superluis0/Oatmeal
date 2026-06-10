import SwiftUI
import SwiftData
import AppKit

// MARK: - Live recording / processing view

struct RecordingView: View {
    @Bindable var coordinator: RecordingCoordinator
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if let warning = coordinator.captureWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).font(.caption)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 6)
                .background(.orange.opacity(0.12))
            }
            Divider()
            if coordinator.liveSegments.isEmpty {
                ContentUnavailableView {
                    Label(statusText, systemImage: "waveform.circle")
                } description: {
                    Text("Live transcript will appear here as people speak.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(coordinator.liveSegments) { seg in
                            SegmentRow(speaker: seg.speaker, text: seg.text, streaming: true)
                        }
                    }
                    .padding()
                }
            }
            if coordinator.isRecording {
                Divider()
                assistPane
                Divider()
                notesPane
            }
        }
        .navigationTitle(coordinator.activeMeeting?.title ?? "Recording")
    }

    @ViewBuilder
    private var assistPane: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                SectionLabel(text: "Live Assist")
                if coordinator.isSuggesting { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    Task { await coordinator.requestSuggestion() }
                } label: {
                    Label("Suggest now", systemImage: "lightbulb.fill")
                }
                .buttonStyle(OatSecondaryButton())
                .disabled(coordinator.isSuggesting)
            }
            if coordinator.liveSuggestions.isEmpty {
                Text(AppSettings.liveAssistEnabled
                     ? "Suggestions appear when you're asked a question — or tap Suggest now."
                     : "Turn on Live Assist in Settings for automatic suggestions. You can still tap Suggest now.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(Array(coordinator.liveSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                            LiveSuggestionCard(suggestion: suggestion,
                                               isLatest: index == 0,
                                               tick: Int(coordinator.elapsed))
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8),
                               value: coordinator.liveSuggestions.first?.id)
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.bgElevated)
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { coordinator.activeMeeting?.notes ?? "" },
            set: { coordinator.activeMeeting?.notes = $0 }
        )
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                SectionLabel(text: "Live Notes")
                Spacer()
                Button {
                    LiveHUDController.shared.toggle(coordinator: coordinator, context: context)
                } label: {
                    Label("Floating panel", systemImage: "pip.enter")
                }
                .buttonStyle(OatGhostButton())
                .help("Pop out a small always-on-top panel over your call")
                Button {
                    coordinator.markHighlight(context: context)
                } label: {
                    Label("Mark moment", systemImage: "bookmark.fill")
                }
                .buttonStyle(OatGhostButton())
                Button {
                    Task { await coordinator.enhanceLive(context: context) }
                } label: {
                    if coordinator.isEnhancingLive {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Enhance now", systemImage: "sparkles")
                    }
                }
                .buttonStyle(OatSecondaryButton())
                .disabled(coordinator.isEnhancingLive || coordinator.liveSegments.isEmpty)
            }
            TextEditor(text: notesBinding)
                .font(.system(.body))
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .frame(height: 72)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            if coordinator.isEnhancingLive {
                // Living skeleton while the live enhance runs (button keeps its spinner).
                SkeletonLines(lineWidths: [1.0, 0.9, 0.72])
                    .padding(.vertical, 4)
                    .frame(maxHeight: 150, alignment: .top)
                    .transition(.opacity)
            } else if !coordinator.liveEnhanced.isEmpty {
                ScrollView {
                    MarkdownView(markdown: coordinator.liveEnhanced).padding(.vertical, 4)
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.bgElevated)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: coordinator.isEnhancingLive)
    }

    private var statusText: String {
        switch coordinator.phase {
        case .preparingModels: return "Loading speech models…"
        case .recording: return "Listening…"
        case .processing(let m): return m
        default: return "Working…"
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            if coordinator.isRecording {
                PulsingDot()
                Text(timeString(coordinator.elapsed))
                    .font(.system(.title2).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
            } else {
                ProgressView().controlSize(.small)
            }
            Text(statusText)
                .font(.system(.subheadline))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if coordinator.isRecording {
                LiveWaveform(level: coordinator.audioLevel)
                    .frame(width: 120, height: 24)
            }
        }
        .padding(Theme.Space.md)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Saved meeting detail

/// Resolves the meeting for the detail pane from a LIVE `@Query`, keyed by the
/// always-safe `persistentModelID`. When the meeting is deleted by any path, the
/// query stops returning it and SwiftUI re-renders to the empty state *before* a
/// layout pass can read a dead SwiftData object — the root cause of the recurring
/// deleted-object traps. The detail view itself is only ever handed a live object.
struct MeetingDetailContainer: View {
    let meetingID: PersistentIdentifier
    var coordinator: RecordingCoordinator
    var justRecordedID: UUID?
    var onConsumedAutoWrapUp: () -> Void
    var onDelete: (Meeting) -> Void
    var onOpenMeeting: (Meeting) -> Void

    @Query private var allMeetings: [Meeting]

    var body: some View {
        if let meeting = allMeetings.first(where: { $0.persistentModelID == meetingID }) {
            MeetingDetailView(
                meeting: meeting,
                coordinator: coordinator,
                autoWrapUp: meeting.id == justRecordedID,
                onConsumedAutoWrapUp: onConsumedAutoWrapUp,
                onDelete: { onDelete(meeting) },
                onOpenMeeting: onOpenMeeting)
            .id(meetingID)
        } else {
            OatEmptyState(
                icon: "waveform",
                title: "Nothing selected yet",
                message: "Start a new recording, import audio, or pick a past meeting from the sidebar.")
        }
    }
}

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    var coordinator: RecordingCoordinator? = nil
    var autoWrapUp: Bool = false
    var onConsumedAutoWrapUp: () -> Void = {}
    var onDelete: () -> Void = {}
    var onOpenMeeting: (Meeting) -> Void = { _ in }
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]

    enum DetailTab: String, CaseIterable, Identifiable {
        case enhanced = "Enhanced"
        case notes = "Notes"
        case transcript = "Transcript"
        case chat = "Chat"
        case analytics = "Analytics"
        var id: String { rawValue }
    }

    @State private var tab: DetailTab = .enhanced
    /// Drives the sliding selection indicator in the custom segmented tab control.
    @Namespace private var tabIndicator
    @State private var isEnhancing = false
    @State private var enhanceError: String?
    @State private var editingTranscript = false
    @State private var newTag = ""
    @State private var showTemplateEditor = false
    @State private var showRecipes = false
    @State private var runningRecipe = false
    @State private var recipeResult: String?
    @State private var recipeIsEmail = false
    @State private var player = AudioPlayer()
    @State private var showDeleteConfirm = false
    @State private var jumpTarget: PersistentIdentifier?
    @State private var showFollowUpSheet = false
    @State private var followUpDate = Date().addingTimeInterval(7 * 86_400)
    @State private var followUpToast: String?
    @State private var reextracting = false
    @State private var reidentifySpeakerCount = 2
    @State private var reidentifying = false
    @State private var showTriage = false

    /// Sendable snapshot of segments for off-main source matching.
    private var segmentRefs: [SegmentRef] {
        meeting.orderedSegments.map {
            SegmentRef(id: $0.persistentModelID,
                       speaker: meeting.displayName(for: $0.speaker),
                       text: $0.text,
                       start: $0.start)
        }
    }

    /// ⌘1–5 switch between the detail tabs (modified, so typing is unaffected).
    private var tabShortcuts: some View {
        Group {
            Button("") { tab = .enhanced }.keyboardShortcut("1", modifiers: .command)
            Button("") { tab = .notes }.keyboardShortcut("2", modifiers: .command)
            Button("") { tab = .transcript }.keyboardShortcut("3", modifiers: .command)
            Button("") { tab = .chat }.keyboardShortcut("4", modifiers: .command)
            Button("") { tab = .analytics }.keyboardShortcut("5", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Jump from a note's source quote to that moment in transcript + audio.
    private func jump(to ref: SegmentRef) {
        tab = .transcript
        jumpTarget = ref.id
        if meeting.audioPath != nil && player.duration > 0 {
            player.seek(to: ref.start)
            player.play()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if jumpTarget == ref.id { jumpTarget = nil }
        }
    }

    var body: some View {
        // Defense in depth: if this meeting was deleted out from under the view,
        // render nothing rather than read a dead SwiftData object during a layout
        // pass (which traps). Pairs with the selection-clearing in ContentView.
        if meeting.modelContext == nil {
            Color.clear
        } else {
            content
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                titleSection
                summarySection
                recurringSection
                highlightsSection
                OatSegmentedTabs(selection: $tab,
                                 namespace: tabIndicator,
                                 reduceMotion: reduceMotion)
                tabContent
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .background(tabShortcuts)
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(RecipeProvider.all(context: context)) { r in
                        Button(r.name) { Task { await runRecipe(r) } }
                    }
                    Divider()
                    Button("Manage Recipes…") { showRecipes = true }
                } label: {
                    Label("Recipes", systemImage: "wand.and.stars.inverse")
                }
                .disabled(meeting.segments.isEmpty || runningRecipe)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Copy as Markdown") { MarkdownExporter.copyToPasteboard(meeting) }
                    Button("Export Markdown…") { MarkdownExporter.exportToFile(meeting) }
                    Button("Export PDF…") { MarkdownExporter.exportPDF(meeting) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showTriage = true } label: {
                    Label("Wrap up", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(meeting.segments.isEmpty)
                .help("Review the summary, confirm tasks, and send the recap")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        if let recipe = RecipeProvider.builtins.first(where: { $0.isEmail }) {
                            Task { await runRecipe(recipe) }
                        }
                    } label: { Label("Email recap to attendees", systemImage: "envelope") }
                    Button { showFollowUpSheet = true } label: {
                        Label("Schedule follow-up…", systemImage: "calendar.badge.plus")
                    }
                    Divider()
                    Button {
                        Task { await reextractActions() }
                    } label: { Label("Re-extract action items", systemImage: "arrow.triangle.2.circlepath") }
                    if coordinator != nil {
                        Button {
                            Task { await coordinator?.regenerateSummary(for: meeting, context: context) }
                        } label: { Label("Regenerate summary", systemImage: "sparkles") }
                    }
                } label: {
                    Label("Follow up", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(meeting.segments.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showFollowUpSheet) { followUpSheet }
        .sheet(isPresented: $showTriage) {
            MeetingTriageView(meeting: meeting) {
                showTriage = false
                if let recipe = RecipeProvider.builtins.first(where: { $0.isEmail }) {
                    Task { await runRecipe(recipe) }
                }
            }
        }
        .onAppear {
            if autoWrapUp {
                showTriage = true
                onConsumedAutoWrapUp()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = followUpToast {
                Text(toast)
                    .font(.system(.callout).weight(.medium))
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Theme.Space.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Meeting", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the transcript, notes, summary, chat, and audio. This can't be undone.")
        }
        .overlay {
            if runningRecipe {
                ProgressView("Running recipe…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .sheet(isPresented: $showRecipes) { RecipesView() }
        .sheet(isPresented: Binding(
            get: { recipeResult != nil },
            set: { if !$0 { recipeResult = nil } }
        )) {
            RecipeResultView(
                text: recipeResult ?? "",
                isEmail: recipeIsEmail,
                recipientEmails: meeting.liveAttendees.compactMap(\.email),
                onInsert: { insertIntoNotes(recipeResult ?? "") }
            )
        }
        .alert("Couldn't enhance notes", isPresented: Binding(
            get: { enhanceError != nil },
            set: { if !$0 { enhanceError = nil } }
        )) {
            Button("OK", role: .cancel) { enhanceError = nil }
        } message: {
            Text(enhanceError ?? "")
        }
        .sheet(isPresented: $showTemplateEditor) {
            TemplateEditorView()
        }
        .onAppear { loadAudioIfNeeded() }
        .onChange(of: meeting.audioPath) { _, _ in loadAudioIfNeeded() }
        .onChange(of: jumpTarget) { _, target in
            guard let target else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
        } // ScrollViewReader
    }

    /// The active tab's content, cross-faded when `tab` changes. Each heavy tab
    /// (Chat, Analytics, transcript) keeps a stable `.id` so its internal state
    /// isn't torn down/rebuilt by the transition — only the opacity is animated.
    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            switch tab {
            case .enhanced: enhancedSection
            case .notes: notesSection
            case .transcript: transcriptSection
            case .chat: MeetingChatView(meeting: meeting)
            case .analytics: AnalyticsView(meeting: meeting)
            }
        }
        .id(tab)
        .transition(reduceMotion ? .identity : .opacity)
        .animation(Motion.reveal(reduceMotion), value: tab)
    }

    private func loadAudioIfNeeded() {
        if let path = meeting.audioPath, FileManager.default.fileExists(atPath: path) {
            player.load(path: path)
        }
    }

    private var followUpSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Schedule follow-up").font(.system(.title3).weight(.semibold))
            DatePicker("When", selection: $followUpDate)
                .datePickerStyle(.graphical)
            HStack {
                Spacer()
                Button("Cancel") { showFollowUpSheet = false }
                    .buttonStyle(OatSecondaryButton())
                Button("Create Event") {
                    let ok = CalendarService().createFollowUp(
                        title: meeting.title,
                        date: followUpDate,
                        notes: meeting.liveSummary?.text ?? meeting.enhancedNotes
                    )
                    showFollowUpSheet = false
                    showToast(ok ? "Follow-up added to your calendar" : "Couldn't create event (check Calendar access)")
                }
                .buttonStyle(OatPrimaryButton())
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 380)
    }

    private func reextractActions() async {
        reextracting = true
        defer { reextracting = false }
        let notes = meeting.enhancedNotes.isEmpty ? meeting.notes : meeting.enhancedNotes
        let extracted = await ActionItemExtractor().extract(transcript: meeting.transcriptText, notes: notes)
        let existing = Set(meeting.liveActionItems.map { $0.text.lowercased() })
        var added = 0
        for action in extracted where !existing.contains(action.text.lowercased()) {
            let item = ActionItem(text: action.text, dueDate: action.dueDate, owner: action.owner)
            context.insert(item)
            item.meeting = meeting
            added += 1
        }
        try? context.save()
        showToast(added > 0 ? "Added \(added) action item\(added == 1 ? "" : "s")" : "No new action items found")
    }

    private func showToast(_ message: String) {
        withAnimation { followUpToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation { if followUpToast == message { followUpToast = nil } }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            TextField("Title", text: $meeting.title)
                .textFieldStyle(.plain)
                .font(.system(size: Appearance.shared.scaled(32), weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit { try? context.save() }
            HStack(spacing: 8) {
                Text(meeting.date, format: .dateTime.month().day().year().hour().minute())
                if meeting.duration > 0 {
                    Text("·")
                    Text(meeting.durationLabel)
                }
            }
            .font(.system(.subheadline))
            .foregroundStyle(.secondary)
            if !meeting.liveAttendees.isEmpty {
                Label(meeting.attendeeNames.joined(separator: ", "),
                      systemImage: "person.2")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            tagEditor
        }
    }

    private var tagEditor: some View {
        HStack(spacing: 6) {
            ForEach(meeting.tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text("#\(tag)")
                    Button {
                        meeting.tags.removeAll { $0 == tag }
                        try? context.save()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(maxWidth: 100)
                .onSubmit { addTag() }
        }
        .padding(.top, 2)
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        newTag = ""
        guard !tag.isEmpty, !meeting.tags.contains(tag) else { return }
        meeting.tags.append(tag)
        try? context.save()
    }

    @ViewBuilder
    private var summarySection: some View {
        // Guard against a model that was deleted out from under the view (e.g. the
        // meeting was removed while a sheet was closing) — reading a deleted
        // SwiftData object's properties traps. modelContext is nil once deleted.
        if meeting.modelContext != nil, let summary = meeting.summary, summary.modelContext != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if !summary.text.isEmpty {
                        MarkdownView(markdown: summary.text)
                    }
                    if !summary.keyPoints.isEmpty {
                        bulletList(title: "Key Points", items: summary.keyPoints)
                    }
                    if !meeting.liveActionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Action Items").font(.headline)
                            ForEach(Array(meeting.liveActionItems.sorted { !$0.isDone && $1.isDone }.enumerated()), id: \.element.persistentModelID) { idx, item in
                                ActionItemRow(item: item)
                                    .staggeredReveal(index: idx, reduceMotion: reduceMotion, rise: false)
                            }
                        }
                    } else if !summary.actionItems.isEmpty {
                        bulletList(title: "Action Items", items: summary.actionItems)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } label: {
                Label("Summary", systemImage: "sparkles")
            }
        }
    }

    private func seriesMatches(_ other: Meeting) -> Bool {
        if let a = meeting.calendarEventID, let b = other.calendarEventID, !a.isEmpty, a == b { return true }
        return other.title.caseInsensitiveCompare(meeting.title) == .orderedSame
    }

    private var previousOccurrences: [Meeting] {
        allMeetings
            .filter { $0.id != meeting.id && $0.date < meeting.date && seriesMatches($0) }
            .sorted { $0.date > $1.date }
    }

    @ViewBuilder
    private var recurringSection: some View {
        let prior = previousOccurrences
        if !prior.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(prior.prefix(5)) { m in
                        Button { onOpenMeeting(m) } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
                                Text(m.date, format: .dateTime.month().day().year())
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        Task { await catchMeUp(prior: prior) }
                    } label: {
                        if runningRecipe {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Catch me up on this series", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(OatSecondaryButton())
                    .disabled(runningRecipe)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } label: {
                Label("Recurring · \(prior.count) previous", systemImage: "repeat")
            }
        }
    }

    private func catchMeUp(prior: [Meeting]) async {
        runningRecipe = true
        defer { runningRecipe = false }
        let series = ([meeting] + prior).sorted { $0.date > $1.date }
        let inputs = series.prefix(8).map { m in
            DigestInput(
                id: String(m.id.uuidString.prefix(4)).lowercased(),
                title: m.title,
                date: m.date.formatted(date: .abbreviated, time: .shortened),
                notes: m.enhancedNotes.isEmpty ? (m.liveSummary?.text ?? m.notes) : m.enhancedNotes,
                transcript: m.transcriptText
            )
        }
        if let result = try? await DigestService().digest(Array(inputs), scopeLabel: "the \(meeting.title) series") {
            recipeIsEmail = false
            recipeResult = result
        }
    }

    @ViewBuilder
    private var highlightsSection: some View {
        if !meeting.highlights.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(meeting.orderedHighlights) { highlight in
                        Button {
                            if meeting.audioPath != nil {
                                player.seek(to: highlight.time)
                                player.play()
                            }
                        } label: {
                            HStack(spacing: Theme.Space.sm) {
                                Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent)
                                Text(timeString(highlight.time))
                                    .font(.system(.body).monospacedDigit())
                                if let note = highlight.note, !note.isEmpty {
                                    Text(note).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } label: {
                Label("Highlights", systemImage: "bookmark")
            }
        }
    }

    private func bulletList(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(inlineMarkdown(stripBullet(item)))
                }
                .staggeredReveal(index: idx, reduceMotion: reduceMotion, rise: false)
            }
        }
    }

    private func stripBullet(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "• "] where t.hasPrefix(prefix) {
            t.removeFirst(prefix.count)
        }
        return t
    }

    private func inlineMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: { meeting.templateName ?? AppSettings.defaultTemplate },
            set: { meeting.templateName = $0; try? context.save() }
        )
    }

    private var enhancedSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Template", selection: templateBinding) {
                        ForEach(TemplateProvider.all(context: context)) { Text($0.name).tag($0.name) }
                    }
                    .frame(maxWidth: 200)
                    Button {
                        showTemplateEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("Manage templates")
                    Spacer()
                    Button {
                        Task { await enhance() }
                    } label: {
                        if isEnhancing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Enhance", systemImage: "sparkles")
                        }
                    }
                    .disabled(isEnhancing || meeting.segments.isEmpty)
                }
                Divider()
                if isEnhancing {
                    // While generation runs, show a living skeleton of the notes
                    // area so the wait feels alive (the button keeps its spinner).
                    enhancingSkeleton
                        .transition(.opacity)
                } else if meeting.noteBlocks.isEmpty && meeting.enhancedNotes.isEmpty {
                    Text(meeting.segments.isEmpty
                         ? "No transcript yet — record a meeting to enhance notes."
                         : "No enhanced notes yet. Tap Enhance to generate them from your notes and the transcript.")
                        .foregroundStyle(.secondary)
                } else if !meeting.noteBlocks.isEmpty {
                    ProvenanceNotesView(blocks: meeting.noteBlocks, segments: segmentRefs, onJump: { jump(to: $0) })
                    provenanceLegend
                } else {
                    MarkdownView(markdown: meeting.enhancedNotes)
                        .appearReveal(reduceMotion: reduceMotion, rise: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .animation(Motion.reveal(reduceMotion), value: isEnhancing)
        } label: {
            Label("Enhanced Notes", systemImage: "wand.and.stars")
        }
    }

    /// A shimmering skeleton of the notes area shown while `isEnhancing`. Lines
    /// only sweep while visible; the modifier drops the overlay once dismissed.
    private var enhancingSkeleton: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SkeletonLines(lineWidths: [1.0, 0.94, 0.88])
            SkeletonLines(lineWidths: [0.7, 0.96, 0.82, 0.6])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Enhancing notes…")
    }

    private var provenanceLegend: some View {
        HStack(spacing: 12) {
            Label("Your notes", systemImage: "circle.fill").foregroundStyle(.primary)
            Label("AI-added", systemImage: "circle.fill").foregroundStyle(.secondary)
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
        .padding(.top, 4)
    }

    private func runRecipe(_ recipe: RecipeItem) async {
        runningRecipe = true
        defer { runningRecipe = false }
        recipeIsEmail = recipe.isEmail
        let notes = meeting.enhancedNotes.isEmpty ? (meeting.liveSummary?.text ?? "") : meeting.enhancedNotes
        do {
            recipeResult = try await RecipeService().run(
                prompt: recipe.prompt,
                title: meeting.title,
                notes: notes,
                transcript: meeting.transcriptText
            )
        } catch {
            enhanceError = error.localizedDescription
        }
    }

    private func insertIntoNotes(_ text: String) {
        if !meeting.notes.isEmpty { meeting.notes += "\n\n" }
        meeting.notes += text
        try? context.save()
    }

    private func enhance() async {
        isEnhancing = true
        defer { isEnhancing = false }
        let template = TemplateProvider.resolve(name: meeting.templateName ?? AppSettings.defaultTemplate, context: context)
        meeting.templateName = template.name
        let identity = MeetingIdentity.preamble(knownSpeakers: meeting.speakerNames)
        let grounded = MeetingIdentity.ground(transcript: meeting.transcriptText, userName: AppSettings.userName)
        do {
            let result = try await NoteEnhancementService()
                .enhance(rawNotes: meeting.notes, transcript: grounded, template: template, identity: identity)
            meeting.enhancedNotes = result.markdown
            meeting.noteBlocks = result.blocks
            try? context.save()
            SemanticIndex(context: context).reindex(meeting)
        } catch {
            enhanceError = error.localizedDescription
        }
    }

    private var notesSection: some View {
        GroupBox {
            NotesEditor(text: $meeting.notes, minHeight: 180) { try? context.save() }
        } label: {
            Label("My Notes", systemImage: "square.and.pencil")
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if meeting.segments.isEmpty {
            Text("No transcript for this meeting.")
                .foregroundStyle(.secondary)
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if meeting.audioPath != nil && player.duration > 0 {
                            playerBar
                        }
                        Spacer()
                        Toggle(isOn: $editingTranscript) {
                            Label("Edit", systemImage: "pencil")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                    if editingTranscript {
                        speakerRenameEditor
                        Divider()
                    }
                    let ordered = meeting.orderedSegments
                    ForEach(Array(ordered.enumerated()), id: \.element.persistentModelID) { idx, seg in
                        let newTurn = idx == 0 || ordered[idx - 1].speaker != seg.speaker
                        transcriptRow(seg, showSpeaker: newTurn)
                            .id(seg.persistentModelID)
                            .padding(.top, newTurn ? 8 : 1)
                            .padding(.vertical, 1)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                    .fill(jumpTarget == seg.persistentModelID ? Theme.accentSoft : .clear)
                            )
                            // One-shot staggered fade-in when the transcript first
                            // appears. Pure opacity (no rise) so the reveal never
                            // fights the programmatic scrollTo / jumpTarget anchor;
                            // guarded internally so it fires once, not on scroll.
                            .appearReveal(
                                reduceMotion: reduceMotion,
                                delay: Reveal.staggerDelay(idx, reduceMotion: reduceMotion),
                                rise: false
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } label: {
                Label("Transcript", systemImage: "text.bubble")
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ seg: TranscriptSegment, showSpeaker: Bool) -> some View {
        if editingTranscript {
            editableRow(seg)
        } else if meeting.audioPath != nil && player.duration > 0 {
            Button {
                player.seek(to: seg.start)
                player.play()
            } label: {
                SegmentRow(speaker: meeting.displayName(for: seg.speaker), text: seg.text, showSpeaker: showSpeaker)
            }
            .buttonStyle(.plain)
        } else {
            SegmentRow(speaker: meeting.displayName(for: seg.speaker), text: seg.text, showSpeaker: showSpeaker)
        }
    }

    private var playerBar: some View {
        HStack(spacing: 8) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1)
            )
            .frame(maxWidth: 200)
            Text("\(timeString(player.currentTime)) / \(timeString(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var uniqueSpeakers: [String] {
        var seen: [String] = []
        for seg in meeting.orderedSegments where !seen.contains(seg.speaker) {
            seen.append(seg.speaker)
        }
        return seen
    }

    private var speakerRenameEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speaker identification").font(.caption.bold()).foregroundStyle(.secondary)
                    HStack {
                        Stepper("Expected speakers: \(reidentifySpeakerCount)",
                                value: $reidentifySpeakerCount, in: 1...12)
                            .fixedSize()
                        Spacer()
                        Button {
                            Task { await reidentify() }
                        } label: {
                            if reidentifying {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Re-identify", systemImage: "person.2.wave.2")
                            }
                        }
                        .buttonStyle(OatSecondaryButton())
                        .disabled(reidentifying || meeting.audioPath == nil)
                    }
                    Text(meeting.audioPath == nil
                         ? "No archived audio — re-identification isn't available for this meeting."
                         : "Re-runs diarization on this meeting's saved audio. Tip: wear headphones while recording so your voice doesn't bleed into the others.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Rename & merge speakers").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(uniqueSpeakers, id: \.self) { original in
                    HStack {
                        Text(original).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        TextField(original, text: speakerNameBinding(original))
                            .textFieldStyle(.roundedBorder)
                        if !meeting.liveAttendees.isEmpty {
                            Menu {
                                ForEach(meeting.liveAttendees) { a in
                                    Button(a.name) {
                                        meeting.speakerNames[original] = a.name
                                        try? context.save()
                                    }
                                }
                            } label: {
                                Image(systemName: "person.crop.circle.badge.plus")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Assign an attendee name")
                        }
                        let others = uniqueSpeakers.filter { $0 != original }
                        if !others.isEmpty {
                            Menu {
                                ForEach(others, id: \.self) { target in
                                    Button("Merge into \(meeting.displayName(for: target))") {
                                        mergeSpeaker(original, into: target)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.triangle.merge")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Merge this speaker's lines into another (fixes over-splitting)")
                        }
                    }
                }
            }
        }
    }

    private func reidentify() async {
        guard let coordinator else { return }
        reidentifying = true
        defer { reidentifying = false }
        await coordinator.reidentifySpeakers(
            for: meeting, expectedSpeakers: reidentifySpeakerCount, context: context)
    }

    /// Reassigns every segment of `from` to `target` and reindexes — making the
    /// merge structural (the transcript, summaries, and chat all see one speaker).
    private func mergeSpeaker(_ from: String, into target: String) {
        for seg in meeting.orderedSegments where seg.speaker == from { seg.speaker = target }
        meeting.speakerNames[from] = nil
        try? context.save()
        SemanticIndex(context: context).reindex(meeting)
    }

    private func speakerNameBinding(_ original: String) -> Binding<String> {
        Binding(
            get: { meeting.speakerNames[original] ?? original },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == original {
                    meeting.speakerNames[original] = nil
                } else {
                    meeting.speakerNames[original] = trimmed
                }
                try? context.save()
            }
        )
    }

    private func editableRow(_ seg: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.displayName(for: seg.speaker)).font(.caption.bold())
            TextField("Text", text: Binding(
                get: { seg.text },
                set: { seg.text = $0; try? context.save() }
            ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Custom segmented tab control

/// A warm, Theme-styled segmented control with a sliding selection indicator.
///
/// The highlight is a single rounded capsule that *morphs* between segments via
/// `matchedGeometryEffect` (keyed off the shared `namespace`), so switching tabs
/// — whether by click or by the ⌘1–5 shortcuts that mutate the same binding —
/// animates the pill smoothly to its new home. Each segment is a real `Button`
/// with a VoiceOver label and `.isSelected` trait, so the control stays fully
/// accessible.
///
/// Reduce-motion: the indicator jumps instantly (the animation resolves to
/// `nil`), matching the rest of the app's motion contract.
private struct OatSegmentedTabs: View {
    @Binding var selection: MeetingDetailView.DetailTab
    var namespace: Namespace.ID
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MeetingDetailView.DetailTab.allCases) { item in
                segment(item)
            }
        }
        .padding(3)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        // Drive the indicator morph from the binding so click *and* ⌘1–5 animate.
        .animation(Motion.gentle(reduceMotion), value: selection)
    }

    @ViewBuilder
    private func segment(_ item: MeetingDetailView.DetailTab) -> some View {
        let isSelected = selection == item
        Button {
            selection = item
        } label: {
            Text(item.rawValue)
                .font(.system(.callout).weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(Theme.accentGradient)
                            .matchedGeometryEffect(id: "tabIndicator", in: namespace)
                            .shadow(color: Theme.accent.opacity(0.30), radius: 5, y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Lightweight Markdown renderer

/// Renders headings, bullet lists, and inline emphasis. SwiftUI's built-in
/// Markdown only handles inline syntax, so we split block-level structure here.
struct MarkdownView: View {
    let markdown: String

    /// Explicit scale (macOS Dynamic Type doesn't reliably resize text).
    private var scale: CGFloat { Appearance.shared.fontScale }
    private var bodyFont: Font { .system(size: 13 * scale) }

    var body: some View {
        let blocks = Self.groupBlocks(Self.stripFence(Self.sanitizeLinks(markdown)).components(separatedBy: "\n"))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .line(let raw): lineView(raw)
                case .table(let header, let rows): tableView(header: header, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - Block grouping (so tables render as tables, not raw pipes)

    private enum Block { case line(String); case table(header: [String], rows: [[String]]) }

    private static func groupBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if isTableRow(trimmed), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let header = cells(trimmed)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, isTableRow(lines[j].trimmingCharacters(in: .whitespaces)) {
                    rows.append(cells(lines[j].trimmingCharacters(in: .whitespaces)))
                    j += 1
                }
                blocks.append(.table(header: header, rows: rows))
                i = j
            } else {
                blocks.append(.line(lines[i]))
                i += 1
            }
        }
        return blocks
    }

    private static func isTableRow(_ s: String) -> Bool { s.hasPrefix("|") && s.dropFirst().contains("|") }

    private static func isTableSeparator(_ s: String) -> Bool {
        guard s.hasPrefix("|") else { return false }
        let cs = cells(s)
        return !cs.isEmpty && cs.allSatisfy { c in !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }
    }

    private static func cells(_ s: String) -> [String] {
        var t = Substring(s)
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") { t = t.dropLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Strips a single wrapping ``` / ```markdown code fence some models emit.
    static func stripFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeFirst()
            if !lines.isEmpty { lines.removeLast() }
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        VStack(spacing: 0) {
            tableRow(header, columns: columns, bold: true)
            Divider().overlay(Theme.hairline)
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                tableRow(row, columns: columns, bold: false)
                if idx < rows.count - 1 { Divider().overlay(Theme.hairline.opacity(0.5)) }
            }
        }
        .padding(8)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }

    private func tableRow(_ cells: [String], columns: Int, bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<columns, id: \.self) { c in
                Text(inline(c < cells.count ? cells[c] : ""))
                    .font(.system(size: 12.5 * scale, weight: bold ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("### ") {
            Text(inline(String(line.dropFirst(4)))).font(.system(size: 13 * scale, weight: .semibold))
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.system(size: 16 * scale, weight: .bold))
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.system(size: 20 * scale, weight: .bold))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            bulletRow("•", String(line.dropFirst(2)))
        } else if let item = numberedItem(line) {
            bulletRow(item.marker, item.text)
        } else if line == "---" || line == "***" || line == "___" {
            Divider()
        } else if line.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(inline(line)).font(bodyFont).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bulletRow(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker).font(bodyFont)
            Text(inline(text)).font(bodyFont).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Parses "1. text" / "2) text" → ("1.", "text").
    private func numberedItem(_ line: String) -> (marker: String, text: String)? {
        var idx = line.startIndex
        var digits = ""
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx]); idx = line.index(after: idx)
        }
        guard !digits.isEmpty, digits.count <= 3, idx < line.endIndex else { return nil }
        let sep = line[idx]
        guard sep == "." || sep == ")" else { return nil }
        let afterSep = line.index(after: idx)
        guard afterSep < line.endIndex, line[afterSep] == " " else { return nil }
        return ("\(digits).", String(line[line.index(after: afterSep)...]))
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// Neutralizes Markdown links whose URL scheme isn't safe, so untrusted LLM /
    /// transcript text can't render a tappable `file://` / `javascript:` / `data:`
    /// link. The visible label text is preserved; only the link is removed.
    static func sanitizeLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        let allowed: Set<String> = ["oatmeal", "https", "http", "mailto"]
        let pattern = "\\[([^\\]]*)\\]\\(([^)\\s]*)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let label = ns.substring(with: m.range(at: 1))
            let urlStr = ns.substring(with: m.range(at: 2))
            if let scheme = URL(string: urlStr)?.scheme?.lowercased(), allowed.contains(scheme) {
                result += ns.substring(with: m.range) // keep the safe link intact
            } else {
                result += label                        // strip unsafe link, keep text
            }
        }
        result += ns.substring(from: cursor)
        return result
    }
}

// MARK: - Provenance notes (user vs AI coloring)

struct ProvenanceNotesView: View {
    let blocks: [NoteBlock]
    let segments: [SegmentRef]
    var onJump: (SegmentRef) -> Void

    @State private var expanded: Set<UUID> = []
    @State private var cache: [UUID: [SegmentRef]] = [:]
    @State private var computing: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                blockRow(block)
                    .staggeredReveal(index: idx, reduceMotion: reduceMotion, rise: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockRow(_ block: NoteBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                MarkdownView(markdown: block.text)
                    .foregroundStyle(block.isAI && !block.edited ? AnyShapeStyle(Theme.textSecondary) : AnyShapeStyle(Theme.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canGround(block) {
                    Button { toggle(block) } label: {
                        Image(systemName: expanded.contains(block.id) ? "quote.bubble.fill" : "quote.bubble")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Show transcript evidence")
                }
            }
            if expanded.contains(block.id) {
                sourcesView(block).transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func sourcesView(_ block: NoteBlock) -> some View {
        if computing.contains(block.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding sources…").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, 8)
        } else if let sources = cache[block.id] {
            if sources.isEmpty {
                Text("No clear transcript match for this line.")
                    .font(.caption).foregroundStyle(Theme.textTertiary).padding(.leading, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sources) { ref in
                        Button { onJump(ref) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "text.quote").font(.caption2).foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(ref.speaker) · \(timeString(ref.start))")
                                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                                    Text(ref.text).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle").font(.caption).foregroundStyle(Theme.accent)
                            }
                            .padding(8)
                            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    private func canGround(_ block: NoteBlock) -> Bool {
        block.isAI && !segments.isEmpty && NoteSourceMatcher.isAvailable
            && block.text.trimmingCharacters(in: .whitespaces).count >= 8
    }

    private func toggle(_ block: NoteBlock) {
        if expanded.contains(block.id) { expanded.remove(block.id); return }
        expanded.insert(block.id)
        guard cache[block.id] == nil, !computing.contains(block.id) else { return }
        computing.insert(block.id)
        let text = block.text
        let segs = segments
        let id = block.id
        Task {
            let result = await NoteSourceMatcher.sources(for: text, in: segs)
            cache[id] = result
            computing.remove(id)
        }
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Shared row

struct SegmentRow: View {
    let speaker: String
    let text: String
    /// When false, this line is a continuation of the same speaker's turn — the
    /// label is hidden and the text is indented to read as one grouped block.
    var showSpeaker: Bool = true
    /// Live mode: the live transcript REPLACES `liveSegments` on every update
    /// (two rolling rows, not an append-only list), so we can't fade in new rows
    /// without thrashing. Instead, when `streaming` is on, we smooth the *text*
    /// as it grows in place — a gentle interpolated content transition keyed on
    /// the text — so new speech feels like it streams in without flicker.
    var streaming: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat { Appearance.shared.fontScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showSpeaker {
                Text(speaker)
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(color(for: speaker))
            }
            Text(text)
                .font(.system(size: 13 * scale))
                .textSelection(.enabled)
                .padding(.leading, showSpeaker ? 0 : 2)
                .modifier(StreamingText(text: text, enabled: streaming, reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for speaker: String) -> Color {
        if speaker == "Me" { return .blue }
        let palette: [Color] = [.green, .orange, .purple, .pink, .teal, .indigo]
        var hash = 0
        for c in speaker.unicodeScalars { hash = (hash &* 31 &+ Int(c.value)) }
        return palette[abs(hash) % palette.count]
    }
}

/// Smooths in-place text growth for the live transcript's rolling rows.
///
/// The live transcript replaces its segments wholesale on each update, so the
/// row identity is stable but the `text` keeps growing. `contentTransition`
/// interpolates that change and a `Motion.reveal`-gated animation keyed on the
/// text makes the growth feel like streaming speech rather than a hard cut.
///
/// No-ops entirely when `enabled` is false (the saved transcript) or under
/// reduce-motion (text updates instantly with no transition).
private struct StreamingText: ViewModifier {
    let text: String
    let enabled: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if enabled && !reduceMotion {
            content
                .contentTransition(.interpolate)
                .animation(Motion.reveal(false), value: text)
        } else {
            content
        }
    }
}

// MARK: - Live Assist suggestion card

struct LiveSuggestionCard: View {
    /// How the card presents itself.
    /// - `.panel`: the managed in-app list (card chrome, copy button, new/old styling).
    /// - `.teleprompter`: the discreet floating overlay — chrome-free and large, so a
    ///   single glance near your eyeline tells you what to say, without reading an app.
    enum Style { case panel, teleprompter }

    let suggestion: LiveSuggestion
    /// The newest card — visually emphasized so it's catchable at a glance.
    var isLatest: Bool = false
    /// Presentation context. Defaults to the in-app panel.
    var style: Style = .panel
    /// Bumped each second by the parent to refresh the relative timestamp.
    var tick: Int = 0

    private var copyText: String {
        var lines: [String] = []
        if !suggestion.answer.isEmpty { lines.append(suggestion.answer) }
        lines += suggestion.talkingPoints.map { "• \($0)" }
        if !suggestion.followUps.isEmpty {
            lines.append("Ask next:")
            lines += suggestion.followUps.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    private var relativeTime: String {
        let secs = max(0, Date().timeIntervalSince(suggestion.createdAt))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(Int(secs))s ago" }
        return "\(Int(secs / 60))m ago"
    }

    var body: some View {
        switch style {
        case .teleprompter: teleprompterBody
        case .panel: panelBody
        }
    }

    // MARK: - Teleprompter (floating overlay)

    /// No card surface, no badges, no buttons — just large, readable lines that sit
    /// on the panel's own translucent background. Reads as a glance, not an app.
    private var teleprompterBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !suggestion.answer.isEmpty {
                Text(suggestion.answer)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !suggestion.talkingPoints.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(suggestion.talkingPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").foregroundStyle(Theme.accent)
                            Text(point).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
            }

            if !suggestion.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ask next").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ForEach(Array(suggestion.followUps.enumerated()), id: \.offset) { _, q in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(Theme.accent)
                            Text(q).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Panel (in-app managed list)

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if !suggestion.answer.isEmpty {
                Text(suggestion.answer)
                    .font(.system(.body).weight(isLatest ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !suggestion.talkingPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(suggestion.talkingPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(Theme.accent)
                            Text(point).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.footnote)
                    }
                }
            }

            if !suggestion.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask next").font(.caption.bold()).foregroundStyle(Theme.textSecondary)
                    ForEach(Array(suggestion.followUps.enumerated()), id: \.offset) { _, q in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(Theme.textSecondary)
                            Text(q).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .padding(Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(isLatest ? Theme.accent : Theme.accent.opacity(0.18),
                              lineWidth: isLatest ? 2 : 1)
        )
        .opacity(isLatest ? 1 : 0.6)
        .shadow(color: isLatest ? Theme.accent.opacity(0.25) : .clear, radius: isLatest ? 6 : 0)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "lightbulb.fill").font(.caption)
                .foregroundStyle(isLatest ? Theme.onAccent : Theme.accent)
            if let q = suggestion.question, !q.isEmpty {
                Text(q).font(.caption).lineLimit(2)
                    .foregroundStyle(isLatest ? Theme.onAccent : Theme.textSecondary)
            } else {
                Text("Suggestion").font(.caption)
                    .foregroundStyle(isLatest ? Theme.onAccent : Theme.textSecondary)
            }
            Spacer(minLength: 6)
            if isLatest {
                Text("NEW").font(.caption2.bold()).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.onAccent.opacity(0.22), in: Capsule())
            }
            Text(relativeTime).font(.caption2)
                .foregroundStyle(isLatest ? Theme.onAccent.opacity(0.85) : Theme.textSecondary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isLatest ? Theme.onAccent : Theme.textSecondary)
            .help("Copy suggestion")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isLatest ? Theme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }
}
