import Foundation
import Network

/// The parts of `NEAppProxyTCPFlow` the bridge uses. A protocol keeps the bridge
/// testable, since flows can only be created by the system inside an extension.
public protocol TCPFlowIO: AnyObject {
    func open(completion: @escaping (Error?) -> Void)
    /// Empty or nil data with no error means the app finished sending.
    func read(completion: @escaping (Data?, Error?) -> Void)
    func write(_ data: Data, completion: @escaping (Error?) -> Void)
    func closeRead(error: Error?)
    func closeWrite(error: Error?)
}

/// Relays one app TCP flow over a connection pinned to an interface.
public final class TCPBridge {
    private static let maxChunk = 64 * 1024
    /// How long one direction may stay open after the other has finished.
    private static let halfCloseLinger: TimeInterval = 120
    private static let connectTimeout = 15

    private let flow: TCPFlowIO
    private var targets: [NWEndpoint]
    private let interface: NWInterface?
    private let onBytes: (_ up: UInt64, _ down: UInt64) -> Void
    private let onFinish: () -> Void
    private let queue = DispatchQueue(label: "com.amplify2.splyt.tcp")

    private var connection: NWConnection?
    private var established = false
    private var finished = false
    private var upDone = false
    private var downDone = false
    private var lingerTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - targets: Endpoints to try in order, such as a hostname then its IP.
    ///   - interface: Required interface. There is deliberately no fallback, so a
    ///     Direct flow can never slip into the VPN.
    public init(
        flow: TCPFlowIO,
        targets: [NWEndpoint],
        interface: NWInterface?,
        onBytes: @escaping (_ up: UInt64, _ down: UInt64) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.flow = flow
        self.targets = targets
        self.interface = interface
        self.onBytes = onBytes
        self.onFinish = onFinish
    }

    public func start() {
        queue.async { self.connectNext() }
    }

    private func connectNext() {
        guard !finished else {
            return
        }
        guard !targets.isEmpty else {
            finish(error: nil)
            return
        }
        let target = targets.removeFirst()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Self.connectTimeout
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let interface {
            parameters.requiredInterface = interface
        }
        let connection = NWConnection(to: target, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state, of: connection)
        }
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State, of connection: NWConnection) {
        guard connection === self.connection, !finished else {
            return
        }
        switch state {
        case .ready:
            established = true
            flow.open { [weak self] error in
                guard let self else {
                    return
                }
                self.queue.async {
                    if let error {
                        self.finish(error: error)
                    } else {
                        self.pumpUp()
                        self.pumpDown()
                    }
                }
            }
        case .waiting(let error), .failed(let error):
            if !established {
                // Waiting means no usable path right now. The app can retry
                // sooner than a parked connection would recover.
                connection.stateUpdateHandler = nil
                connection.cancel()
                connectNext()
            } else if downDone {
                finish(error: error)
            }
            // Otherwise leave the connection alone. After an orderly close in both
            // directions it reports failed(ENETDOWN) while received data is still
            // buffered, and cancelling here would discard that data. The pending
            // receive drains the buffer and then reports completion or the error.
        default:
            break
        }
    }

    /// App to remote.
    private func pumpUp() {
        flow.read { [weak self] data, error in
            guard let self else {
                return
            }
            self.queue.async {
                guard !self.finished else {
                    return
                }
                if let error {
                    self.finish(error: error)
                } else if let data, !data.isEmpty {
                    self.connection?.send(content: data, completion: .contentProcessed { sendError in
                        self.queue.async {
                            if let sendError {
                                self.finish(error: sendError)
                            } else {
                                self.onBytes(UInt64(data.count), 0)
                                self.pumpUp()
                            }
                        }
                    })
                } else {
                    self.connection?.send(
                        content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .idempotent
                    )
                    self.flow.closeRead(error: nil)
                    self.upDone = true
                    self.directionFinished()
                }
            }
        }
    }

    /// Remote to app.
    private func pumpDown() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: Self.maxChunk) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.finished else {
                return
            }
            if let data, !data.isEmpty {
                self.flow.write(data) { writeError in
                    self.queue.async {
                        if let writeError {
                            self.finish(error: writeError)
                        } else {
                            self.onBytes(0, UInt64(data.count))
                            self.continueDown(isComplete: isComplete, error: error)
                        }
                    }
                }
            } else {
                self.continueDown(isComplete: isComplete, error: error)
            }
        }
    }

    private func continueDown(isComplete: Bool, error: NWError?) {
        guard !finished else {
            return
        }
        if isComplete {
            flow.closeWrite(error: nil)
            downDone = true
            directionFinished()
        } else if let error {
            finish(error: error)
        } else {
            pumpDown()
        }
    }

    private func directionFinished() {
        if upDone, downDone {
            finish(error: nil, flowClosed: true)
        } else if lingerTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.halfCloseLinger)
            timer.setEventHandler { [weak self] in
                self?.finish(error: nil)
            }
            timer.resume()
            lingerTimer = timer
        }
    }

    private func finish(error: Error?, flowClosed: Bool = false) {
        guard !finished else {
            return
        }
        finished = true
        lingerTimer?.cancel()
        lingerTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        if !flowClosed {
            if !upDone {
                flow.closeRead(error: error)
            }
            if !downDone {
                flow.closeWrite(error: error)
            }
        }
        onFinish()
    }
}
