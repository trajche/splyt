import Foundation

/// What should happen to an app's internet traffic.
public enum Route: String, Codable, CaseIterable, Sendable {
    /// Use the system VPN (NetBird exit node, WireGuard, ...).
    case vpn
    /// Skip the VPN and leave through the physical interface.
    case direct
    /// Refuse the app's outbound connections.
    case block
}

/// A per-app rule. Rules match on code-signing identifier, on-disk path, or both.
public struct AppRule: Codable, Hashable, Identifiable, Sendable {
    public var signingID: String
    /// Path of an `.app` bundle or an executable. Anything inside a bundle path
    /// matches, which is what catches Electron and Chromium helper processes.
    public var path: String?
    public var name: String
    public var route: Route

    public var id: String { signingID.isEmpty ? (path ?? name) : signingID }

    public init(signingID: String, path: String? = nil, name: String, route: Route) {
        self.signingID = signingID
        self.path = path
        self.name = name
        self.route = route
    }
}

/// Local SOCKS5 proxies used by the browser extension.
public struct BrowserProxySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var vpnPort: UInt16
    public var directPort: UInt16
    /// SOCKS password. It stops other local software, and web pages making requests
    /// to 127.0.0.1, from using the Direct listener to step around the VPN.
    public var token: String

    public init(enabled: Bool, vpnPort: UInt16 = 18230, directPort: UInt16 = 18231, token: String) {
        self.enabled = enabled
        self.vpnPort = vpnPort
        self.directPort = directPort
        self.token = token
    }

    /// Everything the browser extension needs, as one string to paste.
    public var pairingCode: String {
        "\(vpnPort):\(directPort):\(token)"
    }
}

public struct SplytConfig: Codable, Equatable, Sendable {
    /// Rule set for specific apps.
    public var rules: [AppRule]
    /// Route for apps without a rule. `nil` leaves them on normal system routing.
    public var unlisted: Route?
    /// Refuse connections from VPN-routed apps whenever the VPN is down,
    /// rather than letting them fall back to the physical interface.
    public var killSwitch: Bool
    /// `nil` until the browser proxy is first turned on.
    public var browserProxy: BrowserProxySettings?

    public init(
        rules: [AppRule] = [], unlisted: Route? = nil, killSwitch: Bool = true,
        browserProxy: BrowserProxySettings? = nil
    ) {
        self.rules = rules
        self.unlisted = unlisted
        self.killSwitch = killSwitch
        self.browserProxy = browserProxy
    }
}

/// Everything known about a flow at the moment it is classified.
public struct FlowInfo: Sendable {
    public var signingID: String
    public var path: String?
    /// Numeric remote address, when the system supplied one.
    public var remoteIP: String?

    public init(signingID: String, path: String? = nil, remoteIP: String? = nil) {
        self.signingID = signingID
        self.path = path
        self.remoteIP = remoteIP
    }
}

public enum Verdict: String, Codable, Sendable {
    /// Hand the flow back to the kernel unchanged.
    case pass
    /// Proxy the flow out of the physical interface.
    case direct
    /// Refuse the flow.
    case block
}

public struct Decision: Equatable, Sendable {
    public var verdict: Verdict
    /// The route that produced the verdict, or `nil` for flows Splyt leaves alone.
    public var route: Route?

    public init(verdict: Verdict, route: Route?) {
        self.verdict = verdict
        self.route = route
    }
}

public enum SplytConstants {
    public static let extensionBundleID = "com.amplify2.splyt.proxy"
    /// Key in the provider configuration that holds the encoded `SplytConfig`.
    public static let configKey = "config"
    /// Prefix of Activity entries for browser proxy traffic, which belongs to no app.
    public static let browserActivityPrefix = "com.amplify2.splyt.browser."
    /// Key in a WireGuard tunnel's provider configuration that holds its
    /// `WireGuardTunnelInfo`. Never the keys: that file is world-readable.
    public static let tunnelInfoKey = "wireguard"
    /// Start option carrying the wg-quick text, private key included.
    public static let tunnelConfigOption = "wgQuickConfig"
}
