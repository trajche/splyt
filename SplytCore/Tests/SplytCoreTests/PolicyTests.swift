import XCTest
@testable import SplytCore

final class PolicyTests: XCTestCase {
    private let chrome = AppRule(
        signingID: "com.google.Chrome", path: "/Applications/Google Chrome.app",
        name: "Chrome", route: .direct
    )
    private let slack = AppRule(signingID: "com.tinyspeck.slackmacgap", name: "Slack", route: .vpn)
    private let steam = AppRule(signingID: "com.valvesoftware.steam", name: "Steam", route: .block)

    private func policy(unlisted: Route? = nil, killSwitch: Bool = true) -> Policy {
        Policy(config: SplytConfig(rules: [chrome, slack, steam], unlisted: unlisted, killSwitch: killSwitch))
    }

    private func flow(_ id: String, path: String? = nil, ip: String? = "93.184.216.34") -> FlowInfo {
        FlowInfo(signingID: id, path: path, remoteIP: ip)
    }

    func testDirectAppIsProxiedOnlyWhileVPNOwnsTheRoute() {
        let onVPN = policy().decide(flow("com.google.Chrome")) { true }
        XCTAssertEqual(onVPN, Decision(verdict: .direct, route: .direct))
        let noVPN = policy().decide(flow("com.google.Chrome")) { false }
        XCTAssertEqual(noVPN, Decision(verdict: .pass, route: .direct))
    }

    func testVPNAppPassesWhileVPNIsUp() {
        XCTAssertEqual(policy().decide(flow("com.tinyspeck.slackmacgap")) { true }.verdict, .pass)
    }

    func testKillSwitchBlocksVPNAppWhenVPNIsDown() {
        XCTAssertEqual(policy().decide(flow("com.tinyspeck.slackmacgap")) { false }.verdict, .block)
    }

    func testVPNAppLeaksOnlyWhenKillSwitchIsOff() {
        let decision = policy(killSwitch: false).decide(flow("com.tinyspeck.slackmacgap")) { false }
        XCTAssertEqual(decision.verdict, .pass)
    }

    func testBlockedAppIsBlockedRegardlessOfVPNOrDestination() {
        XCTAssertEqual(policy().decide(flow("com.valvesoftware.steam")) { true }.verdict, .block)
        XCTAssertEqual(policy().decide(flow("com.valvesoftware.steam", ip: "192.168.1.5")) { false }.verdict, .block)
    }

    func testMeshAndLANDestinationsKeepSystemRouting() {
        for ip in ["100.125.95.24", "100.70.19.127", "10.1.8.1", "192.168.0.2", "fd03:da71:b90b:80c4::1"] {
            XCTAssertEqual(policy().decide(flow("com.google.Chrome", ip: ip)) { true }.verdict, .pass, ip)
            XCTAssertEqual(policy().decide(flow("com.tinyspeck.slackmacgap", ip: ip)) { false }.verdict, .pass, ip)
        }
    }

    func testUnlistedAppsFollowSystemByDefaultWithoutProbingRoutes() {
        let decision = policy().decide(flow("org.example.other")) {
            XCTFail("the route should not be probed")
            return true
        }
        XCTAssertEqual(decision, Decision(verdict: .pass, route: nil))
    }

    func testUnlistedPolicyApplies() {
        XCTAssertEqual(policy(unlisted: .direct).decide(flow("org.example.other")) { true }.verdict, .direct)
        XCTAssertEqual(policy(unlisted: .block).decide(flow("org.example.other")) { true }.verdict, .block)
        XCTAssertEqual(policy(unlisted: .vpn).decide(flow("org.example.other")) { false }.verdict, .block)
    }

    func testTunnelDaemonsAreNeverRedirected() {
        let strict = policy(unlisted: .block)
        let exempt = [
            flow("netbird"),
            flow("com.wireguard.macos.network-extension"),
            flow("io.tailscale.ipn.macsys.network-extension"),
            flow("com.apple.mDNSResponder"),
            flow("a.out", path: "/usr/local/bin/netbird"),
            flow("com.amplify2.splyt.proxy"),
        ]
        for candidate in exempt {
            XCTAssertEqual(strict.decide(candidate) { true }, Decision(verdict: .pass, route: nil), candidate.signingID)
        }
    }

    func testHelpersMatchTheirParentApp() {
        let byID = flow("com.google.Chrome.helper")
        XCTAssertEqual(policy().decide(byID) { true }.verdict, .direct)
        let byPath = flow(
            "unsigned-helper",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        )
        XCTAssertEqual(policy().decide(byPath) { true }.verdict, .direct)
    }

    func testPrefixMatchRespectsIdentifierBoundaries() {
        XCTAssertNil(policy().matchRule(flow("com.google.ChromeRemoteDesktop")))
        XCTAssertNil(policy().matchRule(flow("x", path: "/Applications/Google Chrome.app.bak/x")))
    }

    func testExactIdentifierBeatsPrefix() {
        let helper = AppRule(signingID: "com.google.Chrome.helper", name: "Helper", route: .block)
        let policy = Policy(config: SplytConfig(rules: [chrome, helper]))
        XCTAssertEqual(policy.matchRule(flow("com.google.Chrome.helper"))?.name, "Helper")
    }

    func testMostSpecificPathWins() {
        let parent = AppRule(signingID: "", path: "/opt/tools", name: "Tools", route: .vpn)
        let child = AppRule(signingID: "", path: "/opt/tools/curl", name: "Curl", route: .direct)
        let policy = Policy(config: SplytConfig(rules: [parent, child]))
        XCTAssertEqual(policy.matchRule(flow("", path: "/opt/tools/curl"))?.name, "Curl")
        XCTAssertEqual(policy.matchRule(flow("", path: "/opt/tools/wget"))?.name, "Tools")
    }

    func testMissingRemoteAddressStillApplies() {
        let decision = policy().decide(flow("com.tinyspeck.slackmacgap", ip: nil)) { false }
        XCTAssertEqual(decision.verdict, .block)
    }
}

final class AddressScopeTests: XCTestCase {
    func testLocalAddresses() {
        let local = [
            "0.0.0.0", "10.1.8.1", "100.64.0.1", "100.125.226.85", "100.127.255.255", "127.0.0.1",
            "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "224.0.0.251",
            "255.255.255.255", "::", "::1", "fe80::1", "fe80::1%en0", "fd7a:115c:a1e0::1",
            "ff02::fb", "::ffff:10.0.0.1",
        ]
        for address in local {
            XCTAssertTrue(AddressScope.isLocal(address), address)
        }
    }

    func testPublicAddresses() {
        let external = [
            "1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.0", "172.15.0.1", "172.32.0.1",
            "192.167.1.1", "2606:4700:4700::1111", "::ffff:1.1.1.1", "not-an-ip",
        ]
        for address in external {
            XCTAssertFalse(AddressScope.isLocal(address), address)
        }
    }
}

final class CodingTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let config = SplytConfig(rules: [AppRule(signingID: "a", name: "A", route: .block)], unlisted: .direct)
        let data = try JSONEncoder().encode(ProviderRequest.apply(config))
        guard case .apply(let decoded) = try JSONDecoder().decode(ProviderRequest.self, from: data) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(decoded, config)
    }
}

final class ActivityLogTests: XCTestCase {
    func testCountsAndActiveFlows() {
        let log = ActivityLog()
        let flow = FlowInfo(signingID: "a")
        let decision = Decision(verdict: .direct, route: .direct)
        log.record(flow, remote: "1.1.1.1:443", decision: decision, tracked: true)
        log.record(flow, remote: nil, decision: decision, tracked: true)
        log.add(signingID: "a", path: nil, up: 10, down: 20)
        log.flowFinished()
        let snapshot = log.snapshot(vpnInterface: "utun100", physicalInterface: "en0")
        XCTAssertEqual(snapshot.activeFlows, 1)
        XCTAssertEqual(snapshot.apps.first?.flows, 2)
        XCTAssertEqual(snapshot.apps.first?.bytesUp, 10)
        XCTAssertEqual(snapshot.apps.first?.bytesDown, 20)
        XCTAssertEqual(snapshot.apps.first?.lastRemote, "1.1.1.1:443")
    }

    func testCapacityEvictsOldest() {
        let log = ActivityLog(capacity: 2)
        let decision = Decision(verdict: .pass, route: nil)
        for (index, id) in ["a", "b", "c"].enumerated() {
            log.record(
                FlowInfo(signingID: id), remote: nil, decision: decision, tracked: false,
                now: Date(timeIntervalSince1970: Double(index))
            )
        }
        XCTAssertEqual(Set(log.snapshot(vpnInterface: nil, physicalInterface: nil).apps.map(\.id)), ["b", "c"])
    }
}

final class EgressTests: XCTestCase {
    func testTunnelNames() {
        XCTAssertTrue(Egress.isTunnel("utun100"))
        XCTAssertTrue(Egress.isTunnel("ipsec0"))
        XCTAssertFalse(Egress.isTunnel("en0"))
    }

    func testLoopbackLookupUsesRealRoutingTable() {
        XCTAssertEqual(Egress.interface(to: "127.0.0.1"), "lo0")
        XCTAssertFalse(Egress.routesViaVPN(to: "127.0.0.1"))
    }

    func testInvalidAddressHasNoInterface() {
        XCTAssertNil(Egress.interface(to: "bogus"))
    }
}

final class NetBirdParsingTests: XCTestCase {
    func testParsesExitNodeAndSelection() {
        let output = """
        Available Networks:

          - ID: Exit Node (VPN all traffic)
            Network: 0.0.0.0/0, ::/0
            Status: Not Selected

          - ID: office
            Network: 10.20.0.0/16
            Status: Selected
        """
        let networks = NetBirdNetwork.parse(output)
        XCTAssertEqual(networks.count, 2)
        XCTAssertEqual(networks[0].id, "Exit Node (VPN all traffic)")
        XCTAssertEqual(networks[0].ranges, ["0.0.0.0/0", "::/0"])
        XCTAssertTrue(networks[0].isExitNode)
        XCTAssertFalse(networks[0].isSelected)
        XCTAssertFalse(networks[1].isExitNode)
        XCTAssertTrue(networks[1].isSelected)
    }

    func testEmptyOutput() {
        XCTAssertTrue(NetBirdNetwork.parse("No networks available.").isEmpty)
    }
}
