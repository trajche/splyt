import Network
import XCTest
@testable import SplytCore

final class SOCKSHandshakeTests: XCTestCase {
    private func greeted(_ password: String = "secret") -> SOCKSHandshake {
        var handshake = SOCKSHandshake(password: password)
        _ = handshake.consume(Data([5, 2, 0, 2]))
        return handshake
    }

    private func credentials(user: String = "splyt", password: String = "secret") -> Data {
        Data([1, UInt8(user.utf8.count)] + Array(user.utf8) + [UInt8(password.utf8.count)] + Array(password.utf8))
    }

    private func authenticated() -> SOCKSHandshake {
        var handshake = greeted()
        _ = handshake.consume(credentials())
        return handshake
    }

    func testChoosesPasswordEvenWhenNoAuthIsOffered() {
        var handshake = SOCKSHandshake(password: "secret")
        XCTAssertEqual(handshake.consume(Data([5, 2, 0, 2])), [.send(Data([5, 2]))])
    }

    func testRefusesClientsThatCannotAuthenticate() {
        var handshake = SOCKSHandshake(password: "secret")
        XCTAssertEqual(handshake.consume(Data([5, 1, 0])), [.reject(reply: Data([5, 0xFF]))])
    }

    func testRefusesWrongPasswordAndUsername() {
        var wrongPassword = greeted()
        XCTAssertEqual(wrongPassword.consume(credentials(password: "nope")), [.reject(reply: Data([1, 1]))])
        var wrongUser = greeted()
        XCTAssertEqual(wrongUser.consume(credentials(user: "other")), [.reject(reply: Data([1, 1]))])
    }

    func testEmptyConfiguredPasswordNeverAuthenticates() {
        var handshake = greeted("")
        XCTAssertEqual(handshake.consume(credentials(password: "")), [.reject(reply: Data([1, 1]))])
    }

    func testParsesDomainTargetWithEarlyData() {
        var handshake = authenticated()
        let name = Array("example.com".utf8)
        let request = Data([5, 1, 0, 3, UInt8(name.count)] + name + [0x01, 0xBB] + [0xAA, 0xBB])
        XCTAssertEqual(
            handshake.consume(request),
            [.connect(host: "example.com", port: 443, leftover: Data([0xAA, 0xBB]))]
        )
    }

    func testParsesIPv4AndIPv6Targets() {
        var v4 = authenticated()
        XCTAssertEqual(
            v4.consume(Data([5, 1, 0, 1, 1, 2, 3, 4, 0, 80])),
            [.connect(host: "1.2.3.4", port: 80, leftover: Data())]
        )
        var v6 = authenticated()
        let address: [UInt8] = [0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 11) + [1]
        guard case .connect(let host, 80, _)? = v6.consume(Data([5, 1, 0, 4] + address + [0, 80])).first else {
            return XCTFail("expected connect")
        }
        XCTAssertEqual(IPv6Address(host), IPv6Address("2001:db8::1"))
    }

    func testHandlesBytesArrivingOneAtATime() {
        var handshake = SOCKSHandshake(password: "secret")
        let name = Array("a.io".utf8)
        let stream = [5, 1, 2] + Array(credentials()) + [5, 1, 0, 3, UInt8(name.count)] + name + [0, 80]
        let events = stream.flatMap { handshake.consume(Data([$0])) }
        XCTAssertEqual(events, [
            .send(Data([5, 2])), .send(Data([1, 0])),
            .connect(host: "a.io", port: 80, leftover: Data()),
        ])
    }

    func testRefusesUDPAssociate() {
        var handshake = authenticated()
        XCTAssertEqual(
            handshake.consume(Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])),
            [.reject(reply: SOCKSHandshake.reply(.commandNotSupported))]
        )
    }

    func testRefusesOtherProtocols() {
        var handshake = SOCKSHandshake(password: "secret")
        XCTAssertEqual(handshake.consume(Data("GET / HTTP/1.1\r\n".utf8)), [.reject(reply: nil)])
    }
}

final class BrowserProxySettingsTests: XCTestCase {
    func testOldSavedConfigStillDecodes() throws {
        let saved = Data(#"{"rules":[],"killSwitch":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SplytConfig.self, from: saved).browserProxy)
    }

    func testPairingCodeFormat() {
        let settings = BrowserProxySettings(enabled: true, vpnPort: 1, directPort: 2, token: "abc")
        XCTAssertEqual(settings.pairingCode, "1:2:abc")
    }
}

/// Runs the real server and a real SOCKS client over loopback.
final class BrowserProxyServerTests: XCTestCase {
    private static let token = "test-token"
    private var server: BrowserProxyServer!
    private var echo: NWListener!
    private let queue = DispatchQueue(label: "test")

    override func tearDown() {
        server?.stop()
        echo?.cancel()
        super.tearDown()
    }

    private func startEcho() throws -> UInt16 {
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "echo ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    if let data, !data.isEmpty {
                        connection.send(content: data, completion: .contentProcessed { _ in
                            isComplete ? connection.cancel() : pump()
                        })
                    } else {
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    }
                }
            }
            pump()
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        echo = listener
        return listener.port!.rawValue
    }

    private func startServer(vpn: UInt16, direct: UInt16, planner: @escaping BrowserProxyServer.Planner) {
        server = BrowserProxyServer(planner: planner)
        server.apply(BrowserProxySettings(enabled: true, vpnPort: vpn, directPort: direct, token: Self.token))
    }

    /// Bytes a client gets back after running the handshake and sending `payload`.
    private func exchange(port: UInt16, password: String = token, payload: Data) -> Data {
        let name = Array("target.test".utf8)
        var script = Data([5, 1, 2])
        script.append(Data([1, 5] + Array("splyt".utf8) + [UInt8(password.utf8.count)] + Array(password.utf8)))
        script.append(Data([5, 1, 0, 3, UInt8(name.count)] + name + [0x1F, 0x90]))
        script.append(payload)

        let done = expectation(description: "client finished")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var received = Data()
        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data {
                    received.append(data)
                }
                if isComplete || error != nil {
                    done.fulfill()
                } else {
                    pump()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: script, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                pump()
            }
        }
        connection.start(queue: queue)
        wait(for: [done], timeout: 10)
        connection.cancel()
        return received
    }

    private func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(socket, $0, length) == 0, getsockname(socket, $0, &length) == 0 else {
                    throw POSIXError(.EADDRINUSE)
                }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Slow CI machines can take seconds to bring the listeners up.
    private func awaitListening(_ port: UInt16) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            defer { close(socket) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected == 0 {
                return
            }
            usleep(20_000)
        }
        XCTFail("nothing listening on port \(port)")
    }

    func testRelaysToPlannedTargetOnTheRequestedRoute() throws {
        let echoPort = try startEcho()
        let (vpn, direct) = (try freePort(), try freePort())
        let routes = NSLock()
        var seen: [Route] = []
        startServer(vpn: vpn, direct: direct) { route, host, _, completion in
            XCTAssertEqual(host, "target.test")
            routes.lock()
            seen.append(route)
            routes.unlock()
            let target = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: echoPort)!)
            completion(.init(targets: [target], interface: nil))
        }
        awaitListening(vpn)
        awaitListening(direct)

        let payload = Data("hello through the proxy".utf8)
        let handshakeReplies = Data([5, 2, 1, 0]) + SOCKSHandshake.reply(.succeeded)
        XCTAssertEqual(exchange(port: vpn, payload: payload), handshakeReplies + payload)
        XCTAssertEqual(exchange(port: direct, payload: payload), handshakeReplies + payload)
        routes.lock()
        defer { routes.unlock() }
        XCTAssertEqual(seen, [.vpn, .direct])
    }

    func testUnavailableRouteIsRefusedRatherThanRerouted() throws {
        let (vpn, direct) = (try freePort(), try freePort())
        startServer(vpn: vpn, direct: direct) { _, _, _, completion in completion(nil) }
        awaitListening(vpn)
        XCTAssertEqual(
            exchange(port: vpn, payload: Data()),
            Data([5, 2, 1, 0]) + SOCKSHandshake.reply(.networkUnreachable)
        )
    }

    func testFailedTargetTellsTheClient() throws {
        let (vpn, direct, closed) = (try freePort(), try freePort(), try freePort())
        startServer(vpn: vpn, direct: direct) { _, _, _, completion in
            let target = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: closed)!)
            completion(.init(targets: [target], interface: nil))
        }
        awaitListening(direct)
        XCTAssertEqual(
            exchange(port: direct, payload: Data()),
            Data([5, 2, 1, 0]) + SOCKSHandshake.reply(.hostUnreachable)
        )
    }

    func testWrongPasswordNeverReachesThePlanner() throws {
        let (vpn, direct) = (try freePort(), try freePort())
        startServer(vpn: vpn, direct: direct) { _, _, _, completion in
            XCTFail("planner must not run")
            completion(nil)
        }
        awaitListening(direct)
        XCTAssertEqual(exchange(port: direct, password: "wrong", payload: Data()), Data([5, 2, 1, 1]))
    }

    func testDisablingStopsListening() throws {
        let (vpn, direct) = (try freePort(), try freePort())
        startServer(vpn: vpn, direct: direct) { _, _, _, completion in completion(nil) }
        awaitListening(vpn)
        server.apply(BrowserProxySettings(enabled: false, vpnPort: vpn, directPort: direct, token: Self.token))
        usleep(200_000)
        XCTAssertFalse(accepts(vpn))
        XCTAssertFalse(accepts(direct))
    }

    private func accepts(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
