import AppKit
import Observation
import Sparkle

/// Auto-updates via Sparkle. Checks the feed (SUFeedURL in Info.plist) once a day, verifies each
/// download against the public key (SUPublicEDKey), and installs on quit or when the user says so.
@MainActor @Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    var canCheck = false

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    private var observation: NSKeyValueObservation?

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // A menu bar app has no Dock icon to badge, so Sparkle should show scheduled update alerts
    // gently (without stealing focus) instead of warning that it can't.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
