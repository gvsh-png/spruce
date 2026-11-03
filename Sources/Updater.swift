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
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
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

    /// A scheduled update found while you work in another app: bring Spruce forward once, so the
    /// update window isn't left hidden behind other windows.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
