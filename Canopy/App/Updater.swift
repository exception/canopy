import AppKit
import Sparkle

/// Self-updates via Sparkle. The feed (SUFeedURL) is the appcast.xml attached to the latest
/// GitHub release; downloads are verified against SUPublicEDKey. Both live in Resources/Info.plist,
/// and scripts/release.sh builds, signs and writes the appcast.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    private var started: Bool

    private init() {
        // Debug builds run from DerivedData: never check on their own (an update would replace
        // the dev build), and never when automation drives an isolated instance. The menu item still works.
        #if DEBUG
        let start = false
        #else
        let start = ProcessInfo.processInfo.environment["CANOPY_CONTROL_PORT"] == nil
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        started = start
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        if !started { controller.startUpdater(); started = true }
        controller.checkForUpdates(nil)
    }

    /// Touching `shared` at launch creates the controller so scheduled checks run.
    func start() {}
}
