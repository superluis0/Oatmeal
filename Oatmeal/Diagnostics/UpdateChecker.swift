import Foundation

/// Checks the public GitHub repo for a newer published Release, so people who
/// installed Oatmeal from source can tell when there's an update.
///
/// Privacy: this is the ONLY non-local network call in the app besides the
/// one-time model download and your own LM Studio server. It contacts
/// api.github.com at most once per day, can be turned off in Settings, and sends
/// no data about you — just an anonymous GET for the latest release tag.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable { let version: String; let url: URL }

    /// Non-nil when a release newer than the running build is available.
    var available: Release?
    var isChecking = false

    private let repo = "superluis0/Oatmeal"
    private let lastCheckKey = "updateLastCheckAt"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Throttled check used on launch (skips if checked within the last day).
    func checkIfDue() async {
        guard AppSettings.checkForUpdates else { return }
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 86_400 {
            return
        }
        await check()
    }

    /// Forces a check now (Settings → "Check now").
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let urlStr = (obj["html_url"] as? String) ?? "https://github.com/\(repo)/releases"
            if Self.isNewer(remote, than: currentVersion), let releaseURL = URL(string: urlStr) {
                available = Release(version: remote, url: releaseURL)
                Log.info("update available: \(remote) (current \(currentVersion))", "update")
            } else {
                available = nil
            }
        } catch {
            // Offline, rate-limited, or no releases yet — stay silent.
        }
    }

    /// Semver-ish comparison: true when `a` is a newer version than `b`.
    /// Compares dotted numeric components, ignoring any pre-release suffix.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { comp in
                Int(comp.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
