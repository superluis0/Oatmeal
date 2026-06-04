import Foundation
import SwiftData
import AppKit

/// Demo mode: a fully isolated, seeded instance of Oatmeal used for screenshots
/// and for contributors to explore the app without recording anything real.
///
/// Activated only by environment variables, so it can NEVER touch a real user's
/// data:
///   OATMEAL_STORE_DIR   — relocate the SwiftData store into a throwaway folder
///   OATMEAL_SEED_DEMO=1  — seed fictional meetings/people/tasks if the store is empty
///   OATMEAL_DEMO_SCREEN  — route straight to a screen on launch (for capture)
///   OATMEAL_DEMO_TAB     — initial meeting-detail tab (enhanced|notes|transcript|chat|analytics)
///   OATMEAL_DEMO_SHOT    — write the window rect here (top-left screen coords) for screencapture
///
/// When active, the app also skips backup restore/snapshot, calendar, reminders
/// and notifications so no real account data is read and nothing is written
/// outside the throwaway folder.
enum Demo {
    static var isActive: Bool { env("OATMEAL_SEED_DEMO") == "1" }
    static var storeDir: String? { env("OATMEAL_STORE_DIR") }
    static var screen: String { env("OATMEAL_DEMO_SCREEN") ?? "meeting" }
    static var outPath: String? { env("OATMEAL_DEMO_OUT") }

    static var initialTab: String? { env("OATMEAL_DEMO_TAB") }

    private static func env(_ key: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
        return v
    }

    /// A custom store URL inside the throwaway folder, or nil for the default.
    static var storeURL: URL? {
        guard let dir = storeDir else { return nil }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("demo.store")
    }

    // MARK: - Window parking (deterministic capture)

    /// Parks the window at a fixed size, then (when OATMEAL_DEMO_OUT is set)
    /// renders the window's own content to a PNG and exits. Self-rendering via
    /// `cacheDisplay` needs no Screen-Recording permission and is immune to
    /// window occlusion or stray instances — fully deterministic for screenshots.
    static func parkWindowForCapture(_ window: NSWindow) {
        guard isActive, let screen = NSScreen.main else { return }
        let size = NSSize(width: 1280, height: 820)
        let visible = screen.visibleFrame
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        guard let out = outPath else { return }
        // Once routing + the target screen have rendered, publish this window's
        // CoreGraphics window number and our real PID so an external
        // `screencapture -l<number>` grabs exactly this window (occlusion-proof)
        // and the launcher can kill exactly this process afterwards.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            window.makeKeyAndOrderFront(nil)
            let line = "\(window.windowNumber) \(ProcessInfo.processInfo.processIdentifier)"
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: out))
        }
    }

    // MARK: - Seeding

    /// Populates the (empty) demo store with a tasteful set of fictional meetings.
    static func seedIfNeeded(_ context: ModelContext) {
        guard isActive else { return }
        let count = (try? context.fetchCount(FetchDescriptor<Meeting>())) ?? 0
        guard count == 0 else { return }
        seed(context)
        try? context.save()
    }

    private static func date(_ daysAgo: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2025; c.month = 11; c.day = 18 - daysAgo; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 1_731_900_000)
    }

    private static func seed(_ ctx: ModelContext) {
        let work = Folder(name: "Work", createdAt: date(30, 9))
        let sales = Folder(name: "Sales", createdAt: date(30, 9))
        ctx.insert(work); ctx.insert(sales)

        // ── Meeting 1 (rich) — Product Sync ───────────────────────────────────
        let m1 = Meeting(
            id: UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000001")!,
            title: "Acme · Weekly Product Sync",
            date: date(0, 10), duration: 1_812,
            enhancedNotes: """
            ## Overview
            The team aligned on the **Q1 onboarding revamp** and agreed to ship the new
            guided setup behind a flag by **Jan 24**. Activation is the north-star metric;
            current 7-day activation sits at **38%**, target is **55%**.

            ## Decisions
            - Ship guided onboarding behind a feature flag, 10% rollout first.
            - Drop the legacy import wizard — usage is under 2%.
            - Maya owns the activation dashboard; Diego owns the flag infra.

            ## Key numbers
            - 7-day activation: **38% → 55%** target
            - Legacy import wizard usage: **<2%**
            - Rollout: **10%** → 50% → 100% over three weeks

            ## Open questions
            - Do we need a migration path for teams on the old wizard?
            - Can analytics land before the 10% rollout?
            """,
            tags: ["product", "q1-planning"], templateName: "Standup")
        m1.folder = work
        m1.speakerNames = ["Speaker 1": "Maya Chen", "Speaker 2": "Diego Park"]
        let s1 = Summary(
            text: "The team committed to a Q1 onboarding revamp: a new guided setup ships behind a feature flag by Jan 24, starting at a 10% rollout. Activation is the priority metric (38% today, 55% target). The legacy import wizard will be retired given <2% usage. Maya owns the activation dashboard, Diego owns flag infrastructure.",
            actionItems: [
                "Maya to build the activation dashboard before the 10% rollout",
                "Diego to stand up the feature-flag infra by Jan 20",
                "Priya to draft migration messaging for legacy-wizard teams"
            ],
            keyPoints: [
                "Guided onboarding ships behind a flag by Jan 24",
                "7-day activation target raised from 38% to 55%",
                "Legacy import wizard retired (<2% usage)",
                "Rollout: 10% → 50% → 100% across three weeks"
            ], createdAt: date(0, 11))
        m1.summary = s1; ctx.insert(s1)
        seedAttendees(ctx, m1, [("Maya Chen", "Speaker 1"), ("Diego Park", "Speaker 2"), ("Priya Rao", nil)])
        seedSegments(ctx, m1, [
            ("Me", "Okay, let's kick off. The big rock this quarter is the onboarding revamp — can we commit to a date?"),
            ("Maya Chen", "I think we can ship the guided setup behind a flag by the 24th, as long as the activation dashboard lands first so we can actually read the rollout."),
            ("Diego Park", "Flag infra is straightforward. I can have it ready by the 20th. I'd start at 10% before we go wider."),
            ("Me", "Love it. What about the old import wizard?"),
            ("Maya Chen", "Usage is under two percent. I'd just retire it. Not worth maintaining."),
            ("Priya Rao", "We'll want migration messaging for the handful of teams still on it. I can draft that."),
            ("Me", "Great. So activation goes from thirty-eight to a fifty-five percent target, dashboard first, then ten percent rollout."),
        ])
        seedActions(ctx, m1, [
            ("Build the activation dashboard before the 10% rollout", "Maya Chen", 6, false),
            ("Stand up the feature-flag infrastructure", "Diego Park", 2, false),
            ("Draft migration messaging for legacy-wizard teams", "Priya Rao", 9, false),
            ("Retire the legacy import wizard", "Diego Park", 14, true),
        ])
        seedChat(ctx, m1, [
            ("user", "What did we decide about the old import wizard?"),
            ("assistant", "The team decided to **retire the legacy import wizard** — usage is under 2%, so it isn't worth maintaining. Priya will draft migration messaging for the few teams still on it before it's removed."),
            ("user", "When does guided onboarding ship and at what rollout?"),
            ("assistant", "Guided onboarding ships **behind a feature flag by Jan 24**, starting at a **10% rollout**, then widening to 50% and 100% over the following three weeks. Diego is standing up the flag infrastructure by Jan 20."),
        ])
        let h = Highlight(time: 742, note: "Activation target set to 55%", createdAt: date(0, 10)); h.meeting = m1; ctx.insert(h)

        // ── Meeting 2 — Design Review ─────────────────────────────────────────
        let m2 = Meeting(
            id: UUID(uuidString: "B2C3D4E5-0000-0000-0000-000000000002")!,
            title: "Design Review · Mobile Onboarding",
            date: date(1, 14), duration: 2_540,
            enhancedNotes: "## Overview\nReviewed three directions for the mobile onboarding flow. Consensus on the **progressive-disclosure** approach with a single primary action per screen.\n\n## Decisions\n- Go with progressive disclosure (Direction B).\n- Cut the welcome carousel; lead with value.\n- Add a skip affordance on every step.",
            tags: ["design"], templateName: "Design Review")
        m2.folder = work
        m2.speakerNames = ["Speaker 1": "Sam Rivera", "Speaker 2": "Jordan Lee"]
        let s2 = Summary(
            text: "The team reviewed three onboarding directions and aligned on progressive disclosure (Direction B) with one primary action per screen. The welcome carousel is cut in favor of leading with value, and every step gets a skip affordance.",
            actionItems: ["Sam to update the prototype to Direction B", "Jordan to spec the skip behavior"],
            keyPoints: ["Progressive disclosure chosen", "Welcome carousel removed", "Skip on every step"],
            createdAt: date(1, 15))
        m2.summary = s2; ctx.insert(s2)
        seedAttendees(ctx, m2, [("Sam Rivera", "Speaker 1"), ("Jordan Lee", "Speaker 2")])
        seedSegments(ctx, m2, [
            ("Me", "Three directions on the board — which one feels right for first-run?"),
            ("Sam Rivera", "Direction B. Progressive disclosure, one primary action per screen. It tested best for comprehension."),
            ("Jordan Lee", "Agreed. And let's cut the welcome carousel — people swipe past it anyway. Lead with the value."),
        ])
        seedActions(ctx, m2, [
            ("Update the prototype to Direction B", "Sam Rivera", 3, false),
            ("Spec the skip behavior for every step", "Jordan Lee", 5, false),
        ])

        // ── Meeting 3 — Customer call ─────────────────────────────────────────
        let m3 = Meeting(
            id: UUID(uuidString: "C3D4E5F6-0000-0000-0000-000000000003")!,
            title: "Customer Call · Northwind Trading",
            date: date(2, 11), duration: 1_355,
            enhancedNotes: "## Overview\nNorthwind is evaluating for a 40-seat rollout. Main blockers: SSO and an audit log. Budget approved for Q1; security review is the gate.\n\n## Decisions\n- Send SOC 2 report and SSO docs.\n- Schedule a security review for next week.",
            tags: ["sales"], templateName: "Sales Call")
        m3.folder = sales
        m3.speakerNames = ["Speaker 1": "Alex Morgan"]
        let s3 = Summary(
            text: "Northwind Trading is evaluating Oatmeal for a 40-seat rollout. Budget is approved for Q1; the gate is a security review. They need SSO and an audit log before purchase. Next step is sending the SOC 2 report and scheduling the review.",
            actionItems: ["Send SOC 2 report and SSO setup docs to Alex", "Schedule the security review for next week"],
            keyPoints: ["40-seat rollout under evaluation", "Blockers: SSO + audit log", "Budget approved for Q1"],
            createdAt: date(2, 12))
        m3.summary = s3; ctx.insert(s3)
        seedAttendees(ctx, m3, [("Alex Morgan", "Speaker 1")])
        seedSegments(ctx, m3, [
            ("Me", "Where are you in the evaluation?"),
            ("Alex Morgan", "Budget's approved for Q1. The two things my security team needs before we sign are SSO and an audit log."),
            ("Me", "Both are supported. I'll send the SOC 2 report and SSO docs today, and let's get a security review on the calendar."),
        ])
        seedActions(ctx, m3, [
            ("Send SOC 2 report and SSO setup docs to Alex", "Me", 1, false),
            ("Schedule the security review", "Me", 4, false),
        ])

        // ── Meetings 4 & 5 (list filler) ──────────────────────────────────────
        let m4 = Meeting(title: "Engineering Standup", date: date(3, 9), duration: 612,
                         enhancedNotes: "## Updates\n- Search indexing shipped.\n- Flaky test quarantined.\n- Pairing on the migration this afternoon.", tags: ["eng"])
        m4.folder = work
        let s4 = Summary(text: "Quick standup: search indexing shipped, a flaky test was quarantined, and the team is pairing on the data migration this afternoon.", actionItems: ["Re-enable the quarantined test once fixed"], keyPoints: ["Search indexing shipped"], createdAt: date(3, 9))
        m4.summary = s4; ctx.insert(s4)
        seedAttendees(ctx, m4, [("Maya Chen", nil), ("Diego Park", nil)])

        let m5 = Meeting(title: "1:1 · Career Growth", date: date(5, 16), duration: 1_980,
                         enhancedNotes: "## Themes\n- Wants more scope on platform work.\n- Aiming for a tech-lead track.\n\n## Next steps\n- Find a platform project for next quarter.", tags: ["1:1"])
        m5.folder = work
        let s5 = Summary(text: "A career-growth 1:1: interest in more platform scope and a tech-lead track. Agreed to find a suitable platform project next quarter.", actionItems: ["Identify a platform project for Q1"], keyPoints: ["Tech-lead track", "More platform scope"], createdAt: date(5, 16))
        m5.summary = s5; ctx.insert(s5)

        for m in [m1, m2, m3, m4, m5] { ctx.insert(m) }

        // Global "Ask Oatmeal" session with a cited answer across meetings.
        let session = ChatSession(scopeRaw: "all", title: "all meetings", createdAt: date(0, 12))
        ctx.insert(session)
        let q = ChatMessage(role: "user", text: "What are my open action items this week?", createdAt: date(0, 12)); q.session = session; ctx.insert(q)
        let a = ChatMessage(role: "assistant", text: """
        You have several open items:

        - **Build the activation dashboard** before the 10% rollout — Maya [#a1b2c3d4]
        - **Stand up the feature-flag infra** by Jan 20 — Diego [#a1b2c3d4]
        - **Update the prototype to Direction B** — Sam [#b2c3d4e5]
        - **Send the SOC 2 report and SSO docs** to Northwind [#c3d4e5f6]

        The Northwind item is time-sensitive — it's blocking their security review.
        """, createdAt: date(0, 12)); a.session = session; ctx.insert(a)
    }

    private static func seedAttendees(_ ctx: ModelContext, _ m: Meeting, _ people: [(String, String?)]) {
        for (name, label) in people {
            let a = Attendee(name: name, mappedSpeakerLabel: label)
            a.meeting = m; ctx.insert(a)
        }
    }

    private static func seedSegments(_ ctx: ModelContext, _ m: Meeting, _ lines: [(String, String)]) {
        var t = 0.0
        for (speaker, text) in lines {
            let dur = Double(max(6, text.count / 12))
            let seg = TranscriptSegment(start: t, end: t + dur, speaker: speaker, text: text)
            seg.meeting = m; ctx.insert(seg)
            t += dur + 1
        }
    }

    private static func seedActions(_ ctx: ModelContext, _ m: Meeting, _ items: [(String, String, Int, Bool)]) {
        for (text, owner, dueInDays, done) in items {
            let due = Calendar.current.date(byAdding: .day, value: dueInDays, to: date(0, 10))
            let item = ActionItem(text: text, isDone: done, dueDate: due, owner: owner, createdAt: date(0, 11))
            item.meeting = m; ctx.insert(item)
        }
    }

    private static func seedChat(_ ctx: ModelContext, _ m: Meeting, _ msgs: [(String, String)]) {
        var when = date(0, 11)
        for (role, text) in msgs {
            let msg = ChatMessage(role: role, text: text, createdAt: when)
            msg.meeting = m; ctx.insert(msg)
            when = when.addingTimeInterval(40)
        }
    }
}
