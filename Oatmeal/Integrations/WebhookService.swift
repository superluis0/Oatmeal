import Foundation

/// Posts a finished meeting's summary to an optional user-configured webhook
/// (e.g. a Slack incoming webhook). No-op unless a URL is set. Opt-in only — the
/// default install never makes outbound calls.
struct WebhookService {
    func postIfConfigured(title: String, summary: String, actionItems: [String]) async {
        let urlString = AppSettings.webhookURL.trimmingCharacters(in: .whitespaces)
        // Only http(s) with a real host — blocks file://, ftp://, data:, etc. so a
        // crafted webhook value can't read local files or hit non-web schemes.
        guard !urlString.isEmpty, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return }

        let actionsText = actionItems.isEmpty ? "" : "\n\nAction items:\n" + actionItems.map { "• \($0)" }.joined(separator: "\n")
        let payload: [String: Any] = [
            "title": title,
            "summary": summary,
            "actionItems": actionItems,
            // Slack-compatible field.
            "text": "*\(title)*\n\(summary)\(actionsText)"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: request)
    }
}
