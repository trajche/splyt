import AppKit
import Foundation
import NetworkExtension
import Observation
import ServiceManagement
import SplytCore

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case off
        case installing
        case awaitingApproval
        case starting
        case on
    }

    private(set) var config: SplytConfig
    private(set) var phase: Phase = .loading
    private(set) var snapshot: Snapshot?
    private(set) var catalog: [CatalogApp] = []
    private(set) var netBirdNetworks: [NetBirdNetwork]?
    private(set) var isChangingExitNode = false
    private(set) var wireGuardTunnels: [WireGuardTunnelState] = []
    private(set) var changingTunnel: String?
    var errorMessage: String?

    /// What the user asked for, which the toggle shows. It differs from `phase`
    /// while the system is still installing or starting the proxy.
    private(set) var wantsOn: Bool
    /// NetBird exit node controls are optional and hidden until turned on in Settings.
    private(set) var netBirdEnabled: Bool
    private let proxy = ProxyController()
    private let installer = SystemExtensionInstaller()
    private let tunnelController = TunnelController()
    private var tunnelStats: [String: WireGuardStats] = [:]
    private var pendingSave: Task<Void, Never>?
    private var lastRestart: ContinuousClock.Instant?

    private static let configKey = "config"
    private static let enabledKey = "enabled"
    private static let activatedBuildKey = "activatedBuild"
    private static let resumeTunnelKey = "resumeTunnel"
    private static let resumeExitNodeKey = "resumeExitNode"
    private static let netBirdKey = "netBird"
    private static let pollInterval: Duration = .seconds(2)
    private static let netBirdPollEvery = 5

    init() {
        let defaults = UserDefaults.standard
        config = defaults.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(SplytConfig.self, from: $0) } ?? SplytConfig()
        wantsOn = defaults.bool(forKey: Self.enabledKey)
        netBirdEnabled = defaults.bool(forKey: Self.netBirdKey)
        proxy.onStatusChange = { [weak self] status in
            self?.statusChanged(status)
        }
        installer.onNeedsApproval = { [weak self] in
            self?.phase = .awaitingApproval
        }
        tunnelController.onChange = { [weak self] in
            self?.refreshTunnels()
        }
        Task { await self.bootstrap() }
    }

    // MARK: - Derived state

    var isOn: Bool {
        phase == .on
    }

    /// Only true while there is no way to act yet. Starting and awaiting approval
    /// stay interactive so a proxy that never comes up can still be turned off.
    var isBusy: Bool {
        phase == .loading || phase == .installing
    }

    var vpnIsUp: Bool {
        snapshot?.vpnInterface != nil
    }

    var connectedTunnel: WireGuardTunnelState? {
        wireGuardTunnels.first { $0.status == .connected }
    }

    var exitNodes: [NetBirdNetwork] {
        netBirdNetworks?.filter(\.isExitNode) ?? []
    }

    var selectedExitNode: NetBirdNetwork? {
        exitNodes.first(where: \.isSelected)
    }

    var menuBarSymbol: String {
        isOn ? "arrow.triangle.branch" : "network.slash"
    }

    var statusLine: String {
        switch phase {
        case .loading:
            return "Loading"
        case .off:
            return "All apps use normal routing"
        case .installing:
            return "Installing extension"
        case .awaitingApproval:
            return "Allow Splyt in System Settings"
        case .starting:
            return "Starting"
        case .on:
            guard let snapshot else {
                return "On"
            }
            let direct = snapshot.physicalInterface ?? "none"
            if let vpn = snapshot.vpnInterface {
                return "VPN on \(vpn), Direct on \(direct)"
            }
            return "No VPN active, all traffic on \(direct)"
        }
    }

    /// The situation most likely to surprise someone: apps set to VPN cannot connect,
    /// or two VPNs both claim all traffic.
    var warning: String? {
        if let tunnel = connectedTunnel, tunnel.info.routesAllTraffic, selectedExitNode != nil {
            return "The NetBird exit node and WireGuard (\(tunnel.info.name)) are both on. Turn one off."
        }
        guard isOn, !vpnIsUp, snapshot != nil else {
            return nil
        }
        let usesVPN = config.rules.contains { $0.route == .vpn } || config.unlisted == .vpn
        guard usesVPN else {
            return nil
        }
        return config.killSwitch
            ? "No VPN is active, so apps set to VPN are blocked."
            : "No VPN is active, so apps set to VPN are using your normal connection."
    }

    // MARK: - On and off

    /// The master switch. Off also disconnects the WireGuard tunnel and deselects
    /// the NetBird exit node, so nothing keeps routing traffic while Splyt is off;
    /// on brings back whichever of them was on.
    func setEnabled(_ enabled: Bool, resume: Bool = true) {
        wantsOn = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        Task {
            do {
                if enabled {
                    try await turnOn()
                    if resume {
                        await resumeVPNs()
                    }
                } else {
                    await suspendVPNs()
                    // With nothing saved there is nothing to disable, and saving a
                    // new configuration would raise a system prompt for no reason.
                    if proxy.hasConfiguration {
                        try await proxy.save(config: config, enabled: false)
                        proxy.stop()
                    }
                    phase = .off
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Turns off every VPN Splyt controls and remembers which were on.
    private func suspendVPNs() async {
        let defaults = UserDefaults.standard
        if let tunnel = tunnelController.tunnels.first(where: { $0.status != .disconnected && $0.status != .invalid }) {
            defaults.set(tunnel.id, forKey: Self.resumeTunnelKey)
        }
        await disconnectTunnels()
        if let node = selectedExitNode {
            defaults.set(node.id, forKey: Self.resumeExitNodeKey)
            do {
                try await NetBirdCLI.set(network: node.id, selected: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            netBirdNetworks = await NetBirdCLI.networks()
        }
    }

    private func disconnectTunnels() async {
        for tunnel in tunnelController.tunnels where tunnel.status != .disconnected && tunnel.status != .invalid {
            do {
                try await tunnelController.disconnect(tunnel.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refreshTunnels()
    }

    /// Reconnects what `suspendVPNs` turned off.
    private func resumeVPNs() async {
        let defaults = UserDefaults.standard
        let tunnelID = defaults.string(forKey: Self.resumeTunnelKey)
        let nodeID = defaults.string(forKey: Self.resumeExitNodeKey)
        forgetSuspendedVPNs()
        guard wantsOn else {
            return
        }
        if let tunnelID, tunnelController.tunnels.contains(where: { $0.id == tunnelID }) {
            changingTunnel = tunnelID
            do {
                try await tunnelController.connect(tunnelID)
            } catch {
                errorMessage = error.localizedDescription
            }
            changingTunnel = nil
            refreshTunnels()
        }
        if netBirdEnabled, nodeID != nil {
            netBirdNetworks = await NetBirdCLI.networks()
        }
        if let nodeID, exitNodes.contains(where: { $0.id == nodeID }) {
            isChangingExitNode = true
            do {
                try await NetBirdCLI.set(network: nodeID, selected: true)
            } catch {
                errorMessage = error.localizedDescription
            }
            netBirdNetworks = await NetBirdCLI.networks()
            isChangingExitNode = false
        }
    }

    /// A VPN chosen by hand replaces whatever Splyt would have brought back.
    private func forgetSuspendedVPNs() {
        UserDefaults.standard.removeObject(forKey: Self.resumeTunnelKey)
        UserDefaults.standard.removeObject(forKey: Self.resumeExitNodeKey)
    }

    /// Turning a VPN on while Splyt is off turns Splyt on too.
    private func enableForVPN() {
        guard !wantsOn else {
            return
        }
        forgetSuspendedVPNs()
        setEnabled(true, resume: false)
    }

    private func turnOn() async throws {
        phase = .installing
        try await installer.activate()
        UserDefaults.standard.set(Self.currentBuild, forKey: Self.activatedBuildKey)
        // Approval can take minutes, and the user may have turned Splyt off meanwhile.
        guard wantsOn else {
            return
        }
        phase = .starting
        try await proxy.save(config: config, enabled: true)
        try proxy.start()
    }

    private static var currentBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// On-demand keeps the proxy connected across launches, so a new build would
    /// otherwise keep running the old extension. Replacing it restarts the proxy, so
    /// this runs once per build rather than on every launch.
    private func replaceExtensionIfOutdated() async {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.activatedBuildKey) != Self.currentBuild else {
            return
        }
        do {
            try await installer.activate()
            defaults.set(Self.currentBuild, forKey: Self.activatedBuildKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the extension and its configuration from the system.
    func uninstall() {
        wantsOn = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        Task {
            do {
                proxy.stop()
                try await proxy.remove()
                try await installer.deactivate()
                phase = .off
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        wantsOn = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        errorMessage = error.localizedDescription
        phase = proxy.status == .connected ? .on : .off
    }

    private func statusChanged(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            phase = .on
            Task { await push() }
        case .connecting, .reasserting:
            if phase != .on {
                phase = .starting
            }
        case .disconnecting, .disconnected:
            if phase == .on || phase == .starting {
                phase = wantsOn ? .starting : .off
            }
            if status == .disconnected, wantsOn {
                restartProxy()
            }
        case .invalid:
            if phase == .on {
                phase = .off
            }
        @unknown default:
            break
        }
    }

    /// Replacing the extension, or a crash, stops the proxy, and on-demand only
    /// restarts it on the next network change. Until then rules would not apply,
    /// so the app restarts it, at most once per interval in case it keeps failing.
    private func restartProxy() {
        let now = ContinuousClock.now
        if let lastRestart, now - lastRestart < .seconds(10) {
            return
        }
        lastRestart = now
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard wantsOn, proxy.status == .disconnected else {
                return
            }
            do {
                try proxy.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Rules

    func route(for rule: AppRule) -> Route {
        config.rules.first { $0.id == rule.id }?.route ?? rule.route
    }

    func setRoute(_ route: Route, for rule: AppRule) {
        if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
            config.rules[index].route = route
        } else {
            var updated = rule
            updated.route = route
            config.rules.append(updated)
            config.rules.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        configChanged()
    }

    func add(_ app: CatalogApp, route: Route) {
        setRoute(route, for: AppRule(signingID: app.signingID, path: app.path, name: app.name, route: route))
    }

    func remove(_ rule: AppRule) {
        config.rules.removeAll { $0.id == rule.id }
        configChanged()
    }

    func setUnlisted(_ route: Route?) {
        config.unlisted = route
        configChanged()
    }

    func setKillSwitch(_ enabled: Bool) {
        config.killSwitch = enabled
        configChanged()
    }

    /// Turning this on for the first time creates the password the extension uses.
    func setBrowserProxy(enabled: Bool) {
        var settings = config.browserProxy ?? BrowserProxySettings(enabled: enabled, token: Self.newToken())
        settings.enabled = enabled
        config.browserProxy = settings
        configChanged()
    }

    /// Disconnects paired browsers until they are given the new pairing code.
    func regenerateBrowserToken() {
        config.browserProxy?.token = Self.newToken()
        configChanged()
    }

    private static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func rule(for activity: AppActivity) -> AppRule? {
        Policy(config: config).matchRule(FlowInfo(signingID: activity.signingID, path: activity.path))
    }

    /// Rule for an app seen in the activity list, using the enclosing `.app` when there is one.
    func draftRule(for activity: AppActivity, route: Route) -> AppRule {
        let bundlePath = activity.path.flatMap { path -> String? in
            guard let range = path.range(of: ".app/") else {
                return nil
            }
            return String(path[..<range.lowerBound]) + ".app"
        }
        let path = bundlePath ?? activity.path
        return AppRule(signingID: activity.signingID, path: path, name: displayName(for: activity), route: route)
    }

    func displayName(for activity: AppActivity) -> String {
        if let path = activity.path, let range = path.range(of: ".app/") {
            let bundle = path[..<range.lowerBound]
            return bundle.split(separator: "/").last.map(String.init) ?? activity.id
        }
        return activity.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? activity.signingID
    }

    private func configChanged() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
        Task { await push() }
        // Saving is slower than messaging the extension and only has to outlive a
        // restart, so a burst of changes is written once.
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.isOn else {
                return
            }
            do {
                try await self.proxy.save(config: self.config, enabled: true)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func push() async {
        _ = await proxy.send(.apply(config))
    }

    // MARK: - NetBird

    func setNetBirdEnabled(_ enabled: Bool) {
        netBirdEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.netBirdKey)
        if !enabled {
            netBirdNetworks = nil
            UserDefaults.standard.removeObject(forKey: Self.resumeExitNodeKey)
            return
        }
        Task {
            netBirdNetworks = await NetBirdCLI.networks()
        }
    }

    func setExitNode(_ network: NetBirdNetwork, selected: Bool) {
        if selected {
            enableForVPN()
        }
        isChangingExitNode = true
        Task {
            defer { isChangingExitNode = false }
            do {
                try await NetBirdCLI.set(network: network.id, selected: selected)
            } catch {
                errorMessage = error.localizedDescription
            }
            netBirdNetworks = await NetBirdCLI.networks()
        }
    }

    // MARK: - WireGuard

    /// Imports a wg-quick file, named after the file.
    func importWireGuard(from url: URL) {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        Task {
            do {
                let ignored = try await tunnelController.add(text: text, name: name)
                if !ignored.isEmpty {
                    errorMessage = "Imported \(name). Splyt ignores these settings: \(ignored.joined(separator: ", "))."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setTunnel(_ tunnel: WireGuardTunnelState, connected: Bool) {
        if connected {
            enableForVPN()
        }
        changingTunnel = tunnel.id
        Task {
            defer { changingTunnel = nil }
            do {
                if connected {
                    try await ensureExtension()
                    try await tunnelController.connect(tunnel.id)
                } else {
                    try await tunnelController.disconnect(tunnel.id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshTunnels()
        }
    }

    func removeTunnel(_ tunnel: WireGuardTunnelState) {
        Task {
            do {
                try await tunnelController.remove(tunnel.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The tunnel runs in the same system extension as the proxy, which may not be
    /// installed yet, or may be an older build.
    private func ensureExtension() async throws {
        guard UserDefaults.standard.string(forKey: Self.activatedBuildKey) != Self.currentBuild else {
            return
        }
        try await installer.activate()
        UserDefaults.standard.set(Self.currentBuild, forKey: Self.activatedBuildKey)
    }

    private func refreshTunnels() {
        wireGuardTunnels = tunnelController.tunnels.map {
            WireGuardTunnelState(info: $0.info, status: $0.status, stats: tunnelStats[$0.id])
        }
    }

    private func pollTunnelStats() async {
        var stats: [String: WireGuardStats] = [:]
        for tunnel in tunnelController.tunnels where tunnel.status == .connected {
            stats[tunnel.id] = await tunnelController.stats(tunnel.id)
        }
        tunnelStats = stats
        refreshTunnels()
    }

    // MARK: - Launch at login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Lifecycle

    private func bootstrap() async {
        catalog = await Task.detached(priority: .utility) { AppCatalog.scan() }.value
        do {
            try await proxy.load()
            try await tunnelController.load()
        } catch {
            errorMessage = error.localizedDescription
        }
        if phase == .loading {
            phase = proxy.status == .connected ? .on : .off
        }
        if wantsOn {
            if proxy.status == .connected {
                await replaceExtensionIfOutdated()
            } else {
                setEnabled(true)
            }
        } else {
            // Splyt's own tunnel never runs while Splyt is off, for example one
            // that on-demand brought back after a reboot.
            await disconnectTunnels()
        }
        await pollForever()
    }

    private func pollForever() async {
        var tick = 0
        while !Task.isCancelled {
            if netBirdEnabled, tick % Self.netBirdPollEvery == 0 {
                netBirdNetworks = await NetBirdCLI.networks()
            }
            tick += 1
            if let data = await proxy.send(.snapshot) {
                snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
            } else {
                snapshot = nil
            }
            await pollTunnelStats()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

/// A WireGuard tunnel as the views show it.
struct WireGuardTunnelState: Identifiable, Equatable {
    let info: WireGuardTunnelInfo
    let status: NEVPNStatus
    let stats: WireGuardStats?

    var id: String { info.id }

    var isOn: Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch status {
        case .connected:
            guard let handshake = stats?.lastHandshake else {
                return "Connected, waiting for handshake"
            }
            let seconds = max(0, Int(-handshake.timeIntervalSinceNow))
            // WireGuard renews keys every two minutes while traffic flows, so an old
            // handshake means the server is not answering.
            if seconds > 180 {
                return "No handshake for \(seconds / 60) min"
            }
            return "Connected, handshake \(seconds)s ago"
        case .connecting:
            return "Connecting"
        case .reasserting:
            return "Reconnecting"
        case .disconnecting:
            return "Disconnecting"
        case .disconnected, .invalid:
            return "Off"
        @unknown default:
            return "Off"
        }
    }
}
