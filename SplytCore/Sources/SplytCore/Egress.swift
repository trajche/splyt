import Darwin
import Foundation
import Network
import Synchronization

/// Asks the kernel's routing table where traffic would go.
///
/// Connecting a UDP socket performs a route lookup and sends nothing, so this
/// needs no privileges, works inside the sandbox, and is cheap enough to run per
/// flow. Because the lookup uses the real destination it stays correct for
/// full-tunnel VPNs, partial-tunnel VPNs, and VPNs that go up or down at any time.
public enum Egress {
    /// Probed when a flow has no numeric address. Any public address will do.
    public static let probeAddress = "1.1.1.1"

    /// Name of the interface the kernel would use to reach `address`.
    public static func interface(to address: String) -> String? {
        let probed = sourceAddress(to: address).flatMap(interfaceName(owning:))
        if let probed, isTunnel(probed) {
            return probed
        }
        // Splyt's own WireGuard tunnel runs in this process, and macOS keeps a
        // tunnel provider's sockets out of its own tunnel, so the probe above
        // cannot see it. Other processes' traffic does use it.
        if let local = localTunnel.withLock({ $0 }), local.carries(address) {
            return local.name
        }
        return probed
    }

    /// A tunnel served by this process, which `interface(to:)` cannot probe.
    public struct LocalTunnel: Sendable {
        public var name: String
        public var routes: [IPRange]

        public init(name: String, routes: [IPRange]) {
            self.name = name
            self.routes = routes
        }

        public func carries(_ address: String) -> Bool {
            routes.contains { $0.contains(address) }
        }
    }

    private static let localTunnel = Mutex<LocalTunnel?>(nil)

    /// Set while this process serves a tunnel, nil once it stops.
    public static func setLocalTunnel(_ tunnel: LocalTunnel?) {
        localTunnel.withLock { $0 = tunnel }
    }

    /// Whether traffic to `address` would enter a tunnel. `nil` probes the default route.
    public static func routesViaVPN(to address: String?) -> Bool {
        guard let name = interface(to: address ?? probeAddress) else {
            return false
        }
        return isTunnel(name)
    }

    /// Numeric addresses for `host` from the system resolver. This blocks.
    public static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0 else {
            return []
        }
        defer { freeaddrinfo(head) }
        var addresses: [String] = []
        var cursor = head
        while let entry = cursor?.pointee {
            cursor = entry.ai_next
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                entry.ai_addr, entry.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST
            ) == 0 {
                let address = String(cString: name)
                if !addresses.contains(address) {
                    addresses.append(address)
                }
            }
        }
        return addresses
    }

    public static func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { name.hasPrefix($0) }
    }

    private enum IPBytes: Equatable {
        case v4(in_addr_t)
        case v6([UInt8])
    }

    private static func sourceAddress(to address: String) -> IPBytes? {
        if let v4 = IPv4Address(address) {
            var remote = sockaddr_in()
            remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            remote.sin_family = sa_family_t(AF_INET)
            remote.sin_port = in_port_t(53).bigEndian
            v4.rawValue.withUnsafeBytes { bytes in
                withUnsafeMutableBytes(of: &remote.sin_addr) { $0.copyMemory(from: bytes) }
            }
            var local = sockaddr_in()
            guard probe(family: AF_INET, remote: &remote, local: &local) else {
                return nil
            }
            return .v4(local.sin_addr.s_addr)
        }
        if let v6 = IPv6Address(address) {
            var remote = sockaddr_in6()
            remote.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            remote.sin6_family = sa_family_t(AF_INET6)
            remote.sin6_port = in_port_t(53).bigEndian
            v6.rawValue.withUnsafeBytes { bytes in
                withUnsafeMutableBytes(of: &remote.sin6_addr) { $0.copyMemory(from: bytes) }
            }
            var local = sockaddr_in6()
            guard probe(family: AF_INET6, remote: &remote, local: &local) else {
                return nil
            }
            return .v6(withUnsafeBytes(of: local.sin6_addr) { Array($0) })
        }
        return nil
    }

    private static func probe<Address>(family: Int32, remote: inout Address, local: inout Address) -> Bool {
        let fd = socket(family, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<Address>.size)
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else {
            return false
        }
        var length = size
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return named == 0
    }

    private static func interfaceName(owning source: IPBytes) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            return nil
        }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let raw = entry.ifa_addr else {
                continue
            }
            let candidate: IPBytes?
            switch Int32(raw.pointee.sa_family) {
            case AF_INET:
                candidate = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    .v4($0.pointee.sin_addr.s_addr)
                }
            case AF_INET6:
                candidate = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    .v6(withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) })
                }
            default:
                candidate = nil
            }
            if candidate == source {
                return String(cString: entry.ifa_name)
            }
        }
        return nil
    }
}

/// Tracks the physical interface that Direct traffic is pinned to.
public final class PhysicalInterfaceMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cached: NWInterface?
    private var available: [NWInterface] = []

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: DispatchQueue(label: "com.amplify2.splyt.path"))
    }

    deinit {
        monitor.cancel()
    }

    public var current: NWInterface? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// An interface by name, such as the tunnel carrying a route.
    public func interface(named name: String) -> NWInterface? {
        lock.lock()
        defer { lock.unlock() }
        return available.first { $0.name == name }
    }

    private func update(_ path: NWPath) {
        let interface = Self.physical(from: path.availableInterfaces)
        lock.lock()
        cached = interface
        available = path.availableInterfaces
        lock.unlock()
    }

    /// System order is preference order, so the first physical interface wins.
    public static func physical(from interfaces: [NWInterface]) -> NWInterface? {
        interfaces.first { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
    }
}
