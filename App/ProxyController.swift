import Foundation
import NetworkExtension
import SplytCore

/// Wraps the system's transparent proxy configuration and the running session.
@MainActor
final class ProxyController {
    private var manager: NETransparentProxyManager?
    private var observer: NSObjectProtocol?

    var onStatusChange: ((NEVPNStatus) -> Void)?

    var hasConfiguration: Bool {
        manager != nil
    }

    var status: NEVPNStatus {
        manager?.connection.status ?? .invalid
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Picks up a configuration saved by an earlier launch.
    func load() async throws {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        if let existing = managers.first {
            adopt(existing)
        }
    }

    /// Saves the configuration. On-demand keeps the proxy running across reboots
    /// whether or not the app is open, so rules and the kill switch stay in force.
    func save(config: SplytConfig, enabled: Bool) async throws {
        let manager = self.manager ?? NETransparentProxyManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = SplytConstants.extensionBundleID
        proto.serverAddress = "Splyt"
        proto.providerConfiguration = [SplytConstants.configKey: try JSONEncoder().encode(config)]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Splyt"
        manager.isEnabled = enabled
        manager.isOnDemandEnabled = enabled
        manager.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : nil
        try await manager.saveToPreferences()
        // The system requires a reload before a freshly saved manager can start.
        try await manager.loadFromPreferences()
        adopt(manager)
    }

    func start() throws {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return
        }
        try session.startTunnel(options: nil)
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func remove() async throws {
        try await manager?.removeFromPreferences()
        manager = nil
    }

    /// Sends a request to the running extension. Returns nil when it is not running.
    func send(_ request: ProviderRequest) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected,
              let message = try? JSONEncoder().encode(request) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func adopt(_ manager: NETransparentProxyManager) {
        self.manager = manager
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.onStatusChange?(self.status)
            }
        }
        onStatusChange?(status)
    }
}
