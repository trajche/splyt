import Foundation
import Network
import SplytCore

// Checks the routing assumptions Splyt depends on, on the real network and without
// the system extension: what owns the default route, and whether a connection
// pinned to an interface really leaves through it.
//
// Usage: swift run splyt-probe [host] [port]

let host = CommandLine.arguments.dropFirst().first ?? "1.1.1.1"
let port = CommandLine.arguments.dropFirst(2).first.flatMap { UInt16($0) } ?? 443
let queue = DispatchQueue(label: "probe")

func report(_ label: String, _ value: String) {
    print(label.padding(toLength: 30, withPad: " ", startingAt: 0), value)
}

func connect(via interface: NWInterface) -> String {
    let done = DispatchSemaphore(value: 0)
    let result = NSLock()
    var outcome = "timed out"
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 5
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.requiredInterface = interface
    let connection = NWConnection(
        host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters
    )
    connection.stateUpdateHandler = { state in
        result.lock()
        defer { result.unlock() }
        switch state {
        case .ready:
            let local = connection.currentPath?.localEndpoint.map { "\($0)" } ?? "?"
            let used = connection.currentPath?.availableInterfaces.first?.name ?? "?"
            outcome = "connected, local \(local), path \(used)"
            done.signal()
        case .waiting(let error), .failed(let error):
            outcome = "refused: \(error)"
            done.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    _ = done.wait(timeout: .now() + 7)
    connection.cancel()
    result.lock()
    defer { result.unlock() }
    return outcome
}

report("default route via", Egress.interface(to: Egress.probeAddress) ?? "none")
report("route to \(host) via", Egress.interface(to: host) ?? "none (not an IP, or no route)")
report("VPN owns default route", Egress.routesViaVPN(to: nil) ? "yes" : "no")

let ready = DispatchSemaphore(value: 0)
let monitor = NWPathMonitor()
let pathLock = NSLock()
var interfaces: [NWInterface] = []
monitor.pathUpdateHandler = { path in
    pathLock.lock()
    interfaces = path.availableInterfaces
    pathLock.unlock()
    ready.signal()
}
monitor.start(queue: queue)
_ = ready.wait(timeout: .now() + 3)
monitor.cancel()

pathLock.lock()
let seen = interfaces
pathLock.unlock()
report("available interfaces", seen.map { "\($0.name)(\($0.type))" }.joined(separator: " "))
let physical = PhysicalInterfaceMonitor.physical(from: seen)
report("Direct would pin to", physical?.name ?? "none")

for interface in seen where interface.type != .loopback {
    report("connect \(host):\(port) on \(interface.name)", connect(via: interface))
}
