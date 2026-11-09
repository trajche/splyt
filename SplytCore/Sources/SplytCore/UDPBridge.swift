import Foundation
import Network

/// The parts of `NEAppProxyUDPFlow` the bridge uses.
public protocol UDPFlowIO: AnyObject {
    func open(completion: @escaping (Error?) -> Void)
    /// Nil or empty datagrams with no error means the flow ended.
    func readDatagrams(completion: @escaping ([(Data, NWEndpoint)]?, Error?) -> Void)
    func writeDatagrams(_ datagrams: [(Data, NWEndpoint)], completion: @escaping (Error?) -> Void)
    func closeRead(error: Error?)
    func closeWrite(error: Error?)
}

/// Relays one app UDP flow. A UDP socket can talk to many peers, so each remote
/// endpoint gets its own pinned connection.
public final class UDPBridge {
    private static let idleTimeout: TimeInterval = 90
    private static let idleCheckInterval: TimeInterval = 15
    private static let maxPeers = 256

    private let flow: UDPFlowIO
    private let interface: NWInterface?
    private let onBytes: (_ up: UInt64, _ down: UInt64) -> Void
    private let onFinish: () -> Void
    private let queue = DispatchQueue(label: "com.amplify2.splyt.udp")

    private var peers: [NWEndpoint: NWConnection] = [:]
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    private var finished = false

    public init(
        flow: UDPFlowIO,
        interface: NWInterface?,
        onBytes: @escaping (_ up: UInt64, _ down: UInt64) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.flow = flow
        self.interface = interface
        self.onBytes = onBytes
        self.onFinish = onFinish
    }

    public func start() {
        flow.open { [weak self] error in
            guard let self else {
                return
            }
            self.queue.async {
                if let error {
                    self.finish(error: error)
                } else {
                    self.startIdleTimer()
                    self.readLoop()
                }
            }
        }
    }

    private func readLoop() {
        flow.readDatagrams { [weak self] datagrams, error in
            guard let self else {
                return
            }
            self.queue.async {
                guard !self.finished else {
                    return
                }
                if let error {
                    self.finish(error: error)
                } else if let datagrams, !datagrams.isEmpty {
                    self.lastActivity = Date()
                    for (payload, endpoint) in datagrams {
                        self.send(payload, to: endpoint)
                    }
                    self.readLoop()
                } else {
                    self.finish(error: nil)
                }
            }
        }
    }

    private func send(_ payload: Data, to endpoint: NWEndpoint) {
        let connection = peers[endpoint] ?? makePeer(endpoint)
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if error == nil {
                self?.onBytes(UInt64(payload.count), 0)
            }
        })
    }

    private func makePeer(_ endpoint: NWEndpoint) -> NWConnection {
        if peers.count >= Self.maxPeers, let victim = peers.first {
            victim.value.cancel()
            peers[victim.key] = nil
        }
        let parameters = NWParameters.udp
        if let interface {
            parameters.requiredInterface = interface
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        peers[endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            if case .failed = state, self.peers[endpoint] === connection {
                self.peers[endpoint] = nil
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receive(from: connection, endpoint: endpoint)
        return connection
    }

    private func receive(from connection: NWConnection, endpoint: NWEndpoint) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, !self.finished else {
                return
            }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                self.flow.writeDatagrams([(data, endpoint)]) { [weak self] writeError in
                    guard let self else {
                        return
                    }
                    self.queue.async {
                        if let writeError {
                            self.finish(error: writeError)
                        } else {
                            self.onBytes(0, UInt64(data.count))
                        }
                    }
                }
            }
            if error == nil {
                self.receive(from: connection, endpoint: endpoint)
            }
        }
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleCheckInterval, repeating: Self.idleCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            if Date().timeIntervalSince(self.lastActivity) > Self.idleTimeout {
                self.finish(error: nil)
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func finish(error: Error?) {
        guard !finished else {
            return
        }
        finished = true
        idleTimer?.cancel()
        idleTimer = nil
        for connection in peers.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        peers.removeAll()
        flow.closeRead(error: error)
        flow.closeWrite(error: error)
        onFinish()
    }
}
