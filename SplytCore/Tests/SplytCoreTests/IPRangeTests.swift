import XCTest
@testable import SplytCore

final class IPRangeTests: XCTestCase {
    func testContains() throws {
        let all4 = try XCTUnwrap(IPRange("0.0.0.0/0"))
        XCTAssertTrue(all4.contains("1.1.1.1"))
        XCTAssertFalse(all4.contains("2606:4700::1111"))

        let all6 = try XCTUnwrap(IPRange("::/0"))
        XCTAssertTrue(all6.contains("2606:4700::1111"))
        XCTAssertFalse(all6.contains("1.1.1.1"))

        let net = try XCTUnwrap(IPRange("10.77.0.0/20"))
        XCTAssertTrue(net.contains("10.77.15.255"))
        XCTAssertFalse(net.contains("10.77.16.0"))

        let odd = try XCTUnwrap(IPRange("10.77.0.9/29"))  // host bits are ignored
        XCTAssertTrue(odd.contains("10.77.0.15"))
        XCTAssertFalse(odd.contains("10.77.0.16"))

        let host = try XCTUnwrap(IPRange("fd77:77::2"))
        XCTAssertEqual(host.prefixLength, 128)
        XCTAssertTrue(host.contains("fd77:77::2"))
        XCTAssertFalse(host.contains("fd77:77::3"))
        XCTAssertTrue(try XCTUnwrap(IPRange("fe80::/10")).contains("fe80::1%en0"))
    }

    func testRejectsBadInput() {
        for text in ["", "10.0.0.0/33", "::/129", "10.0.0/8", "host/8", "10.0.0.0/x", "10.0.0.0/-1"] {
            XCTAssertNil(IPRange(text), text)
        }
        XCTAssertFalse(IPRange("0.0.0.0/0")!.contains("not an address"))
    }

    func testLocalTunnelLookup() {
        let tunnel = Egress.LocalTunnel(name: "utun8", routes: ["0.0.0.0/0", "::/0"].compactMap(IPRange.init))
        XCTAssertTrue(tunnel.carries("95.217.18.211"))
        XCTAssertTrue(tunnel.carries("2a01:4f9::1"))
        let split = Egress.LocalTunnel(name: "utun8", routes: ["10.77.0.0/24"].compactMap(IPRange.init))
        XCTAssertFalse(split.carries("1.1.1.1"))
    }
}
