import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Start/stop recording from anywhere (default ⌥⌘R).
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .option]))
    /// Bookmark a moment while recording (default ⌥⌘H).
    static let markMoment = Self("markMoment", default: .init(.h, modifiers: [.command, .option]))
    /// Quick-ask across all meetings from anywhere (default ⌥⌘A).
    static let quickAsk = Self("quickAsk", default: .init(.a, modifiers: [.command, .option]))
    /// Paste the latest meeting's recap into the frontmost app (default ⌥⌘V).
    static let copyRecap = Self("copyRecap", default: .init(.v, modifiers: [.command, .option]))
}
