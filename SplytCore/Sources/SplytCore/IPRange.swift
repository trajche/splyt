import Foundation

/// An address prefix such as 10.0.0.0/8 or ::/0.
public struct IPRange: Equatable, Sendable {
    private let network: [UInt8]
    public let prefixLength: Int

    /// Parses "address/prefix", or a bare address as a single host.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let bytes = parts.first.flatMap({ Self.bytes(String($0)) }) else {
            return nil
        }
        let maximum = bytes.count * 8
        let length: Int
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...maximum).contains(value) else {
                return nil
            }
            length = value
        } else {
            length = maximum
        }
        network = Self.masked(bytes, length)
        prefixLength = length
    }

    /// Whether `address` falls inside. Addresses of the other family never do.
    public func contains(_ address: String) -> Bool {
        let host = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        guard let bytes = Self.bytes(host), bytes.count == network.count else {
            return false
        }
        return Self.masked(bytes, prefixLength) == network
    }

    /// Strict parsing: Network's IPv4Address also takes shorthand such as "10.0.0".
    private static func bytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    private static func masked(_ bytes: [UInt8], _ length: Int) -> [UInt8] {
        bytes.enumerated().map { index, byte in
            let bits = min(max(length - index * 8, 0), 8)
            return bits == 0 ? 0 : byte & UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        }
    }
}
