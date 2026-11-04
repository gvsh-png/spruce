import AppKit
import Observation
import Sparkle

/// Auto-updates via Sparkle. Checks the feed (SUFeedURL in Info.plist) once a day, verifies each
/// download against the public key (SUPublicEDKey), and installs on quit or when the user says so.
@MainActor @Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    var canCheck = false

    // Stored copies, so SwiftUI sees changes; Sparkle keeps the real values in its own defaults.
    var automaticallyChecks = false {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    var automaticallyDownloads = false {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    private var observation: NSKeyValueObservation?

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// GitHub Pages caches the feed for up to 10 minutes; a parameter that changes on every check asks
    /// for the current file, so a check right after a release doesn't say "up to date".
    nonisolated func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        [["key": "t", "value": String(Int(Date().timeIntervalSince1970)), "displayKey": "t", "displayValue": "now"]]
    }

    /// Sparkle's alerts ("You're up to date", errors) block Spruce's menu until answered, so they must
    /// never open hidden behind other apps.
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in NSApp.activate() }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // A menu bar app has no Dock icon to badge, so Sparkle should show scheduled update alerts
    // gently (without stealing focus) instead of warning that it can't.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update found while you work in another app: bring Spruce forward once, so the
    /// update window isn't left hidden behind other windows.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        Task { @MainActor in NSApp.activate() }
    }
}
