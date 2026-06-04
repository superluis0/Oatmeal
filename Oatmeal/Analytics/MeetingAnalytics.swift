import Foundation

struct SpeakerStat: Identifiable {
    var id: String { name }
    let name: String
    var seconds: Double
    var questions: Int
    var segments: Int
}

/// Local, on-device conversation analytics derived from diarized segments.
struct MeetingAnalytics {
    var speakers: [SpeakerStat]
    var totalSeconds: Double
    var totalQuestions: Int
    var monologueCount: Int
    var longestMonologue: Double
    var monologueSpeaker: String?
    var interruptions: Int

    struct Seg { let name: String; let start: Double; let end: Double; let text: String }

    static func compute(_ segs: [Seg],
                        monologueThreshold: Double = 60,
                        monologueMaxGap: Double = 8,
                        interruptGap: Double = 0.4) -> MeetingAnalytics {
        var byName: [String: SpeakerStat] = [:]
        for s in segs {
            var stat = byName[s.name] ?? SpeakerStat(name: s.name, seconds: 0, questions: 0, segments: 0)
            stat.seconds += max(0, s.end - s.start)
            if s.text.contains("?") { stat.questions += 1 }
            stat.segments += 1
            byName[s.name] = stat
        }
        let speakers = byName.values.sorted { $0.seconds > $1.seconds }
        let total = speakers.reduce(0) { $0 + $1.seconds }
        let totalQ = speakers.reduce(0) { $0 + $1.questions }

        let ordered = segs.sorted { $0.start < $1.start }

        // Monologues: contiguous same-speaker spans longer than the threshold.
        var monoCount = 0, longest = 0.0
        var monoSpeaker: String?
        var i = 0
        while i < ordered.count {
            var j = i
            let name = ordered[i].name
            let spanStart = ordered[i].start
            var spanEnd = ordered[i].end
            // Extend the span only while the same speaker continues without a long
            // silence — otherwise two far-apart turns by one speaker would count as
            // one giant monologue across the gap.
            while j + 1 < ordered.count && ordered[j + 1].name == name
                && ordered[j + 1].start - spanEnd <= monologueMaxGap {
                j += 1; spanEnd = ordered[j].end
            }
            let dur = spanEnd - spanStart
            if dur >= monologueThreshold {
                monoCount += 1
                if dur > longest { longest = dur; monoSpeaker = name }
            }
            i = j + 1
        }

        // Interruptions (approximate — mic/system are separate streams): a speaker
        // change with a near-zero or negative gap between turns.
        var interruptions = 0
        if ordered.count > 1 {
            for k in 1..<ordered.count where ordered[k].name != ordered[k - 1].name {
                if ordered[k].start - ordered[k - 1].end < interruptGap { interruptions += 1 }
            }
        }

        return MeetingAnalytics(
            speakers: speakers, totalSeconds: total, totalQuestions: totalQ,
            monologueCount: monoCount, longestMonologue: longest,
            monologueSpeaker: monoSpeaker, interruptions: interruptions
        )
    }
}
