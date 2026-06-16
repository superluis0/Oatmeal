import Foundation
import Sparkle

/// Drives in-app updates via **Sparkle** (the macOS auto-updater). Sparkle fetches
/// a signed *appcast* over HTTPS, and — on Oatmeal's self-signed distribution
/// path — verifies each update with an **EdDSA signature** before installing it
/// in place and relaunching. The result is one-click "Install Update".
///
/// This type keeps the small `@Observable` surface the UI binds to (the sidebar
/// "Update" pill and Settings → Updates) and forwards the heavy lifting to
/// Sparkle's standard updater + user driver (the "A new version is available"
/// dialog). A tiny `NSObject` bridge ([SparkleBridge]) adapts Sparkle's `@objc`
/// delegate callbacks to this `@MainActor @Observable` object.
///
/// Privacy: the only network call here is Sparkle fetching the appcast
/// (`SUFeedURL`) to compare versions — the same occasional update check Oatmeal
/// has always done, now able to install with one click. No data about you is sent;
/// turn it off in Settings to keep Oatmeal fully offline.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable { let version: String }

    /// Non-nil once Sparkle has found a newer release (drives the pill + Settings).
    var available: Release?
    /// True while a user-initiated check is in flight (drives the "Checking…" label).
    var isChecking = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var bridge: SparkleBridge?

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Create and start Sparkle's updater. Idempotent; call early in app launch.
    func startUpdater() {
        guard controller == nil else { return }
        let bridge = SparkleBridge(owner: self)
        self.bridge = bridge   // retain — SPUStandardUpdaterController holds the delegate weakly
        // `userDriverDelegate: bridge` enables Sparkle's "gentle reminders": instead
        // of auto-popping its modal on a background check, Sparkle lets us surface
        // the update ourselves (the in-app banner + sidebar pill, driven by
        // `available`). The user still installs through Sparkle's standard dialog,
        // reached via `checkForUpdates()` from the banner.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: bridge, userDriverDelegate: bridge)
        controller?.updater.automaticallyChecksForUpdates = AppSettings.checkForUpdates
    }

    /// User-initiated check — shows Sparkle's standard "Install Update" UI.
    /// The sidebar pill and Settings "Check now" call this.
    func checkForUpdates() {
        startUpdater()
        isChecking = true
        controller?.updater.checkForUpdates()
    }

    /// Silent, throttled launch check. Sparkle owns the once-per-interval
    /// scheduling; if it finds an update it lights up `available` and (via the
    /// standard user driver) offers to install. No-op when the user has turned
    /// updates off.
    func checkIfDue() {
        startUpdater()
        guard AppSettings.checkForUpdates else { return }
        controller?.updater.checkForUpdatesInBackground()
    }

    /// Reflect the Settings toggle into Sparkle's scheduler and persist it.
    func setAutomaticChecks(_ on: Bool) {
        startUpdater()
        AppSettings.checkForUpdates = on
        controller?.updater.automaticallyChecksForUpdates = on
    }

    // MARK: - Sparkle callbacks (forwarded from the NSObject bridge, on the main thread)

    fileprivate func didFind(_ item: SUAppcastItem) {
        available = Release(version: item.displayVersionString)
    }
    fileprivate func didNotFindUpdate() { available = nil }
    fileprivate func cycleFinished() { isChecking = false }
}

/// Bridges Sparkle's `@objc SPUUpdaterDelegate` to the `@Observable @MainActor`
/// `UpdateChecker`. Sparkle invokes delegate methods on the main thread, so
/// `MainActor.assumeIsolated` is safe here.
private final class SparkleBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private weak var owner: UpdateChecker?
    init(owner: UpdateChecker) { self.owner = owner }

    // MARK: SPUUpdaterDelegate
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { owner?.didFind(item) }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { owner?.didNotFindUpdate() }
    }
    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        MainActor.assumeIsolated { owner?.cycleFinished() }
    }

    // MARK: SPUStandardUserDriverDelegate — gentle reminders
    // We show updates with our own in-app banner (see ContentView's UpdateBanner),
    // so tell Sparkle not to auto-present its modal alert on scheduled/background
    // checks. `available` is set in `didFindValidUpdate` above, which is what the
    // banner + pill bind to; the user installs via "Update Now" → `checkForUpdates()`
    // (user-initiated, which always shows Sparkle's standard install dialog — this
    // method is never consulted for user-initiated checks, so updates can't be
    // blocked).
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }
}
