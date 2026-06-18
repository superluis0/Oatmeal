import SwiftUI

/// Per-version highlights, newest first. **Single source of truth** for the in-app
/// "What's new" changelog AND the GitHub release notes — when cutting a release, add
/// the new version's date + bullets at the TOP and reuse the bullets for the notes.
enum WhatsNew {
    static let entries: [(version: String, date: String, bullets: [String])] = [
        ("0.7.6", "Jun 18, 2026", [
            "Recover a recording that didn\u{2019}t save \u{2014} if a recording can\u{2019}t be saved, its audio is kept and now appears in the sidebar with one-tap Recover, which rebuilds the whole meeting (transcript, speakers, summary) from the audio.",
            "More reliable storage: Oatmeal\u{2019}s database now lives in its own folder, and a crash that could happen after recording (when the database had trouble saving) is fixed.",
            "The Digest leads with your action items now \u{2014} grouped by Overdue and Due this week, checkable, and clickable straight to the meeting, with a short AI summary below.",
            "Click a folder\u{2019}s name in the sidebar to expand or collapse it (not just the little arrow), and Oatmeal remembers which folders you\u{2019}ve collapsed.",
        ]),
        ("0.7.5", "Jun 17, 2026", [
            "Organize meetings into collapsible folders in the sidebar \u{2014} drag and drop (or right-click) to file them by person, company, or project.",
            "Jump around a recording with chapters: auto-detected topics you can tap to skip right to that moment (in the Transcript tab).",
            "A real audio player \u{2014} rewind/forward 15s, stop, 1\u{00D7}\u{2013}2\u{00D7} speed, and a full scrubber.",
            "Find a moment by meaning: semantic search now drops you on the exact spot in the transcript, not just the meeting.",
            "Each person now shows recurring topics and when you last met; share faster with a clean recap (no transcript) or a drafted thank-you note.",
            "Polish: bigger, clearer Settings text; a scrollable What\u{2019}s-New history; one-tap setup for Shortcuts/Siri & Claude; and sturdier database diagnostics.",
        ]),
        ("0.7.4", "Jun 16, 2026", [
            "Meeting summaries are more detailed and better organized \u{2014} longer meetings get clear sections, while quick check-ins stay short.",
            "Fix a speaker and the summary keeps up: renames update it instantly, and merging speakers offers a one-tap \u{201C}Update summary.\u{201D}",
            "Cross-meeting Digests and Decision logs are saved now \u{2014} leave the view and come back, and they\u{2019}re still there.",
            "Meeting chat reads as saved history, with timestamps, day dividers, and a Clear button.",
            "Control Oatmeal from Shortcuts, Spotlight & Siri, plus optional global hotkeys to quick-ask or paste your latest recap \u{2014} all in Settings \u{2192} Automation.",
            "More reliable: fixed crashes around chatting after a long reply, rapid Record/Stop, and speaker re-identify \u{2014} plus a fix so speaker corrections always reach your summary.",
        ]),
        ("0.7.3", "Jun 16, 2026", [
            "Fixed a crash that could happen while processing a long recording.",
            "If the database ever has trouble saving, Oatmeal flags it and points you to a one-restart recovery \u{2014} your meetings are always backed up.",
            "Updates now check every couple of hours, not just on launch.",
        ]),
        ("0.7.2", "Jun 16, 2026", [
            "A floating banner now tells you the moment an update is ready.",
            "New in-app Log viewer (Settings \u{2192} Privacy \u{2192} View Logs) with one-tap copy/save for support.",
            "Meetings load on the first click in the sidebar, every time.",
            "Fixed a crash when renaming a speaker.",
        ]),
    ]

    static func bullets(for version: String) -> [String]? {
        entries.first { $0.version == version }?.bullets
    }

    /// True when there's a changelog entry for this version (so we don't show an
    /// empty sheet for a version with no notes).
    static func hasEntry(for version: String) -> Bool {
        entries.contains { $0.version == version }
    }
}

/// Identifiable payload for presenting the What's New sheet via `.sheet(item:)`.
/// Carries the version the user just updated TO, which the sheet badges as "Latest".
struct WhatsNewInfo: Identifiable {
    let id = UUID()
    let version: String
}

/// A cozy "What's new" changelog, shown once after an update. Newest release on top
/// (badged "Latest"), every prior release below it with its date — scroll through
/// the whole history. Read-only, dismissible.
struct WhatsNewSheet: View {
    /// The version the user just updated to (highlighted at the top).
    let currentVersion: String
    var onDismiss: () -> Void
    @State private var appearance = Appearance.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                IconBadge(systemName: "sparkles", size: 56)
                Text("What\u{2019}s new")
                    .font(.system(.title2).weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("You\u{2019}re now on Oatmeal \(currentVersion)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.md)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    ForEach(WhatsNew.entries, id: \.version) { entry in
                        versionBlock(entry)
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.hairline)

            Button("Got it", action: onDismiss)
                .buttonStyle(OatPrimaryButton(fullWidth: true))
                .keyboardShortcut(.defaultAction)
                .padding(Theme.Space.lg)
        }
        .frame(width: 480, height: 580)
        .background(Theme.bg)
        .fontDesign(appearance.fontDesign)
    }

    @ViewBuilder
    private func versionBlock(_ entry: (version: String, date: String, bullets: [String])) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 8) {
                Text("Version \(entry.version)")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if entry.version == currentVersion {
                    Text("Latest")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                }
                Spacer()
                Text(entry.date)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(entry.bullets, id: \.self) { bullet in
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
    }
}
