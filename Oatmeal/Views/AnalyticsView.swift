import SwiftUI
import Charts

/// Per-meeting coaching & analytics: local talk-time / questions / monologues,
/// plus on-demand LLM coaching and opt-in BANT/MEDDIC scoring.
struct AnalyticsView: View {
    let meeting: Meeting

    @State private var coaching: String?
    @State private var working = false
    @State private var error: String?

    private var analytics: MeetingAnalytics {
        MeetingAnalytics.compute(meeting.orderedSegments.map {
            MeetingAnalytics.Seg(name: meeting.displayName(for: $0.speaker),
                                 start: $0.start, end: $0.end, text: $0.text)
        })
    }

    var body: some View {
        if meeting.segments.isEmpty {
            Text("No transcript to analyze yet.")
                .foregroundStyle(Theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                talkTimeCard
                statsRow
                coachingCard
            }
        }
    }

    private var talkTimeCard: some View {
        let a = analytics
        return GroupBox {
            if a.speakers.isEmpty {
                Text("No speaker data.").font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Chart(a.speakers) { s in
                    BarMark(
                        x: .value("Seconds", s.seconds),
                        y: .value("Speaker", s.name)
                    )
                    .foregroundStyle(Theme.accent)
                    .annotation(position: .trailing) {
                        Text(percent(s.seconds, of: a.totalSeconds))
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(a.speakers.count) * 38 + 12)
                .padding(8)
            }
        } label: {
            Label("Talk time", systemImage: "waveform")
        }
    }

    private var statsRow: some View {
        let a = analytics
        return HStack(spacing: Theme.Space.sm) {
            stat("\(a.totalQuestions)", "questions")
            stat("\(a.monologueCount)", "monologues")
            stat("\(a.interruptions)", "interrupts*")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title2).weight(.bold)).foregroundStyle(Theme.accent)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .oatCard(padding: Theme.Space.sm)
    }

    private var coachingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Button { Task { await run { try await CoachingService().coach(transcript: meeting.transcriptText, notes: notes) } } } label: {
                        Label("Coaching", systemImage: "lightbulb")
                    }
                    .buttonStyle(OatSecondaryButton())
                    Button { Task { await run { try await CoachingService().score(framework: "BANT", transcript: meeting.transcriptText, notes: notes) } } } label: {
                        Text("Score: BANT")
                    }
                    .buttonStyle(OatSecondaryButton())
                    Button { Task { await run { try await CoachingService().score(framework: "MEDDIC", transcript: meeting.transcriptText, notes: notes) } } } label: {
                        Text("Score: MEDDIC")
                    }
                    .buttonStyle(OatSecondaryButton())
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                }
                if let coaching {
                    Divider().overlay(Theme.hairline)
                    MarkdownView(markdown: coaching)
                }
                Text("Interrupts are approximate (mic and meeting audio are captured as separate streams).")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Coaching", systemImage: "sparkles")
        }
        .alert("Couldn't analyze", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }

    private var notes: String {
        meeting.enhancedNotes.isEmpty ? (meeting.liveSummary?.text ?? meeting.notes) : meeting.enhancedNotes
    }

    private func run(_ op: @escaping () async throws -> String) async {
        working = true
        defer { working = false }
        do { coaching = try await op() } catch { self.error = error.localizedDescription }
    }

    private func percent(_ value: Double, of total: Double) -> String {
        guard total > 0 else { return "" }
        return "\(Int(value / total * 100))%"
    }
}
