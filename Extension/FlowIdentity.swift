import Darwin
import Foundation
import Network
import NetworkExtension
import SplytCore

enum FlowIdentity {
    /// Builds what the policy needs to know about a flow.
    static func info(for flow: NEAppProxyFlow, remote: Network.NWEndpoint?) -> FlowInfo {
        FlowInfo(
            signingID: flow.metaData.sourceAppSigningIdentifier,
            path: executablePath(flow.metaData.sourceAppAuditToken),
            remoteIP: remote.flatMap(numericHost)
        )
    }

    static func numericHost(_ endpoint: Network.NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else {
            return nil
        }
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)"
        default:
            return nil
        }
    }

    static func describe(_ endpoint: Network.NWEndpoint?, hostname: String?) -> String? {
        guard let endpoint else {
            return hostname
        }
        guard case .hostPort(_, let port) = endpoint else {
            return hostname ?? "\(endpoint)"
        }
        return hostname.map { "\($0):\(port)" } ?? "\(endpoint)"
    }

    /// Path lookup is best effort. The signing identifier remains the primary key,
    /// and the process may already have exited.
    private static func executablePath(_ token: Data?) -> String? {
        guard let token, token.count == MemoryLayout<audit_token_t>.size else {
            return nil
        }
        let audit = token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        // audit_token_to_pid() is this field; reading it avoids linking libbsm.
        let pid = pid_t(bitPattern: audit.val.5)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
