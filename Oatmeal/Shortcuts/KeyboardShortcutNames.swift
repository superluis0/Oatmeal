import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Start/stop recording from anywhere (default ⌥⌘R).
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .option]))
    /// Bookmark a moment while recording (default ⌥⌘H).
    static let markMoment = Self("markMoment", default: .init(.h, modifiers: [.command, .option]))
}
