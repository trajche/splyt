import Dispatch
import Foundation
import SplytCore

// Runs the browser proxy on its own, without the system extension, using the same
// planner the extension uses. Lets the Firefox extension be tested on the real
// network. Each connection is logged as "<route> <host>".
//
// Usage: swift run splyt-socks <token> [vpn port] [direct port]

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
guard let token = arguments.first else {
    print("usage: splyt-socks <token> [vpn port] [direct port]")
    exit(2)
}
let physical = PhysicalInterfaceMonitor()
var hooks = BrowserProxyServer.Hooks()
hooks.opened = { route, host in
    print(route.rawValue, host)
}
let server = BrowserProxyServer(planner: BrowserProxyServer.livePlanner(physical: physical), hooks: hooks)
let settings = BrowserProxySettings(
    enabled: true,
    vpnPort: arguments.dropFirst().first.flatMap(UInt16.init) ?? 18230,
    directPort: arguments.dropFirst(2).first.flatMap(UInt16.init) ?? 18231,
    token: token
)
// The monitor reports interfaces asynchronously.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    server.apply(settings)
    print("ready", settings.vpnPort, settings.directPort)
}
dispatchMain()
