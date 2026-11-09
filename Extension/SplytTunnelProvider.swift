import Foundation
import Network
import NetworkExtension
import OSLog
import SplytCore
import WireGuardKit

/// Runs an imported WireGuard tunnel, so no separate WireGuard app is needed.
///
/// The tunnel takes the default route like any full-tunnel VPN, and the transparent
/// proxy in this same extension splits traffic around it. If this process dies,
/// macOS removes the tunnel's routes, so VPN apps lose the network rather than
/// leaking; on-demand then restarts the extension.
final class SplytTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.amplify2.splyt", category: "wireguard")

    private lazy var adapter = WireGuardAdapter(with: self) { [log] level, message in
        switch level {
        case .error:
            log.error("\(message, privacy: .public)")
        case .verbose:
            log.debug("\(message, privacy: .public)")
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            let info = try tunnelInfo()
            // The app passes the configuration when the user connects. Starts by
            // on-demand, for example after a reboot, use the copy saved then.
            let text: String
            if let fresh = options?[SplytConstants.tunnelConfigOption] as? String {
                text = fresh
                try ConfigCache.save(text, id: info.id)
            } else {
                text = try ConfigCache.load(id: info.id)
            }
            let config = try WireGuardConfig(parsing: text)
            let configuration = try Self.tunnelConfiguration(config, name: info.name)
            let routes = config.peers.flatMap(\.allowedIPs).compactMap(IPRange.init)
            log.info("Starting WireGuard tunnel \(info.name, privacy: .public)")
            adapter.start(tunnelConfiguration: configuration) { [log, adapter] error in
                if let error {
                    log.error("WireGuard did not start: \(String(describing: error), privacy: .public)")
                    completionHandler(TunnelError.adapter(String(describing: error)))
                    return
                }
                // The proxy in this process cannot see this tunnel by probing
                // routes, so it is told which interface and routes it has.
                if let name = adapter.interfaceName {
                    Egress.setLocalTunnel(Egress.LocalTunnel(name: name, routes: routes))
                    log.info("WireGuard tunnel up on \(name, privacy: .public)")
                } else {
                    log.error("WireGuard tunnel up, but its interface name is unknown")
                }
                completionHandler(nil)
            }
        } catch {
            log.error("WireGuard did not start: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("Stopping WireGuard tunnel, reason \(reason.rawValue)")
        if reason == .configurationRemoved, let info = try? tunnelInfo() {
            ConfigCache.remove(id: info.id)
        }
        Egress.setLocalTunnel(nil)
        adapter.stop { _ in
            completionHandler()
        }
    }

    /// Any message gets the tunnel's counters back.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        adapter.getRuntimeConfiguration { uapi in
            guard let uapi else {
                completionHandler?(nil)
                return
            }
            completionHandler?(try? JSONEncoder().encode(WireGuardStats(uapi: uapi)))
        }
    }

    // MARK: - Configuration

    private func tunnelInfo() throws -> WireGuardTunnelInfo {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?[SplytConstants.tunnelInfoKey] as? Data,
              let info = try? JSONDecoder().decode(WireGuardTunnelInfo.self, from: data) else {
            throw TunnelError.missingConfiguration
        }
        return info
    }

    private static func tunnelConfiguration(_ config: WireGuardConfig, name: String) throws -> TunnelConfiguration {
        guard let privateKey = PrivateKey(base64Key: config.interface.privateKey) else {
            throw TunnelError.invalid("PrivateKey")
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = try config.interface.addresses.map {
            guard let range = IPAddressRange(from: $0) else {
                throw TunnelError.invalid("Address \($0)")
            }
            return range
        }
        interface.dns = try config.interface.dns.map {
            guard let server = DNSServer(from: $0) else {
                throw TunnelError.invalid("DNS \($0)")
            }
            return server
        }
        interface.dnsSearch = config.interface.dnsSearch
        interface.mtu = config.interface.mtu
        interface.listenPort = config.interface.listenPort

        let peers = try config.peers.map { entry -> PeerConfiguration in
            guard let publicKey = PublicKey(base64Key: entry.publicKey) else {
                throw TunnelError.invalid("PublicKey")
            }
            var peer = PeerConfiguration(publicKey: publicKey)
            if let psk = entry.presharedKey {
                guard let key = PreSharedKey(base64Key: psk) else {
                    throw TunnelError.invalid("PresharedKey")
                }
                peer.preSharedKey = key
            }
            if let text = entry.endpoint {
                guard let endpoint = Endpoint(from: text) else {
                    throw TunnelError.invalid("Endpoint \(text)")
                }
                peer.endpoint = endpoint
            }
            peer.allowedIPs = try entry.allowedIPs.map {
                guard let range = IPAddressRange(from: $0) else {
                    throw TunnelError.invalid("AllowedIPs \($0)")
                }
                return range
            }
            peer.persistentKeepAlive = entry.persistentKeepalive
            return peer
        }
        return TunnelConfiguration(name: name, interface: interface, peers: peers)
    }

    enum TunnelError: LocalizedError {
        case missingConfiguration
        case invalid(String)
        case adapter(String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "The tunnel has no configuration. Import it again in Splyt."
            case .invalid(let field):
                return "The tunnel configuration has an invalid \(field)."
            case .adapter(let detail):
                return "WireGuard could not start: \(detail)"
            }
        }
    }
}

/// Keeps each tunnel's configuration, including its private key, where only root
/// can read it: this extension's sandbox container. The system's VPN preferences
/// file is readable by every local user, so the key is never stored there.
private enum ConfigCache {
    static func save(_ text: String, id: String) throws {
        let directory = try directoryURL()
        let url = directory.appendingPathComponent(fileName(id))
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(id: String) throws -> String {
        let url = try directoryURL().appendingPathComponent(fileName(id))
        guard let data = try? Data(contentsOf: url) else {
            throw SplytTunnelProvider.TunnelError.missingConfiguration
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func remove(id: String) {
        guard let url = try? directoryURL().appendingPathComponent(fileName(id)) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileName(_ id: String) -> String {
        // Tunnel IDs are UUIDs; anything else must not escape the directory.
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(safe).conf"
    }

    private static func directoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("WireGuard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
