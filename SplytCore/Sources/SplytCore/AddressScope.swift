import Foundation
import Network

/// Classifies destinations that are not on the public internet.
public enum AddressScope {
    private static let v4Blocks: [(network: UInt32, bits: UInt32)] = [
        (0x0000_0000, 8),   // 0.0.0.0/8
        (0x0A00_0000, 8),   // 10.0.0.0/8
        (0x6440_0000, 10),  // 100.64.0.0/10 (NetBird and Tailscale overlays)
        (0x7F00_0000, 8),   // 127.0.0.0/8
        (0xA9FE_0000, 16),  // 169.254.0.0/16
        (0xAC10_0000, 12),  // 172.16.0.0/12
        (0xC0A8_0000, 16),  // 192.168.0.0/16
        (0xE000_0000, 4),   // 224.0.0.0/4
        (0xF000_0000, 4),   // 240.0.0.0/4
    ]

    /// Loopback, RFC 1918, CGNAT overlays, link-local, multicast and their IPv6
    /// counterparts. Unparseable input is treated as public.
    public static func isLocal(_ address: String) -> Bool {
        // Strip a zone such as fe80::1%en0.
        let host = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        if let v4 = IPv4Address(host) {
            return isLocal(v4: v4)
        }
        guard let v6 = IPv6Address(host) else {
            return false
        }
        if let mapped = v6.asIPv4 {
            return isLocal(v4: mapped)
        }
        let bytes = [UInt8](v6.rawValue)
        if bytes.allSatisfy({ $0 == 0 }) || (bytes[..<15].allSatisfy { $0 == 0 } && bytes[15] == 1) {
            return true  // :: and ::1
        }
        return bytes[0] == 0xFF                              // ff00::/8
            || (bytes[0] & 0xFE) == 0xFC                     // fc00::/7
            || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)  // fe80::/10
    }

    private static func isLocal(v4: IPv4Address) -> Bool {
        let value = v4.rawValue.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return v4Blocks.contains { block in
            let mask = UInt32.max << (32 - block.bits)
            return value & mask == block.network
        }
    }
}
