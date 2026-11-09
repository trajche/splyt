import Foundation
import NetworkExtension
import Security
import SplytCore

/// Imported WireGuard tunnels. Each is a packet tunnel configuration served by the
/// Splyt extension. Its private key lives in the login keychain, never in the
/// system VPN preferences, which every local user can read.
@MainActor
final class TunnelController {
    struct Tunnel: Identifiable {
        let info: WireGuardTunnelInfo
        fileprivate let manager: NETunnelProviderManager

        var id: String { info.id }
        var status: NEVPNStatus { manager.connection.status }
        var connectedDate: Date? { manager.connection.connectedDate }
    }

    enum TunnelError: LocalizedError {
        case notFound
        case missingKey(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "That tunnel no longer exists."
            case .missingKey(let name):
                return "The keys for \(name) are missing from the keychain. Remove the tunnel and import it again."
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Keychain: \(detail)"
            }
        }
    }

    private(set) var tunnels: [Tunnel] = []
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private static let connectTimeout: Duration = .seconds(20)

    func load() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        tunnels = managers.compactMap { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  proto.providerBundleIdentifier == SplytConstants.extensionBundleID,
                  let data = proto.providerConfiguration?[SplytConstants.tunnelInfoKey] as? Data,
                  let info = try? JSONDecoder().decode(WireGuardTunnelInfo.self, from: data) else {
                return nil
            }
            return Tunnel(info: info, manager: manager)
        }
        .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
        observe()
        onChange?()
        // A tunnel started outside Splyt, or by an older build, keeps running
        // only until the next sleep or update without on-demand.
        for tunnel in tunnels where tunnel.status == .connected && !tunnel.manager.isOnDemandEnabled {
            tunnel.manager.isOnDemandEnabled = true
            tunnel.manager.onDemandRules = [NEOnDemandRuleConnect()]
            try await tunnel.manager.saveToPreferences()
        }
    }

    /// Validates and saves a wg-quick configuration. Returns keys Splyt ignores.
    func add(text: String, name: String) async throws -> [String] {
        let config = try WireGuardConfig(parsing: text)
        let info = config.summary(id: UUID().uuidString, name: name)
        try Keychain.save(text, account: info.id)

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = SplytConstants.extensionBundleID
        proto.serverAddress = info.endpoint ?? "WireGuard"
        proto.providerConfiguration = [SplytConstants.tunnelInfoKey: try JSONEncoder().encode(info)]
        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = proto
        manager.localizedDescription = name
        manager.isEnabled = false
        do {
            try await manager.saveToPreferences()
        } catch {
            Keychain.delete(account: info.id)
            throw error
        }
        try await load()
        return config.ignoredKeys
    }

    /// Connects one tunnel and disconnects any other, since two full tunnels would
    /// fight over the default route.
    func connect(_ id: String) async throws {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else {
            throw TunnelError.notFound
        }
        for other in tunnels where other.id != id && other.status != .disconnected && other.status != .invalid {
            try await disconnect(other.id)
        }
        guard let text = Keychain.load(account: id) else {
            throw TunnelError.missingKey(tunnel.info.name)
        }
        let manager = tunnel.manager
        // On-demand stays off until the first start, which carries the keys; an
        // on-demand start before that would find nothing saved in the extension.
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        guard let session = manager.connection as? NETunnelProviderSession else {
            return
        }
        try session.startTunnel(options: [SplytConstants.tunnelConfigOption: text as NSString])

        // The extension has saved the keys once the tunnel is up, so on-demand can
        // now restart it after sleep, a reboot or an extension update.
        // Right after the request the status can still read disconnected, so only
        // a disconnect after a short grace period counts as a failed start.
        let started = ContinuousClock.now
        while session.status != .connected {
            let elapsed = ContinuousClock.now - started
            if elapsed > Self.connectTimeout || (elapsed > .seconds(2) && session.status == .disconnected) {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        manager.isOnDemandEnabled = true
        manager.onDemandRules = [NEOnDemandRuleConnect()]
        try await manager.saveToPreferences()
    }

    func disconnect(_ id: String) async throws {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else {
            throw TunnelError.notFound
        }
        if tunnel.manager.isOnDemandEnabled {
            tunnel.manager.isOnDemandEnabled = false
            try await tunnel.manager.saveToPreferences()
        }
        tunnel.manager.connection.stopVPNTunnel()
    }

    func remove(_ id: String) async throws {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else {
            return
        }
        tunnel.manager.connection.stopVPNTunnel()
        try await tunnel.manager.removeFromPreferences()
        Keychain.delete(account: id)
        try await load()
    }

    func stats(_ id: String) async -> WireGuardStats? {
        guard let tunnel = tunnels.first(where: { $0.id == id }),
              tunnel.status == .connected,
              let session = tunnel.manager.connection as? NETunnelProviderSession else {
            return nil
        }
        let data: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data()) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        return data.flatMap { try? JSONDecoder().decode(WireGuardStats.self, from: $0) }
    }

    private func observe() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = tunnels.map { tunnel in
            NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange, object: tunnel.manager.connection, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onChange?()
                }
            }
        }
    }
}

/// Generic passwords in the login keychain, readable only by Splyt.
private enum Keychain {
    static let service = "com.amplify2.splyt.wireguard"

    static func save(_ text: String, account: String) throws {
        delete(account: account)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "Splyt WireGuard tunnel",
            kSecValueData: Data(text.utf8),
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TunnelController.TunnelError.keychain(status)
        }
    }

    static func load(account: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}
