import SwiftUI

/// Per-version highlights, newest first. **Single source of truth** for the
/// in-app "What's new" card AND the GitHub release notes — when cutting a release,
/// add the new version's bullets here and reuse them for the release notes.
enum WhatsNew {
    static let entries: [(version: String, bullets: [String])] = [
        ("0.7.4", [
            "Meeting summaries are more detailed and better organized \u{2014} longer meetings get clear sections, while quick check-ins stay short.",
            "Fix a speaker and the summary keeps up: renames update it instantly, and merging speakers offers a one-tap \u{201C}Update summary.\u{201D}",
            "Cross-meeting Digests and Decision logs are saved now \u{2014} leave the view and come back, and they\u{2019}re still there.",
            "Meeting chat reads as saved history, with timestamps, day dividers, and a Clear button.",
            "Control Oatmeal from Shortcuts, Spotlight & Siri, plus optional global hotkeys to quick-ask or paste your latest recap \u{2014} all in Settings \u{2192} Automation.",
            "More reliable: fixed crashes around chatting after a long reply, rapid Record/Stop, and speaker re-identify \u{2014} plus a fix so speaker corrections always reach your summary.",
        ]),
        ("0.7.3", [
            "Fixed a crash that could happen while processing a long recording.",
            "If the database ever has trouble saving, Oatmeal flags it and points you to a one-restart recovery \u{2014} your meetings are always backed up.",
            "Updates now check every couple of hours, not just on launch.",
        ]),
        ("0.7.2", [
            "A floating banner now tells you the moment an update is ready.",
            "New in-app Log viewer (Settings \u{2192} Privacy \u{2192} View Logs) with one-tap copy/save for support.",
            "Meetings load on the first click in the sidebar, every time.",
            "Fixed a crash when renaming a speaker.",
        ]),
    ]

    static func bullets(for version: String) -> [String]? {
        entries.first { $0.version == version }?.bullets
    }
}

/// Identifiable payload for presenting the What's New sheet via `.sheet(item:)`.
struct WhatsNewInfo: Identifiable {
    let id = UUID()
    let version: String
    let bullets: [String]
}

/// A cozy "What's new in X" card, shown once after an update (first launch on a
/// new version). Read-only, dismissible.
struct WhatsNewSheet: View {
    let version: String
    let bullets: [String]
    var onDismiss: () -> Void
    @State private var appearance = Appearance.shared

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            VStack(spacing: 6) {
                IconBadge(systemName: "sparkles", size: 56)
                Text("What\u{2019}s new")
                    .font(.system(.title2).weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Oatmeal \(version)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 1)
                        Text(bullet)
                            .font(.system(.callout))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Got it", action: onDismiss)
                .buttonStyle(OatPrimaryButton(fullWidth: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .background(Theme.bg)
        .fontDesign(appearance.fontDesign)
    }
}
