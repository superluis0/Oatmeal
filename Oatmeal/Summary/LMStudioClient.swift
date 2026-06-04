import Foundation

struct LMStudioMessage {
    let role: String  // "system" | "user" | "assistant"
    let content: String

    static func system(_ c: String) -> LMStudioMessage { .init(role: "system", content: c) }
    static func user(_ c: String) -> LMStudioMessage { .init(role: "user", content: c) }
    static func assistant(_ c: String) -> LMStudioMessage { .init(role: "assistant", content: c) }
}

enum LMStudioError: LocalizedError {
    case serverUnreachable
    case noModelLoaded
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable:
            return "Couldn't reach LM Studio at \(AppSettings.baseURL). Open LM Studio, start the local server, and load a model."
        case .noModelLoaded:
            return "LM Studio is running but no model is loaded. Load a model in LM Studio (or set one in Settings)."
        case .badResponse(let m):
            return "Unexpected response from LM Studio: \(m)"
        }
    }
}

/// Thin reusable client for a local LM Studio server (OpenAI-compatible API).
/// The single place that knows the LM Studio wire format and error handling.
struct LMStudioClient {
    var baseURL: String = AppSettings.baseURL
    var explicitModel: String = AppSettings.model

    /// Sends a chat completion and returns the assistant message content.
    func chat(messages: [LMStudioMessage], temperature: Double = 0.3) async throws -> String {
        let model = try await resolveModel()
        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": false
        ]
        return try await postChatCompletion(payload)
    }

    /// IDs of currently loaded models.
    func listModels() async throws -> [String] {
        let url = try makeURL("/v1/models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LMStudioError.serverUnreachable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LMStudioError.serverUnreachable
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw LMStudioError.noModelLoaded
        }
        return arr.compactMap { $0["id"] as? String }
    }

    // MARK: - Internals

    private func makeURL(_ path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + path) else {
            throw LMStudioError.badResponse("Invalid base URL")
        }
        return url
    }

    private func resolveModel() async throws -> String {
        let explicit = explicitModel.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return explicit }
        guard let first = try await listModels().first else {
            throw LMStudioError.noModelLoaded
        }
        return first
    }

    private func postChatCompletion(_ payload: [String: Any]) async throws -> String {
        let url = try makeURL("/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LMStudioError.serverUnreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LMStudioError.badResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LMStudioError.badResponse("HTTP \(http.statusCode): \(body)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LMStudioError.badResponse("Missing choices/content")
        }
        return content
    }
}
