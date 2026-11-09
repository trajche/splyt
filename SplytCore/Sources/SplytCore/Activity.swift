import Foundation

/// Traffic seen for one app since the proxy started.
public struct AppActivity: Codable, Identifiable, Hashable, Sendable {
    public var signingID: String
    public var path: String?
    public var lastRemote: String?
    public var lastVerdict: Verdict
    public var lastRoute: Route?
    public var flows: Int
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var lastSeen: Date

    public var id: String { signingID.isEmpty ? (path ?? "unknown") : signingID }
}

/// State reported by the extension to the app.
public struct Snapshot: Codable, Sendable {
    public var activeFlows: Int
    /// Interface carrying the default route, when that is a tunnel.
    public var vpnInterface: String?
    public var physicalInterface: String?
    public var apps: [AppActivity]
    /// Why the browser proxy is not serving, when it should be.
    public var browserProxyProblem: String?

    public init(activeFlows: Int, vpnInterface: String?, physicalInterface: String?, apps: [AppActivity]) {
        self.activeFlows = activeFlows
        self.vpnInterface = vpnInterface
        self.physicalInterface = physicalInterface
        self.apps = apps
    }
}

/// Messages sent from the app to the running extension.
public enum ProviderRequest: Codable, Sendable {
    case apply(SplytConfig)
    case snapshot
}

/// Bounded, thread-safe per-app counters.
public final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [String: AppActivity] = [:]
    private var active = 0
    private let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = capacity
    }

    public func record(_ flow: FlowInfo, remote: String?, decision: Decision, tracked: Bool, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(signingID: flow.signingID, path: flow.path)
        var entry = apps[key] ?? AppActivity(
            signingID: flow.signingID, path: flow.path, lastRemote: nil, lastVerdict: decision.verdict,
            lastRoute: decision.route, flows: 0, bytesUp: 0, bytesDown: 0, lastSeen: now
        )
        entry.path = flow.path ?? entry.path
        entry.lastRemote = remote ?? entry.lastRemote
        entry.lastVerdict = decision.verdict
        entry.lastRoute = decision.route
        entry.flows += 1
        entry.lastSeen = now
        apps[key] = entry
        if tracked {
            active += 1
        }
        evictIfNeeded()
    }

    public func add(signingID: String, path: String?, up: UInt64 = 0, down: UInt64 = 0, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(signingID: signingID, path: path)
        apps[key]?.bytesUp &+= up
        apps[key]?.bytesDown &+= down
        apps[key]?.lastSeen = now
    }

    public func flowFinished() {
        lock.lock()
        defer { lock.unlock() }
        active = max(0, active - 1)
    }

    public func snapshot(vpnInterface: String?, physicalInterface: String?) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            activeFlows: active,
            vpnInterface: vpnInterface,
            physicalInterface: physicalInterface,
            apps: apps.values.sorted { $0.lastSeen > $1.lastSeen }
        )
    }

    private func evictIfNeeded() {
        guard apps.count > capacity,
              let oldest = apps.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key else {
            return
        }
        apps[oldest] = nil
    }

    private static func key(signingID: String, path: String?) -> String {
        signingID.isEmpty ? (path ?? "unknown") : signingID
    }
}
