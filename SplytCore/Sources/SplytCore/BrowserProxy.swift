import Foundation
import Network

/// Local SOCKS5 proxies for routing below the app level. A browser extension picks
/// one listener per request, so a single browser can split traffic by tab, site or
/// container. One listener always leaves through the tunnel and the other through
/// the physical interface. Separate ports, rather than one port with a route in
/// the username, stop the browser reusing a connection across routes.
public final class BrowserProxyServer: @unchecked Sendable {
    /// Where a connection should go. `nil` from a planner means the route is
    /// unavailable, and the client is refused: there is deliberately no fallback.
    public struct Plan {
        public var targets: [NWEndpoint]
        public var interface: NWInterface?

        public init(targets: [NWEndpoint], interface: NWInterface?) {
            self.targets = targets
            self.interface = interface
        }
    }

    public typealias Planner = (
        _ route: Route, _ host: String, _ port: UInt16, _ completion: @escaping (Plan?) -> Void
    ) -> Void

    public struct Hooks {
        public var opened: (Route, String) -> Void = { _, _ in }
        public var bytes: (Route, UInt64, UInt64) -> Void = { _, _, _ in }
        public var closed: () -> Void = {}

        public init() {}
    }

    private static let retryDelay: TimeInterval = 5

    private let planner: Planner
    private let hooks: Hooks
    private let queue = DispatchQueue(label: "com.amplify2.splyt.browser")
    private let lock = NSLock()
    private var settings: BrowserProxySettings?
    private var listeners: [NWListener] = []
    private var sessions: [ObjectIdentifier: SOCKSSession] = [:]
    private var failure: String?

    public init(planner: @escaping Planner, hooks: Hooks = Hooks()) {
        self.planner = planner
        self.hooks = hooks
    }

    /// Why the proxy is not serving, when it should be.
    public var problem: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Starts, stops or restarts to match `settings`. No-op when nothing changed.
    public func apply(_ settings: BrowserProxySettings?) {
        let wanted = settings?.enabled == true ? settings : nil
        lock.lock()
        let unchanged = wanted == self.settings
        lock.unlock()
        guard !unchanged else {
            return
        }
        restart(wanted)
    }

    public func stop() {
        restart(nil)
    }

    private func restart(_ wanted: BrowserProxySettings?) {
        lock.lock()
        let old = listeners
        let oldSessions = Array(sessions.values)
        listeners = []
        sessions = [:]
        settings = wanted
        failure = nil
        lock.unlock()
        old.forEach { $0.cancel() }
        oldSessions.forEach { $0.cancel() }
        guard let wanted else {
            return
        }
        for (route, port) in [(Route.vpn, wanted.vpnPort), (.direct, wanted.directPort)] {
            listen(route: route, port: port, settings: wanted)
        }
    }

    private func listen(route: Route, port: UInt16, settings: BrowserProxySettings) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            setFailure("Port \(port) is not valid")
            return
        }
        let parameters = NWParameters.tcp
        // Loopback only. This listener must never be reachable from the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            setFailure("Could not listen on port \(port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, route: route, password: settings.token)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed(let error) = state, let self, let listener else {
                return
            }
            self.listenerFailed(listener, port: port, error: error)
        }
        lock.lock()
        listeners.append(listener)
        lock.unlock()
        listener.start(queue: queue)
    }

    /// A previous extension process can hold a port briefly during an update.
    private func listenerFailed(_ listener: NWListener, port: UInt16, error: NWError) {
        setFailure("Port \(port) is unavailable: \(error)")
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            let current = self.settings
            let stillListening = self.listeners.contains { $0 === listener }
            self.lock.unlock()
            if stillListening {
                self.restart(current)
            }
        }
    }

    private func setFailure(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        failure = message
    }

    private func accept(_ connection: NWConnection, route: Route, password: String) {
        let session = SOCKSSession(
            connection: connection, route: route, password: password,
            planner: planner, hooks: hooks
        )
        let key = ObjectIdentifier(session)
        session.onEnd = { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.sessions[key] = nil
        }
        lock.lock()
        sessions[key] = session
        lock.unlock()
        session.start()
    }
}

extension BrowserProxyServer {
    /// The planner used in production. It pins every public destination to an
    /// interface, so a tunnel that drops fails the connection instead of leaking it.
    public static func livePlanner(physical: PhysicalInterfaceMonitor) -> Planner {
        { route, host, port, completion in
            guard route != .block, let endpointPort = NWEndpoint.Port(rawValue: port) else {
                completion(nil)
                return
            }
            let isNumeric = IPv4Address(host) != nil || IPv6Address(host) != nil
            if isNumeric, AddressScope.isLocal(host) {
                completion(Plan(targets: [Self.endpoint(host, endpointPort)], interface: nil))
                return
            }
            if route == .direct {
                // Resolving over en0 keeps the answer outside the VPN, so a CDN does
                // not pick a server for the exit node's location.
                guard let interface = physical.current else {
                    completion(nil)
                    return
                }
                completion(Plan(targets: [Self.endpoint(host, endpointPort)], interface: interface))
                return
            }
            // A connection pinned to a tunnel only resolves if that tunnel has its
            // own scoped DNS. Resolving through the system first gives VPN-routed
            // tabs the same DNS as apps on the VPN route.
            DispatchQueue.global(qos: .userInitiated).async {
                let addresses = isNumeric ? [host] : Egress.resolve(host)
                completion(Self.tunnelPlan(addresses: addresses, port: endpointPort, physical: physical))
            }
        }
    }

    private static func tunnelPlan(
        addresses: [String], port: NWEndpoint.Port, physical: PhysicalInterfaceMonitor
    ) -> Plan? {
        // A name that resolves only to private addresses is an internal service.
        if !addresses.isEmpty, addresses.allSatisfy(AddressScope.isLocal) {
            return Plan(targets: addresses.map { endpoint($0, port) }, interface: nil)
        }
        let routed = addresses
            .filter { !AddressScope.isLocal($0) }
            .compactMap { address in Egress.interface(to: address).map { (address, $0) } }
            .filter { Egress.isTunnel($0.1) }
        guard let name = routed.first?.1, let tunnel = physical.interface(named: name) else {
            return nil
        }
        let targets = routed.filter { $0.1 == name }.map { endpoint($0.0, port) }
        return Plan(targets: targets, interface: tunnel)
    }

    private static func endpoint(_ host: String, _ port: NWEndpoint.Port) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}

/// One client, from handshake to the end of its relay.
private final class SOCKSSession {
    private static let handshakeTimeout: TimeInterval = 10

    private let connection: NWConnection
    private let route: Route
    private let planner: BrowserProxyServer.Planner
    private let hooks: BrowserProxyServer.Hooks
    private let queue = DispatchQueue(label: "com.amplify2.splyt.socks")
    private var handshake: SOCKSHandshake
    private var bridge: TCPBridge?
    /// The client may send its request, data and FIN in one go. Network reports that
    /// end once; later receives fail with ENODATA instead of reporting it again.
    private var clientFinished = false
    private var timer: DispatchSourceTimer?
    private var ended = false

    var onEnd: (() -> Void)?

    init(
        connection: NWConnection, route: Route, password: String,
        planner: @escaping BrowserProxyServer.Planner, hooks: BrowserProxyServer.Hooks
    ) {
        self.connection = connection
        self.route = route
        self.planner = planner
        self.hooks = hooks
        handshake = SOCKSHandshake(password: password)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.handshakeTimeout)
        timer.setEventHandler { [weak self] in
            self?.end()
        }
        timer.resume()
        self.timer = timer
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connectionEnded() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHandshake()
    }

    func cancel() {
        queue.async { self.end() }
    }

    /// Before the relay starts this ends the session. After it, the bridge sees the
    /// same failure through its flow and finishes on its own.
    private func connectionEnded() {
        if bridge == nil {
            end()
        }
    }

    private func receiveHandshake() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.ended else {
                return
            }
            var proceed = false
            self.clientFinished = isComplete
            if let data, !data.isEmpty {
                proceed = self.apply(self.handshake.consume(data))
            }
            if proceed {
                if isComplete || error != nil {
                    self.end()
                } else {
                    self.receiveHandshake()
                }
            }
        }
    }

    /// Returns whether more handshake bytes are expected.
    private func apply(_ events: [SOCKSHandshake.Event]) -> Bool {
        for event in events {
            switch event {
            case .send(let data):
                connection.send(content: data, completion: .idempotent)
            case .reject(let reply):
                refuse(reply)
                return false
            case .connect(let host, let port, let leftover):
                timer?.cancel()
                timer = nil
                planner(route, host, port) { [weak self] plan in
                    self?.queue.async { self?.relay(host: host, leftover: leftover, plan: plan) }
                }
                return false
            }
        }
        return true
    }

    private func relay(host: String, leftover: Data, plan: BrowserProxyServer.Plan?) {
        guard !ended else {
            return
        }
        guard let plan, !plan.targets.isEmpty else {
            refuse(SOCKSHandshake.reply(.networkUnreachable))
            return
        }
        let route = route
        let hooks = hooks
        hooks.opened(route, host)
        let bridge = TCPBridge(
            flow: SOCKSClientFlow(connection: connection, leftover: leftover, finished: clientFinished),
            targets: plan.targets, interface: plan.interface,
            onBytes: { hooks.bytes(route, $0, $1) },
            onFinish: { [weak self] in
                hooks.closed()
                self?.queue.async { self?.finishRelay() }
            }
        )
        self.bridge = bridge
        bridge.start()
    }

    private func finishRelay() {
        bridge = nil
        guard !ended else {
            return
        }
        ended = true
        onEnd?()
    }

    private func refuse(_ reply: Data?) {
        guard let reply else {
            end()
            return
        }
        connection.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed {
            [weak self] _ in
            self?.queue.async { self?.end() }
        })
    }

    private func end() {
        guard !ended else {
            return
        }
        ended = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onEnd?()
    }
}

/// Presents an accepted SOCKS client as the app side of a `TCPBridge`, so browser
/// connections share the relay that app flows use. The bridge calls this from one
/// serial queue. "Open" here is the reply that tells the client it may start.
private final class SOCKSClientFlow: TCPFlowIO {
    private static let maxChunk = 64 * 1024

    private let connection: NWConnection
    private var leftover: Data
    /// Whether the client has finished sending, so reads after `leftover` are at EOF.
    private var finished: Bool
    private var opened = false
    private var readClosed = false
    private var writeClosed = false

    init(connection: NWConnection, leftover: Data, finished: Bool) {
        self.connection = connection
        self.leftover = leftover
        self.finished = finished
    }

    func open(completion: @escaping (Error?) -> Void) {
        opened = true
        connection.send(content: SOCKSHandshake.reply(.succeeded), completion: .contentProcessed { completion($0) })
    }

    func read(completion: @escaping (Data?, Error?) -> Void) {
        if !leftover.isEmpty {
            let data = leftover
            leftover = Data()
            completion(data, nil)
            return
        }
        guard !finished else {
            completion(Data(), nil)
            return
        }
        // The bridge calls read again only after this completes, so `finished` is
        // never read and written at the same time.
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxChunk) { [weak self] data, _, isComplete, error in
            if isComplete {
                self?.finished = true
            }
            if let data, !data.isEmpty {
                completion(data, nil)
            } else if let error {
                completion(nil, error)
            } else {
                completion(Data(), nil)
            }
        }
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func closeRead(error: Error?) {
        readClosed = true
        cancelIfDone(error: error)
    }

    func closeWrite(error: Error?) {
        writeClosed = true
        guard opened else {
            // Every target failed, so the client is still waiting for its reply.
            let reply = SOCKSHandshake.reply(.hostUnreachable)
            connection.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed {
                [connection] _ in
                connection.cancel()
            })
            return
        }
        if error == nil {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }
        cancelIfDone(error: error)
    }

    private func cancelIfDone(error: Error?) {
        guard opened else {
            return
        }
        if error != nil {
            connection.cancel()
        } else if readClosed, writeClosed {
            // Runs after the final send above, so the close reaches the client first.
            connection.send(content: nil, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
