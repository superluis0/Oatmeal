import SwiftUI
import SwiftData

/// A real task manager over every meeting's action items (plus standalone tasks):
/// time-bucketed (Overdue / Today / This Week / Later / No Date / Snoozed / Done),
/// filterable by owner, with quick natural-language capture.
struct TasksView: View {
    @Query(sort: \ActionItem.createdAt, order: .reverse) private var items: [ActionItem]
    var onOpenMeeting: (Meeting) -> Void
    @Environment(\.modelContext) private var context

    @State private var quickAdd = ""
    @State private var ownerFilter: String? = nil
    @State private var showDone = false

    private var owners: [String] {
        Array(Set(items.compactMap { $0.owner }.filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [ActionItem] {
        guard let owner = ownerFilter else { return items }
        return items.filter { $0.owner == owner }
    }

    private func items(in bucket: TaskDates.Bucket) -> [ActionItem] {
        filtered
            .filter { TaskDates.bucket(for: $0) == bucket }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var openCount: Int { filtered.filter { !$0.isDone }.count }

    var body: some View {
        VStack(spacing: 0) {
            quickAddBar
            Divider().overlay(Theme.hairline)
            if items.isEmpty {
                OatEmptyState(
                    icon: "checklist",
                    title: "No action items yet",
                    message: "Record a meeting and Oatmeal extracts tasks here — or add one above."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        ForEach(TaskDates.Bucket.allCases) { bucket in
                            if bucket == .done {
                                let doneItems = items(in: .done)
                                if !doneItems.isEmpty {
                                    DisclosureGroup(isExpanded: $showDone) {
                                        card(doneItems)
                                    } label: {
                                        SectionLabel(text: "Done (\(doneItems.count))")
                                    }
                                }
                            } else {
                                let bucketItems = items(in: bucket)
                                if !bucketItems.isEmpty { section(bucket, bucketItems) }
                            }
                        }
                    }
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("All owners") { ownerFilter = nil }
                    if !owners.isEmpty { Divider() }
                    ForEach(owners, id: \.self) { o in
                        Button { ownerFilter = o } label: {
                            Label(o, systemImage: ownerFilter == o ? "checkmark" : "person")
                        }
                    }
                } label: {
                    Label(ownerFilter ?? "Everyone", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private var quickAddBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
            TextField("Add a task… (e.g. “Email Dan the deck by Friday”)", text: $quickAdd)
                .textFieldStyle(.plain)
                .onSubmit(addTask)
            if !quickAdd.isEmpty {
                Button("Add", action: addTask).buttonStyle(OatSecondaryButton())
            }
            Text("\(openCount) open").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Space.md)
    }

    private func section(_ bucket: TaskDates.Bucket, _ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label("\(bucket.rawValue) (\(items.count))", systemImage: bucket.icon)
                .font(.system(.subheadline).weight(.semibold))
                .foregroundStyle(bucket == .overdue ? Theme.danger : Theme.textSecondary)
            card(items)
        }
    }

    private func card(_ items: [ActionItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                ActionItemRow(item: item, showSource: true, onOpenMeeting: onOpenMeeting)
                if item.persistentModelID != items.last?.persistentModelID {
                    Divider().overlay(Theme.hairline).padding(.leading, 36)
                }
            }
        }
        .oatCard(padding: Theme.Space.xs)
    }

    private func addTask() {
        let text = quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let item = ActionItem(text: text, dueDate: TaskDates.parse(text))
        context.insert(item)
        try? context.save()
        quickAdd = ""
    }
}

/// A single checkable action item with inline due/snooze/owner controls;
/// reused in the Tasks view and meeting detail.
struct ActionItemRow: View {
    @Bindable var item: ActionItem
    var showSource: Bool = false
    var onOpenMeeting: ((Meeting) -> Void)? = nil
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Button {
                item.isDone.toggle()
                if item.isDone { item.snoozedUntil = nil }
                try? context.save()
                RemindersService.syncCompletion(of: item)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? Theme.accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(.body))
                    .foregroundStyle(item.isDone ? Theme.textSecondary : Theme.textPrimary)
                    .strikethrough(item.isDone, color: Theme.textTertiary)
                metadata
                if showSource, let meeting = item.meeting {
                    Button { onOpenMeeting?(meeting) } label: {
                        Label(meeting.title, systemImage: "waveform")
                            .font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            rowMenu
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, Theme.Space.xs)
    }

    @ViewBuilder
    private var metadata: some View {
        if item.owner != nil || item.dueDate != nil || item.snoozedUntil != nil {
            HStack(spacing: 8) {
                if let owner = item.owner, !owner.isEmpty {
                    Label(owner, systemImage: "person").labelStyle(.titleAndIcon)
                }
                if let due = item.dueDate {
                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(due < .now && !item.isDone ? Theme.danger : Theme.textSecondary)
                }
                if let snz = item.snoozedUntil, snz > .now {
                    Label("Snoozed", systemImage: "moon.zzz.fill").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var rowMenu: some View {
        Menu {
            Menu("Due date") {
                Button("Today") { setDue(TaskDates.today) }
                Button("Tomorrow") { setDue(TaskDates.tomorrow) }
                Button("Next week") { setDue(TaskDates.nextWeek) }
                if item.dueDate != nil { Divider(); Button("Clear") { setDue(nil) } }
            }
            Menu("Snooze") {
                Button("Until tomorrow") { snooze(TaskDates.tomorrow) }
                Button("Until next week") { snooze(TaskDates.nextWeek) }
                if item.snoozedUntil != nil { Divider(); Button("Unsnooze") { snooze(nil) } }
            }
            if let attendees = item.meeting?.attendees, !attendees.isEmpty {
                Menu("Owner") {
                    ForEach(attendees) { a in
                        Button(a.name) { item.owner = a.name; try? context.save() }
                    }
                    if item.owner != nil { Divider(); Button("Clear") { item.owner = nil; try? context.save() } }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                context.delete(item)
                try? context.save()
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textTertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .menuIndicator(.hidden)
    }

    private func setDue(_ date: Date?) {
        item.dueDate = date
        try? context.save()
    }

    private func snooze(_ date: Date?) {
        item.snoozedUntil = date
        try? context.save()
    }
}
