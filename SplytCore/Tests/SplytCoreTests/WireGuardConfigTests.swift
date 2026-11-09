import XCTest
@testable import SplytCore

final class WireGuardConfigTests: XCTestCase {
    private let key1 = "gUThNpfK2d2sNqAl7Kc3E1M7hDSv5zGo8I2IakycRNM="
    private let key2 = "LfmnTR7tO4sBhl0YEre1ULXw8zirSANjVj+TpQphzh8="

    private var sample: String {
        """
        [Interface]
        PrivateKey = \(key1)
        Address = 10.77.0.2/32, fd77:77::2/128
        DNS = 1.1.1.1, 2606:4700:4700::1111, corp.example
        MTU = 1380

        [Peer]
        # exit node
        PublicKey = \(key2)
        PresharedKey = \(key1)
        Endpoint = 203.0.113.10:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        """
    }

    func testParsesFullConfig() throws {
        let config = try WireGuardConfig(parsing: sample)
        XCTAssertEqual(config.interface.privateKey, key1)
        XCTAssertEqual(config.interface.addresses, ["10.77.0.2/32", "fd77:77::2/128"])
        XCTAssertEqual(config.interface.dns, ["1.1.1.1", "2606:4700:4700::1111"])
        XCTAssertEqual(config.interface.dnsSearch, ["corp.example"])
        XCTAssertEqual(config.interface.mtu, 1380)
        XCTAssertEqual(config.peers.count, 1)
        XCTAssertEqual(config.peers[0].publicKey, key2)
        XCTAssertEqual(config.peers[0].presharedKey, key1)
        XCTAssertEqual(config.peers[0].endpoint, "203.0.113.10:51820")
        XCTAssertEqual(config.peers[0].allowedIPs, ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(config.peers[0].persistentKeepalive, 25)
        XCTAssertEqual(config.ignoredKeys, [])
    }

    func testKeysAreCaseInsensitiveAndListsMayRepeat() throws {
        let config = try WireGuardConfig(parsing: """
            [interface]
            privatekey=\(key1)
            address = 10.0.0.2/32
            address = fd00::2/128
            [PEER]
            publickey = \(key2)
            allowedips = 10.0.0.0/24
            AllowedIPs = 192.168.1.0/24
            """)
        XCTAssertEqual(config.interface.addresses, ["10.0.0.2/32", "fd00::2/128"])
        XCTAssertEqual(config.peers[0].allowedIPs, ["10.0.0.0/24", "192.168.1.0/24"])
    }

    func testRecordsScriptKeysAsIgnored() throws {
        let config = try WireGuardConfig(parsing: sample.replacingOccurrences(
            of: "MTU = 1380", with: "MTU = 1380\nPostUp = iptables -A FORWARD\nTable = off"
        ))
        XCTAssertEqual(config.ignoredKeys, ["PostUp", "Table"])
    }

    func testRejectsMissingPieces() {
        XCTAssertThrowsError(try WireGuardConfig(parsing: "[Peer]\nPublicKey = \(key2)")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .missingInterface)
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: "[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = \(key2)")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .missingPrivateKey)
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: "[Interface]\nPrivateKey = \(key1)\nAddress = 10.0.0.2/32")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .noPeers)
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: "[Interface]\nPrivateKey = \(key1)\n[Peer]\nPublicKey = \(key2)")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .missingAddress)
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: "[Interface]\nPrivateKey = \(key1)\nAddress = 10.0.0.2/32\n[Peer]\nEndpoint = 1.2.3.4:5")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .missingPublicKey(peer: 1))
        }
    }

    func testRejectsBadValuesWithLineNumbers() {
        let cases: [(String, String, String, Int)] = [
            ("PrivateKey = \(key1)", "PrivateKey = short", "PrivateKey", 2),
            ("Address = 10.77.0.2/32, fd77:77::2/128", "Address = 10.77.0.2/33", "Address", 3),
            ("MTU = 1380", "MTU = 100", "MTU", 5),
            ("Endpoint = 203.0.113.10:51820", "Endpoint = 203.0.113.10", "Endpoint", 11),
            ("AllowedIPs = 0.0.0.0/0, ::/0", "AllowedIPs = everything", "AllowedIPs", 12),
            ("PersistentKeepalive = 25", "PersistentKeepalive = soon", "PersistentKeepalive", 13),
        ]
        for (good, bad, key, line) in cases {
            XCTAssertThrowsError(try WireGuardConfig(parsing: sample.replacingOccurrences(of: good, with: bad)), key) {
                XCTAssertEqual($0 as? WireGuardConfig.ParseError, .invalidValue(line: line, key: key))
            }
        }
    }

    func testRejectsStructuralErrors() {
        XCTAssertThrowsError(try WireGuardConfig(parsing: "PrivateKey = \(key1)")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .outsideSection(line: 1))
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: "[Interface]\nPrivateKey \(key1)")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .malformedLine(line: 2))
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: "[Wat]")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .unknownSection(line: 1, "Wat"))
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: sample + "\n[Interface]")) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .unknownSection(line: 14, "Interface"))
        }
        XCTAssertThrowsError(try WireGuardConfig(parsing: sample.replacingOccurrences(
            of: "MTU = 1380", with: "MTU = 1380\nMTU = 1400"
        ))) {
            XCTAssertEqual($0 as? WireGuardConfig.ParseError, .duplicateKey(line: 6, key: "mtu"))
        }
    }

    func testKeepaliveOffAndZeroMeanNone() throws {
        for value in ["off", "0"] {
            let config = try WireGuardConfig(parsing: sample.replacingOccurrences(
                of: "PersistentKeepalive = 25", with: "PersistentKeepalive = \(value)"
            ))
            XCTAssertNil(config.peers[0].persistentKeepalive)
        }
    }

    func testEndpointForms() {
        XCTAssertEqual(WireGuardConfig.parseEndpoint("vpn.example.com:51820")?.host, "vpn.example.com")
        XCTAssertEqual(WireGuardConfig.parseEndpoint("[2a01:4f9::1]:51820")?.host, "2a01:4f9::1")
        XCTAssertEqual(WireGuardConfig.parseEndpoint("[2a01:4f9::1]:51820")?.port, 51820)
        XCTAssertNil(WireGuardConfig.parseEndpoint("2a01:4f9::1:51820"))
        XCTAssertNil(WireGuardConfig.parseEndpoint("host:0"))
        XCTAssertNil(WireGuardConfig.parseEndpoint(":51820"))
        XCTAssertNil(WireGuardConfig.parseEndpoint("[::1]51820"))
    }

    func testSummaryHoldsNoKeys() throws {
        let config = try WireGuardConfig(parsing: sample)
        let info = config.summary(id: "abc", name: "vpn-wg")
        XCTAssertEqual(info.endpoint, "203.0.113.10:51820")
        XCTAssertTrue(info.routesAllTraffic)
        let encoded = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        XCTAssertFalse(encoded.contains(key1))
        XCTAssertFalse(encoded.contains(key2))

        let split = try WireGuardConfig(parsing: sample.replacingOccurrences(
            of: "AllowedIPs = 0.0.0.0/0, ::/0", with: "AllowedIPs = 10.0.0.0/8"
        ))
        XCTAssertFalse(split.summary(id: "abc", name: "x").routesAllTraffic)
    }

    func testStatsFromUAPI() {
        let uapi = """
            private_key=abcd
            listen_port=51820
            public_key=ef01
            last_handshake_time_sec=1793638800
            last_handshake_time_nsec=500000000
            rx_bytes=1000
            tx_bytes=2000
            public_key=ef02
            last_handshake_time_sec=0
            last_handshake_time_nsec=0
            rx_bytes=5
            tx_bytes=6
            """
        let stats = WireGuardStats(uapi: uapi)
        XCTAssertEqual(stats.received, 1005)
        XCTAssertEqual(stats.sent, 2006)
        XCTAssertEqual(stats.lastHandshake, Date(timeIntervalSince1970: 1_793_638_800.5))
        XCTAssertNil(WireGuardStats(uapi: "rx_bytes=1\n").lastHandshake)
    }
}
