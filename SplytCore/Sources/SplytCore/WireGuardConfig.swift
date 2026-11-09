import Foundation

/// A WireGuard configuration in the wg-quick format that WireGuard apps export.
///
/// Parsing checks everything Splyt can check without WireGuardKit, so a bad file
/// is rejected when it is imported rather than when the tunnel starts.
public struct WireGuardConfig: Equatable, Sendable {
    public struct Interface: Equatable, Sendable {
        public var privateKey: String
        public var addresses: [String] = []
        public var dns: [String] = []
        /// Non-address entries on the DNS line, which wg-quick treats as search domains.
        public var dnsSearch: [String] = []
        public var mtu: UInt16?
        public var listenPort: UInt16?
    }

    public struct Peer: Equatable, Sendable {
        public var publicKey: String
        public var presharedKey: String?
        public var endpoint: String?
        public var allowedIPs: [String] = []
        public var persistentKeepalive: UInt16?
    }

    public var interface: Interface
    public var peers: [Peer]
    /// Keys Splyt does not apply, such as wg-quick's PostUp scripts.
    public var ignoredKeys: [String]

    public enum ParseError: Error, Equatable, LocalizedError {
        case unknownSection(line: Int, String)
        case outsideSection(line: Int)
        case malformedLine(line: Int)
        case invalidValue(line: Int, key: String)
        case duplicateKey(line: Int, key: String)
        case missingInterface
        case missingPrivateKey
        case missingAddress
        case noPeers
        case missingPublicKey(peer: Int)

        public var errorDescription: String? {
            switch self {
            case .unknownSection(let line, let name):
                return "Line \(line): unknown section [\(name)]."
            case .outsideSection(let line):
                return "Line \(line) is outside an [Interface] or [Peer] section."
            case .malformedLine(let line):
                return "Line \(line) is not in the form Key = Value."
            case .invalidValue(let line, let key):
                return "Line \(line): \(key) has an invalid value."
            case .duplicateKey(let line, let key):
                return "Line \(line): \(key) appears twice in one section."
            case .missingInterface:
                return "The file has no [Interface] section."
            case .missingPrivateKey:
                return "The [Interface] section has no PrivateKey."
            case .missingAddress:
                return "The [Interface] section has no Address."
            case .noPeers:
                return "The file has no [Peer] section."
            case .missingPublicKey(let peer):
                return "Peer \(peer) has no PublicKey."
            }
        }
    }

    public init(interface: Interface, peers: [Peer], ignoredKeys: [String] = []) {
        self.interface = interface
        self.peers = peers
        self.ignoredKeys = ignoredKeys
    }

    public init(parsing text: String) throws {
        var interfaceValues: Values?
        var peerValues: [Values] = []
        var inInterface: Bool?
        var ignored: [String] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw ParseError.malformedLine(line: lineNumber)
                }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                switch name.lowercased() {
                case "interface" where interfaceValues == nil:
                    inInterface = true
                    interfaceValues = Values()
                case "peer":
                    inInterface = false
                    peerValues.append(Values())
                default:
                    throw ParseError.unknownSection(line: lineNumber, name)
                }
                continue
            }
            guard let inInterface else {
                throw ParseError.outsideSection(line: lineNumber)
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw ParseError.malformedLine(line: lineNumber)
            }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // A missing "=" can hide behind the padding that ends every base64 key.
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
                throw ParseError.malformedLine(line: lineNumber)
            }
            let key = name.lowercased()
            guard (inInterface ? Self.interfaceKeys : Self.peerKeys).contains(key) else {
                ignored.append(name)
                continue
            }
            if inInterface {
                try interfaceValues!.add(key, value, line: lineNumber)
            } else {
                try peerValues[peerValues.count - 1].add(key, value, line: lineNumber)
            }
        }

        guard let interfaceValues else {
            throw ParseError.missingInterface
        }
        interface = try Self.interface(from: interfaceValues)
        guard !peerValues.isEmpty else {
            throw ParseError.noPeers
        }
        peers = try peerValues.enumerated().map { try Self.peer(from: $1, number: $0 + 1) }
        ignoredKeys = ignored
    }

    /// One section's values with the line each came from, for error messages.
    private struct Values {
        private var entries: [String: (value: String, line: Int)] = [:]

        mutating func add(_ key: String, _ value: String, line: Int) throws {
            if let existing = entries[key] {
                // Lists may be split across repeated lines; single values may not.
                guard WireGuardConfig.listKeys.contains(key) else {
                    throw ParseError.duplicateKey(line: line, key: key)
                }
                entries[key] = (existing.value + "," + value, existing.line)
            } else {
                entries[key] = (value, line)
            }
        }

        subscript(key: String) -> String? {
            entries[key]?.value
        }

        func invalid(_ key: String, _ displayName: String) -> ParseError {
            .invalidValue(line: entries[key]?.line ?? 0, key: displayName)
        }
    }

    // MARK: - Fields

    private static let interfaceKeys: Set<String> = ["privatekey", "address", "dns", "mtu", "listenport"]
    private static let peerKeys: Set<String> = [
        "publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive",
    ]
    private static let listKeys: Set<String> = ["address", "dns", "allowedips"]

    private static func interface(from values: Values) throws -> Interface {
        guard let privateKey = values["privatekey"] else {
            throw ParseError.missingPrivateKey
        }
        guard isKey(privateKey) else {
            throw values.invalid("privatekey", "PrivateKey")
        }
        var interface = Interface(privateKey: privateKey)
        interface.addresses = list(values["address"])
        guard !interface.addresses.isEmpty else {
            throw ParseError.missingAddress
        }
        guard interface.addresses.allSatisfy(isAddressRange) else {
            throw values.invalid("address", "Address")
        }
        for entry in list(values["dns"]) {
            if isIPAddress(entry) {
                interface.dns.append(entry)
            } else {
                interface.dnsSearch.append(entry)
            }
        }
        if let mtu = values["mtu"] {
            guard let value = UInt16(mtu), value >= 576 else {
                throw values.invalid("mtu", "MTU")
            }
            interface.mtu = value
        }
        if let port = values["listenport"] {
            guard let value = UInt16(port) else {
                throw values.invalid("listenport", "ListenPort")
            }
            interface.listenPort = value
        }
        return interface
    }

    private static func peer(from values: Values, number: Int) throws -> Peer {
        guard let publicKey = values["publickey"] else {
            throw ParseError.missingPublicKey(peer: number)
        }
        guard isKey(publicKey) else {
            throw values.invalid("publickey", "PublicKey")
        }
        var peer = Peer(publicKey: publicKey)
        if let psk = values["presharedkey"] {
            guard isKey(psk) else {
                throw values.invalid("presharedkey", "PresharedKey")
            }
            peer.presharedKey = psk
        }
        if let endpoint = values["endpoint"] {
            guard parseEndpoint(endpoint) != nil else {
                throw values.invalid("endpoint", "Endpoint")
            }
            peer.endpoint = endpoint
        }
        peer.allowedIPs = list(values["allowedips"])
        guard peer.allowedIPs.allSatisfy(isAddressRange) else {
            throw values.invalid("allowedips", "AllowedIPs")
        }
        if let keepalive = values["persistentkeepalive"] {
            if keepalive.lowercased() != "off" {
                guard let value = UInt16(keepalive) else {
                    throw values.invalid("persistentkeepalive", "PersistentKeepalive")
                }
                peer.persistentKeepalive = value == 0 ? nil : value
            }
        }
        return peer
    }

    private static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Validation

    /// A WireGuard key: 32 bytes in base64.
    public static func isKey(_ value: String) -> Bool {
        value.count == 44 && Data(base64Encoded: value)?.count == 32
    }

    public static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }

    /// An address with an optional prefix length, such as 10.0.0.2/32.
    public static func isAddressRange(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let address = parts.first.map(String.init), isIPAddress(address) else {
            return false
        }
        guard parts.count == 2 else {
            return true
        }
        let maximum = address.contains(":") ? 128 : 32
        guard let prefix = Int(parts[1]), (0...maximum).contains(prefix) else {
            return false
        }
        return true
    }

    /// Splits host:port, accepting [v6]:port. Returns nil when either part is missing.
    public static func parseEndpoint(_ value: String) -> (host: String, port: UInt16)? {
        let host: Substring
        let portText: Substring
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"),
                  value[value.index(after: close)...].hasPrefix(":") else {
                return nil
            }
            host = value[value.index(after: value.startIndex)..<close]
            portText = value[value.index(close, offsetBy: 2)...]
        } else {
            guard let colon = value.lastIndex(of: ":") else {
                return nil
            }
            host = value[..<colon]
            portText = value[value.index(after: colon)...]
            // An unbracketed IPv6 address is ambiguous.
            guard !host.contains(":") else {
                return nil
            }
        }
        guard !host.isEmpty, let port = UInt16(portText), port > 0 else {
            return nil
        }
        return (String(host), port)
    }

    // MARK: - Summary

    /// Everything about the tunnel that is safe to show and store outside the keychain.
    public func summary(id: String, name: String) -> WireGuardTunnelInfo {
        let allowed = peers.flatMap(\.allowedIPs)
        return WireGuardTunnelInfo(
            id: id,
            name: name,
            endpoint: peers.first?.endpoint,
            addresses: interface.addresses,
            routesAllTraffic: allowed.contains("0.0.0.0/0") || allowed.contains("::/0")
        )
    }
}

/// The non-secret description of an imported tunnel. It is stored in the system's
/// VPN configuration, which any local user can read, so it never holds keys.
public struct WireGuardTunnelInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var endpoint: String?
    public var addresses: [String]
    public var routesAllTraffic: Bool

    public init(id: String, name: String, endpoint: String?, addresses: [String], routesAllTraffic: Bool) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.addresses = addresses
        self.routesAllTraffic = routesAllTraffic
    }
}

/// Live counters from the running tunnel, read from WireGuard's UAPI output.
public struct WireGuardStats: Codable, Equatable, Sendable {
    public var lastHandshake: Date?
    public var received: UInt64
    public var sent: UInt64

    public init(lastHandshake: Date?, received: UInt64, sent: UInt64) {
        self.lastHandshake = lastHandshake
        self.received = received
        self.sent = sent
    }

    /// Sums every peer. The newest handshake of any peer wins.
    public init(uapi: String) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var newest: TimeInterval = 0
        var seconds: TimeInterval = 0
        for line in uapi.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }
            switch parts[0] {
            case "rx_bytes":
                received += UInt64(parts[1]) ?? 0
            case "tx_bytes":
                sent += UInt64(parts[1]) ?? 0
            case "last_handshake_time_sec":
                seconds = TimeInterval(parts[1]) ?? 0
            case "last_handshake_time_nsec":
                let time = seconds + (TimeInterval(parts[1]) ?? 0) / 1_000_000_000
                newest = max(newest, time)
            default:
                break
            }
        }
        self.init(
            lastHandshake: newest > 0 ? Date(timeIntervalSince1970: newest) : nil,
            received: received, sent: sent
        )
    }
}
