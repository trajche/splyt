import Network
import XCTest
@testable import SplytCore

/// Scripted stand-in for a system TCP flow.
private final class FakeTCPFlow: TCPFlowIO {
    private let lock = NSLock()
    private var pendingReads: [(Data?, Error?) -> Void] = []
    private var incoming: [Data] = []
    private var eof = false
    private(set) var written = Data()
    private(set) var writeClosed = false
    private(set) var readClosed = false
    private(set) var opened = false
    private(set) var closeWriteError: Error?
    var openError: Error?
    let writeClosedExpectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        writeClosedExpectation = expectation
    }

    func open(completion: @escaping (Error?) -> Void) {
        opened = true
        completion(openError)
    }

    func read(completion: @escaping (Data?, Error?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if !incoming.isEmpty {
            completion(incoming.removeFirst(), nil)
        } else if eof {
            completion(Data(), nil)
        } else {
            pendingReads.append(completion)
        }
    }

    func appSends(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if pendingReads.isEmpty {
            incoming.append(data)
        } else {
            pendingReads.removeFirst()(data, nil)
        }
    }

    func appFinishes() {
        lock.lock()
        defer { lock.unlock() }
        eof = true
        pendingReads.forEach { $0(Data(), nil) }
        pendingReads.removeAll()
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock()
        written.append(data)
        lock.unlock()
        completion(nil)
    }

    func closeRead(error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        readClosed = true
    }

    func closeWrite(error: Error?) {
        lock.lock()
        let first = !writeClosed
        writeClosed = true
        closeWriteError = error
        lock.unlock()
        if first {
            writeClosedExpectation.fulfill()
        }
    }

    var received: Data {
        lock.lock()
        defer { lock.unlock() }
        return written
    }
}

private final class FakeUDPFlow: UDPFlowIO {
    private let lock = NSLock()
    private var pending: (([(Data, NWEndpoint)]?, Error?) -> Void)?
    private(set) var received: [(Data, NWEndpoint)] = []
    private(set) var closed = false
    let replied: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        replied = expectation
    }

    func open(completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func readDatagrams(completion: @escaping ([(Data, NWEndpoint)]?, Error?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        pending = completion
    }

    func appSends(_ data: Data, to endpoint: NWEndpoint) {
        lock.lock()
        let reader = pending
        pending = nil
        lock.unlock()
        reader?([(data, endpoint)], nil)
    }

    func appCloses() {
        lock.lock()
        let reader = pending
        pending = nil
        lock.unlock()
        reader?(nil, nil)
    }

    func writeDatagrams(_ datagrams: [(Data, NWEndpoint)], completion: @escaping (Error?) -> Void) {
        lock.lock()
        received.append(contentsOf: datagrams)
        lock.unlock()
        completion(nil)
        replied.fulfill()
    }

    func closeRead(error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    func closeWrite(error: Error?) {}
}

/// Loopback TCP server: upper-cases what it receives, then closes on client EOF.
private final class UppercaseServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.tcp")
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                return
            }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.serve(connection)
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    }

    var endpoint: NWEndpoint {
        .hostPort(host: "127.0.0.1", port: listener.port!)
    }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, _ in
            if let data, !data.isEmpty {
                let upper = Data(data.map { (97...122).contains($0) ? $0 - 32 : $0 })
                connection.send(content: upper, completion: .contentProcessed { _ in })
            }
            if complete {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            } else {
                self.serve(connection)
            }
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

final class TCPBridgeTests: XCTestCase {
    func testRelaysBothWaysAndPropagatesEOF() throws {
        let server = try UppercaseServer()
        defer { server.stop() }
        let closed = expectation(description: "remote EOF reached the app")
        let done = expectation(description: "bridge finished")
        let flow = FakeTCPFlow(closed)
        let counters = Counters()
        let bridge = TCPBridge(
            flow: flow, targets: [server.endpoint], interface: nil,
            onBytes: counters.add, onFinish: { done.fulfill() }
        )
        bridge.start()
        flow.appSends(Data("hello splyt".utf8))
        flow.appFinishes()
        wait(for: [closed, done], timeout: 5)
        XCTAssertEqual(String(data: flow.received, encoding: .utf8), "HELLO SPLYT")
        XCTAssertTrue(flow.readClosed)
        XCTAssertEqual(counters.values.up, 11)
        XCTAssertEqual(counters.values.down, 11)
    }

    func testLargeTransferKeepsEveryByte() throws {
        let server = try UppercaseServer()
        defer { server.stop() }
        let closed = expectation(description: "closed")
        let flow = FakeTCPFlow(closed)
        let bridge = TCPBridge(flow: flow, targets: [server.endpoint], interface: nil, onBytes: { _, _ in }, onFinish: {})
        bridge.start()
        let payload = Data(repeating: 97, count: 4 * 1024 * 1024)
        flow.appSends(payload)
        flow.appFinishes()
        wait(for: [closed], timeout: 15)
        XCTAssertEqual(flow.received, Data(repeating: 65, count: payload.count))
    }

    /// Regression: an NWConnection reports failed(ENETDOWN) once both directions have
    /// closed, even with received data still buffered. The bridge used to treat that
    /// as fatal and cut off the tail of the response.
    func testHalfClosedAppStillGetsFullResponse() throws {
        for _ in 0..<5 {
            let server = try ReadThenReplyServer()
            let closed = expectation(description: "closed")
            let done = expectation(description: "finished")
            let flow = FakeTCPFlow(closed)
            let bridge = TCPBridge(
                flow: flow, targets: [.hostPort(host: "127.0.0.1", port: server.port)], interface: nil,
                onBytes: { _, _ in }, onFinish: { done.fulfill() }
            )
            bridge.start()
            let size = 4 * 1024 * 1024
            flow.appSends(Data(repeating: 97, count: size))
            flow.appFinishes()
            wait(for: [closed, done], timeout: 15)
            XCTAssertEqual(flow.received.count, size)
            XCTAssertNil(flow.closeWriteError)
        }
    }

    func testFallsBackToNextTargetWhenFirstFails() throws {
        let server = try UppercaseServer()
        defer { server.stop() }
        let closed = expectation(description: "closed")
        let flow = FakeTCPFlow(closed)
        let refused = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        let bridge = TCPBridge(flow: flow, targets: [refused, server.endpoint], interface: nil, onBytes: { _, _ in }, onFinish: {})
        bridge.start()
        flow.appSends(Data("x".utf8))
        flow.appFinishes()
        wait(for: [closed], timeout: 10)
        XCTAssertEqual(String(data: flow.received, encoding: .utf8), "X")
    }

    func testClosesFlowWithoutOpeningWhenEveryTargetFails() {
        let closed = expectation(description: "closed")
        let done = expectation(description: "finished")
        let flow = FakeTCPFlow(closed)
        let refused = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        let bridge = TCPBridge(flow: flow, targets: [refused], interface: nil, onBytes: { _, _ in }, onFinish: { done.fulfill() })
        bridge.start()
        wait(for: [closed, done], timeout: 10)
        XCTAssertFalse(flow.opened)
        XCTAssertTrue(flow.readClosed)
    }

    func testOpenFailureTearsDown() throws {
        let server = try UppercaseServer()
        defer { server.stop() }
        let closed = expectation(description: "closed")
        let flow = FakeTCPFlow(closed)
        flow.openError = URLError(.cancelled)
        let bridge = TCPBridge(flow: flow, targets: [server.endpoint], interface: nil, onBytes: { _, _ in }, onFinish: {})
        bridge.start()
        wait(for: [closed], timeout: 5)
    }
}

final class UDPBridgeTests: XCTestCase {
    func testRelaysDatagramAndTagsReplyWithPeer() throws {
        let queue = DispatchQueue(label: "test.udp")
        let listener = try NWListener(using: .udp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receiveMessage { data, _, _, _ in
                connection.send(content: Data("pong:".utf8) + (data ?? Data()), completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        defer { listener.cancel() }

        let replied = expectation(description: "reply")
        let finished = expectation(description: "finished")
        let flow = FakeUDPFlow(replied)
        let bridge = UDPBridge(flow: flow, interface: nil, onBytes: { _, _ in }, onFinish: { finished.fulfill() })
        bridge.start()
        let peer = NWEndpoint.hostPort(host: "127.0.0.1", port: listener.port!)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            flow.appSends(Data("ping".utf8), to: peer)
        }
        wait(for: [replied], timeout: 5)
        XCTAssertEqual(flow.received.first.map { String(decoding: $0.0, as: UTF8.self) }, "pong:ping")
        XCTAssertEqual(flow.received.first?.1, peer)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            flow.appCloses()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(flow.closed)
    }
}

/// Blocking BSD-socket server: reads to EOF, sends a reply of the same size, closes.
/// This is the shape of a real remote peer, independent of Network.framework.
private final class ReadThenReplyServer {
    let port: NWEndpoint.Port

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port)))
        Thread.detachNewThread {
            let client = accept(listener, nil, nil)
            defer {
                close(client)
                close(listener)
            }
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while case let count = read(client, &buffer, buffer.count), count > 0 {
                total += count
            }
            let reply = [UInt8](repeating: 65, count: total)
            var offset = 0
            while offset < total {
                let sent = reply[offset...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                guard sent > 0 else {
                    return
                }
                offset += sent
            }
        }
    }
}

/// Bytes counted from the bridge's queue and asserted from the test's thread.
private final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var up: UInt64 = 0
    private var down: UInt64 = 0

    func add(_ up: UInt64, _ down: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.up += up
        self.down += down
    }

    var values: (up: UInt64, down: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (up, down)
    }
}
