import AppIntents
import SwiftData

/// Errors surfaced to Shortcuts / Siri with a friendly message.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case disabled, notReady, noMeetings, emptyQuestion, aiUnreachable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .disabled:      return "Turn on Shortcuts in Oatmeal \u{2192} Settings \u{2192} Automation to use this."
        case .notReady:      return "Open Oatmeal and try again."
        case .noMeetings:    return "You don't have any meetings yet."
        case .emptyQuestion: return "Ask me something about your meetings."
        case .aiUnreachable: return "Your local AI (LM Studio) isn't reachable. Start its server and try again."
        }
    }
}

/// Shared gate: App Intents are opt-in (Settings → Automation), and need the live
/// store — which `openAppWhenRun` brings up; we wait briefly for it to settle.
@MainActor
private func intentContext() async throws -> ModelContext {
    guard AppSettings.shortcutsEnabled else { throw IntentError.disabled }
    guard let ctx = await AppLifecycle.shared.awaitContext() else { throw IntentError.notReady }
    return ctx
}

// MARK: - Ask Oatmeal

struct AskOatmealIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Oatmeal"
    static var description = IntentDescription("Ask a question across all your meetings — answered on-device.")
    static var openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to know about your meetings?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let answer = try await MeetingQueryService(context: try await intentContext()).ask(question)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

// MARK: - Summarize last meeting

struct LastMeetingSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Summarize Last Meeting"
    static var description = IntentDescription("Get the summary of your most recent meeting.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = try MeetingQueryService(context: try await intentContext()).latestMeetingSummary()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Open action items

struct OpenActionItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Action Items"
    static var description = IntentDescription("List your open action items, optionally for one owner.")
    static var openAppWhenRun = true

    @Parameter(title: "Owner (optional)")
    var owner: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = MeetingQueryService(context: try await intentContext()).openActionItems(owner: owner)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Find meetings

struct FindMeetingsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Meetings"
    static var description = IntentDescription("Find meetings whose title or transcript matches a keyword.")
    static var openAppWhenRun = true

    @Parameter(title: "Keyword")
    var keyword: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = MeetingQueryService(context: try await intentContext()).findMeetings(keyword)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Start recording

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Start recording a meeting in Oatmeal.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AppSettings.shortcutsEnabled else { throw IntentError.disabled }
        guard let coord = AppLifecycle.shared.coordinator,
              let ctx = await AppLifecycle.shared.awaitContext() else { throw IntentError.notReady }
        guard !coord.isRecording else { return .result(dialog: "Oatmeal is already recording.") }
        await coord.start(context: ctx)
        return .result(dialog: "Recording started.")
    }
}

// MARK: - App Shortcuts (zero-config phrases in Spotlight / Siri)

struct OatmealShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskOatmealIntent(),
                    phrases: ["Ask my meetings in \(.applicationName)", "Ask \(.applicationName)"],
                    shortTitle: "Ask Oatmeal", systemImageName: "sparkles")
        AppShortcut(intent: LastMeetingSummaryIntent(),
                    phrases: ["Summarize my last meeting in \(.applicationName)", "\(.applicationName) last meeting"],
                    shortTitle: "Last Meeting Summary", systemImageName: "doc.text")
        AppShortcut(intent: OpenActionItemsIntent(),
                    phrases: ["My action items in \(.applicationName)", "\(.applicationName) action items"],
                    shortTitle: "Open Action Items", systemImageName: "checklist")
        AppShortcut(intent: FindMeetingsIntent(),
                    phrases: ["Find a meeting in \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "Find Meetings", systemImageName: "magnifyingglass")
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording in \(.applicationName)", "Record a meeting in \(.applicationName)"],
                    shortTitle: "Start Recording", systemImageName: "record.circle")
    }
}
