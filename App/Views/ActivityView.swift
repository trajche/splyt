import SplytCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                Table(snapshot.apps) {
                    TableColumn("App") { app in
                        HStack(spacing: 8) {
                            AppIcon(path: bundlePath(app), size: 18)
                            Text(model.displayName(for: app)).lineLimit(1)
                        }
                    }
                    TableColumn("Route") { app in
                        Text(app.lastVerdict.title(route: app.lastRoute, vpnIsUp: model.vpnIsUp))
                    }
                    .width(90)
                    TableColumn("Destination") { app in
                        Text(app.lastRemote ?? "").lineLimit(1).foregroundStyle(.secondary)
                    }
                    TableColumn("Flows") { app in
                        Text(app.flows, format: .number).monospacedDigit()
                    }
                    .width(55)
                    TableColumn("Proxied") { app in
                        Text(Self.bytes(app.bytesUp + app.bytesDown)).monospacedDigit()
                    }
                    .width(75)
                    TableColumn("") { app in
                        // Browser rows are routed from the extension, not by app rule.
                        if !app.signingID.hasPrefix(SplytConstants.browserActivityPrefix) {
                            Menu("Route") {
                                ForEach(Route.allCases, id: \.self) { route in
                                    Button(route.title) {
                                        model.setRoute(route, for: model.rule(for: app) ?? model.draftRule(for: app, route: route))
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                    .width(70)
                }
            } else {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "waveform.path.ecg",
                    description: Text("Turn Splyt on to see which apps are connecting.")
                )
            }
        }
        .navigationTitle("Activity")
    }

    private func bundlePath(_ app: AppActivity) -> String? {
        guard let path = app.path, let range = path.range(of: ".app/") else {
            return app.path
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func bytes(_ count: UInt64) -> String {
        count == 0 ? "-" : ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
