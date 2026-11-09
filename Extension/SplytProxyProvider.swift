import Foundation
import Network
import NetworkExtension
import OSLog
import SplytCore

/// Sees every outbound flow on the Mac and acts on the policy's verdict:
/// - pass: return false, so the kernel routes the flow as if Splyt were absent.
/// - direct: claim the flow and relay it through a connection pinned to the
///   physical interface, which takes it around the VPN.
/// - block: claim the flow and refuse it.
///
/// If this process dies, flows fall back to system routing. With an exit node
/// selected that is the VPN, so a crash cannot expose VPN-routed apps.
final class SplytProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {
    private let log = Logger(subsystem: "com.amplify2.splyt", category: "proxy")
    private let activity = ActivityLog()
    private let physical = PhysicalInterfaceMonitor()
    private let lock = NSLock()
    private var policy = Policy(config: SplytConfig())
    private var bridges: [ObjectIdentifier: AnyObject] = [:]
    private lazy var browserProxy = BrowserProxyServer(
        planner: BrowserProxyServer.livePlanner(physical: physical),
        hooks: browserHooks()
    )

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        loadSavedConfig()

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [.TCP, .UDP].map { (networkProtocol: NENetworkRule.`Protocol`) in
            NENetworkRule(
                remoteNetworkEndpoint: nil, remotePrefix: 0,
                localNetworkEndpoint: nil, localPrefix: 0,
                protocol: networkProtocol, direction: .outbound
            )
        }
        setTunnelNetworkSettings(settings) { [log] error in
            if let error {
                log.error("Could not apply network settings: \(error.localizedDescription, privacy: .public)")
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("Stopping, reason \(reason.rawValue)")
        browserProxy.stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = try? JSONDecoder().decode(ProviderRequest.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        switch request {
        case .apply(let config):
            setPolicy(Policy(config: config))
            completionHandler?(Data())
        case .snapshot:
            let defaultInterface = Egress.interface(to: Egress.probeAddress)
            var snapshot = activity.snapshot(
                vpnInterface: defaultInterface.flatMap { Egress.isTunnel($0) ? $0 : nil },
                physicalInterface: physical.current?.name
            )
            snapshot.browserProxyProblem = browserProxy.problem
            completionHandler?(try? JSONEncoder().encode(snapshot))
        }
    }

    // MARK: - Flows

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcp = flow as? NEAppProxyTCPFlow {
            return handle(tcp)
        }
        if let udp = flow as? NEAppProxyUDPFlow {
            // The system lands here when a UDP client has not named a target yet.
            return handle(udp, remote: nil)
        }
        return false
    }

    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        handle(flow, remote: remoteEndpoint)
    }

    private func handle(_ flow: NEAppProxyTCPFlow) -> Bool {
        let remote = flow.remoteFlowEndpoint
        let info = FlowIdentity.info(for: flow, remote: remote)
        let decision = classify(info)
        activity.record(
            info, remote: FlowIdentity.describe(remote, hostname: flow.remoteHostname),
            decision: decision, tracked: decision.verdict == .direct
        )
        switch decision.verdict {
        case .pass:
            return false
        case .block:
            refuse(flow)
            return true
        case .direct:
            guard let interface = physical.current else {
                activity.flowFinished()
                refuse(flow)
                return true
            }
            // Prefer the name: Direct traffic should resolve outside the VPN, or a
            // CDN could answer with an address chosen for the exit node's location.
            var targets = [remote]
            if let hostname = flow.remoteHostname, !hostname.isEmpty,
               case .hostPort(_, let port) = remote {
                targets.insert(Network.NWEndpoint.hostPort(host: .name(hostname, nil), port: port), at: 0)
            }
            let key = ObjectIdentifier(flow)
            let bridge = TCPBridge(
                flow: TCPFlowAdapter(flow), targets: targets, interface: interface,
                onBytes: counter(for: info),
                onFinish: { [weak self] in self?.bridgeFinished(key) }
            )
            retain(bridge, key)
            bridge.start()
            return true
        }
    }

    private func handle(_ flow: NEAppProxyUDPFlow, remote: Network.NWEndpoint?) -> Bool {
        let info = FlowIdentity.info(for: flow, remote: remote)
        let decision = classify(info)
        activity.record(
            info, remote: FlowIdentity.describe(remote, hostname: flow.remoteHostname),
            decision: decision, tracked: decision.verdict == .direct
        )
        switch decision.verdict {
        case .pass:
            return false
        case .block:
            refuse(flow)
            return true
        case .direct:
            guard let interface = physical.current else {
                activity.flowFinished()
                refuse(flow)
                return true
            }
            let key = ObjectIdentifier(flow)
            let bridge = UDPBridge(
                flow: UDPFlowAdapter(flow), interface: interface,
                onBytes: counter(for: info),
                onFinish: { [weak self] in self?.bridgeFinished(key) }
            )
            retain(bridge, key)
            bridge.start()
            return true
        }
    }

    private func classify(_ info: FlowInfo) -> Decision {
        currentPolicy().decide(info) { Egress.routesViaVPN(to: info.remoteIP) }
    }

    private func refuse(_ flow: NEAppProxyFlow) {
        let error = NEAppProxyFlowError(.refused)
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }

    private func counter(for info: FlowInfo) -> (UInt64, UInt64) -> Void {
        let activity = self.activity
        return { up, down in
            activity.add(signingID: info.signingID, path: info.path, up: up, down: down)
        }
    }

    // MARK: - Browser proxy

    private func browserHooks() -> BrowserProxyServer.Hooks {
        let activity = self.activity
        var hooks = BrowserProxyServer.Hooks()
        hooks.opened = { route, host in
            activity.record(
                Self.browserFlow(route), remote: host,
                decision: Decision(verdict: route == .direct ? .direct : .pass, route: route),
                tracked: true
            )
        }
        hooks.bytes = { route, up, down in
            let flow = Self.browserFlow(route)
            activity.add(signingID: flow.signingID, path: flow.path, up: up, down: down)
        }
        hooks.closed = {
            activity.flowFinished()
        }
        return hooks
    }

    /// The Activity row for browser traffic on `route`.
    private static func browserFlow(_ route: Route) -> FlowInfo {
        FlowInfo(
            signingID: SplytConstants.browserActivityPrefix + route.rawValue,
            path: route == .vpn ? "Browser (VPN)" : "Browser (Direct)"
        )
    }

    // MARK: - State

    private func loadSavedConfig() {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?[SplytConstants.configKey] as? Data,
              let config = try? JSONDecoder().decode(SplytConfig.self, from: data) else {
            log.notice("No saved configuration; leaving all traffic alone")
            return
        }
        setPolicy(Policy(config: config))
    }

    private func currentPolicy() -> Policy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    private func setPolicy(_ policy: Policy) {
        lock.lock()
        self.policy = policy
        lock.unlock()
        browserProxy.apply(policy.config.browserProxy)
    }

    private func retain(_ bridge: AnyObject, _ key: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        bridges[key] = bridge
    }

    private func bridgeFinished(_ key: ObjectIdentifier) {
        activity.flowFinished()
        lock.lock()
        defer { lock.unlock() }
        bridges[key] = nil
    }
}
