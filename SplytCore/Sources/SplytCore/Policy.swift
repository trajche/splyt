import Foundation

/// Decides what happens to each new flow. Pure logic: the only input from the
/// outside world is `routesViaVPN`, so every path here is unit-tested.
public struct Policy: Sendable {
    public var config: SplytConfig

    public init(config: SplytConfig) {
        self.config = config
    }

    /// - Parameter routesViaVPN: Whether the kernel would currently send this
    ///   flow into a tunnel. Evaluated lazily and only when the answer matters.
    public func decide(_ flow: FlowInfo, routesViaVPN: () -> Bool) -> Decision {
        if Self.isExempt(flow) {
            return Decision(verdict: .pass, route: nil)
        }
        guard let route = matchRule(flow)?.route ?? config.unlisted else {
            return Decision(verdict: .pass, route: nil)
        }
        if route == .block {
            return Decision(verdict: .block, route: route)
        }
        // Mesh, tailnet and LAN destinations keep their system route. Binding them
        // to en0 would break them, and an exit node is not meant to carry them.
        if let ip = flow.remoteIP, AddressScope.isLocal(ip) {
            return Decision(verdict: .pass, route: route)
        }
        switch route {
        case .direct:
            return Decision(verdict: routesViaVPN() ? .direct : .pass, route: route)
        case .vpn:
            if routesViaVPN() || !config.killSwitch {
                return Decision(verdict: .pass, route: route)
            }
            return Decision(verdict: .block, route: route)
        case .block:
            return Decision(verdict: .block, route: route)
        }
    }

    /// Finds the rule for a flow. An exact signing identifier wins; otherwise the
    /// most specific path or signing-ID-prefix match does.
    public func matchRule(_ flow: FlowInfo) -> AppRule? {
        if !flow.signingID.isEmpty,
           let exact = config.rules.first(where: { $0.signingID == flow.signingID }) {
            return exact
        }
        var best: (rule: AppRule, score: Int)?
        for rule in config.rules {
            let score = Self.score(rule, flow)
            if score > 0, score > (best?.score ?? 0) {
                best = (rule, score)
            }
        }
        return best?.rule
    }

    private static func score(_ rule: AppRule, _ flow: FlowInfo) -> Int {
        var score = 0
        if let rulePath = rule.path, let path = flow.path,
           path == rulePath || path.hasPrefix(rulePath + "/") {
            score = rulePath.count
        }
        // Helpers usually extend the parent's identifier, for example
        // com.google.Chrome.helper under com.google.Chrome.
        if !rule.signingID.isEmpty, flow.signingID.hasPrefix(rule.signingID + ".") {
            score = max(score, rule.signingID.count)
        }
        return score
    }

    // MARK: - Exempt processes

    /// Traffic that must never be redirected. Rerouting a tunnel daemon's own
    /// encrypted packets would break the VPN. mDNSResponder performs DNS for every
    /// app, so a rule on it could not mean anything per app.
    private static let exemptIDs: Set<String> = [
        "netbird",
        "tailscaled",
        "com.apple.mDNSResponder",
    ]

    private static let exemptPrefixes = [
        "com.amplify2.splyt",
        "io.netbird.",
        "io.tailscale.",
        "com.tailscale.",
        "com.wireguard.",
        "com.paloaltonetworks.GlobalProtect",
        "com.openvpn.",
        "net.openvpn.",
        "net.tunnelblick.",
        "net.mullvad.",
        "com.nordvpn.",
        "ch.protonvpn.",
        "com.expressvpn.",
    ]

    private static let exemptPathSuffixes = ["/netbird", "/tailscaled", "/wireguard-go"]

    public static func isExempt(_ flow: FlowInfo) -> Bool {
        if exemptIDs.contains(flow.signingID) {
            return true
        }
        if exemptPrefixes.contains(where: { flow.signingID.hasPrefix($0) }) {
            return true
        }
        if let path = flow.path, exemptPathSuffixes.contains(where: { path.hasSuffix($0) }) {
            return true
        }
        return false
    }
}
