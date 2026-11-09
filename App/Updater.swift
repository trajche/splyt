import AppKit
import Observation
import Sparkle

/// Updates Splyt from GitHub releases with Sparkle.
///
/// The feed is the `appcast.xml` attached to the latest release, so no separate
/// server is needed. Sparkle checks each update's EdDSA signature against
/// `SUPublicEDKey` in Info.plist and its Developer ID signature against this app's.
/// A new build replaces the system extension on its first launch, as any update does.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// Set while a scheduled check has found an update the user has not looked at.
    private(set) var availableVersion: String?
    private(set) var automaticallyChecks = false
    private(set) var automaticallyInstalls = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
        )
        self.controller = controller
        // A build without a public key cannot verify updates, so it never checks.
        if Self.isConfigured {
            controller.startUpdater()
        }
        refresh()
    }

    static var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return key?.isEmpty == false
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var canCheck: Bool {
        Self.isConfigured && controller?.updater.canCheckForUpdates == true
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    private func refresh() {
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        automaticallyInstalls = controller?.updater.automaticallyDownloadsUpdates ?? false
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Splyt lives in the menu bar, so a scheduled check must not steal focus. Sparkle
    // shows its window without activating the app, and the menu shows the update.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            availableVersion = userInitiated ? nil : version
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            availableVersion = nil
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            availableVersion = nil
        }
    }
}
