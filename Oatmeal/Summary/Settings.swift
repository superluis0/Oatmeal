import Foundation

enum AppSettings {
    private static let baseURLKey = "lmStudioBaseURL"
    private static let modelKey = "lmStudioModel"
    private static let defaultTemplateKey = "defaultNoteTemplate"
    private static let autoDetectKey = "autoDetectMeetings"
    private static let autoSelectTemplateKey = "autoSelectTemplate"
    private static let webhookURLKey = "webhookURL"
    private static let inputDeviceUIDKey = "inputDeviceUID"
    private static let hasOnboardedKey = "hasOnboarded"
    private static let preMeetingRemindersKey = "preMeetingReminders"
    private static let syncRemindersKey = "syncReminders"
    private static let modelVersionKey = "modelVersion"
    private static let inPersonModeKey = "inPersonMode"
    private static let audioRetentionDaysKey = "audioRetentionDays"
    private static let upcomingVideoOnlyKey = "upcomingVideoOnly"
    private static let liveAssistEnabledKey = "liveAssistEnabled"
    private static let assistProfileKey = "assistProfile"
    private static let floatingPanelAutoKey = "floatingPanelAuto"
    private static let userNameKey = "userName"
    private static let userTaglineKey = "userTagline"
    private static let checkForUpdatesKey = "checkForUpdates"

    /// Whether to check the GitHub repo for a newer release (~once/day). Default on.
    static var checkForUpdates: Bool {
        get { (UserDefaults.standard.object(forKey: checkForUpdatesKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: checkForUpdatesKey) }
    }

    static let defaultBaseURL = "http://127.0.0.1:1234"

    /// The user's own name, so the AI knows who the "Me" speaker is and never
    /// confuses the note-taker with the other participants.
    static var userName: String {
        get { UserDefaults.standard.string(forKey: userNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: userNameKey) }
    }

    /// Optional one-line role / company for the user (e.g. "PM at Acme"), used to
    /// ground affiliations correctly in summaries and chat.
    static var userTagline: String {
        get { UserDefaults.standard.string(forKey: userTaglineKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: userTaglineKey) }
    }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    /// Optional explicit model id. Empty => auto-select the first loaded model.
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// Name of the note template applied to new meetings by default.
    static var defaultTemplate: String {
        get { UserDefaults.standard.string(forKey: defaultTemplateKey) ?? NoteTemplate.builtins[0].name }
        set { UserDefaults.standard.set(newValue, forKey: defaultTemplateKey) }
    }

    /// When on, Oatmeal prompts to record when it detects a meeting app + live event.
    static var autoDetectMeetings: Bool {
        get { UserDefaults.standard.bool(forKey: autoDetectKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDetectKey) }
    }

    /// When on, the note template is chosen automatically from the transcript.
    static var autoSelectTemplate: Bool {
        get { UserDefaults.standard.bool(forKey: autoSelectTemplateKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSelectTemplateKey) }
    }

    /// Optional outbound webhook (e.g. Slack incoming webhook). Empty => disabled.
    static var webhookURL: String {
        get { UserDefaults.standard.string(forKey: webhookURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: webhookURLKey) }
    }

    /// UID of the chosen microphone input device. Empty => system default.
    static var inputDeviceUID: String {
        get { UserDefaults.standard.string(forKey: inputDeviceUIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: inputDeviceUIDKey) }
    }

    /// Whether the user has completed first-run onboarding.
    static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: hasOnboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasOnboardedKey) }
    }

    /// Notify ~1 min before upcoming calendar meetings with a "Start Recording" action.
    static var preMeetingReminders: Bool {
        get { UserDefaults.standard.bool(forKey: preMeetingRemindersKey) }
        set { UserDefaults.standard.set(newValue, forKey: preMeetingRemindersKey) }
    }

    /// Push action items into an "Oatmeal" Apple Reminders list.
    static var syncReminders: Bool {
        get { UserDefaults.standard.bool(forKey: syncRemindersKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncRemindersKey) }
    }

    /// Parakeet model: "v2" (English, fastest) or "v3" (multilingual).
    static var modelVersion: String {
        get { UserDefaults.standard.string(forKey: modelVersionKey) ?? "v2" }
        set { UserDefaults.standard.set(newValue, forKey: modelVersionKey) }
    }

    /// Diarize the microphone into multiple speakers (for in-room recordings)
    /// instead of labeling everything "Me".
    static var inPersonMode: Bool {
        get { UserDefaults.standard.bool(forKey: inPersonModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: inPersonModeKey) }
    }

    /// Auto-delete archived audio older than this many days (0 = keep forever).
    static var audioRetentionDays: Int {
        get { UserDefaults.standard.integer(forKey: audioRetentionDaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: audioRetentionDaysKey) }
    }

    /// Upcoming view shows only events with a video-call link (default on).
    static var upcomingVideoOnly: Bool {
        get { (UserDefaults.standard.object(forKey: upcomingVideoOnlyKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: upcomingVideoOnlyKey) }
    }

    /// When on, Oatmeal privately suggests answers + follow-up questions live
    /// during a recording (auto on detected questions, plus a manual button).
    static var liveAssistEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: liveAssistEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: liveAssistEnabledKey) }
    }

    /// Free-text about the user (bio / resume / role) used to personalize Live
    /// Assist suggestions. Stored locally only.
    static var assistProfile: String {
        get { UserDefaults.standard.string(forKey: assistProfileKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: assistProfileKey) }
    }

    /// Automatically open the floating panel when a recording starts (default on).
    static var floatingPanelAuto: Bool {
        get { (UserDefaults.standard.object(forKey: floatingPanelAutoKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: floatingPanelAutoKey) }
    }
}
