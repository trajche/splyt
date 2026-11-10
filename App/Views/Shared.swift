import AppKit
import SplytCore
import SwiftUI

extension Route {
    var title: String {
        switch self {
        case .vpn:
            return "VPN"
        case .direct:
            return "Direct"
        case .block:
            return "Block"
        }
    }
}

extension Verdict {
    /// How the extension last handled an app's flow, in terms of where it went.
    func title(route: Route?, vpnIsUp: Bool) -> String {
        switch self {
        case .block:
            return "Blocked"
        case .direct:
            return "Direct"
        case .pass:
            guard let route else {
                return vpnIsUp ? "System (VPN)" : "System"
            }
            return route == .vpn ? "VPN" : "Direct"
        }
    }
}

struct AppIcon: View {
    let path: String?
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let path, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct RoutePicker: View {
    @Binding var route: Route

    var body: some View {
        Picker("Route", selection: $route) {
            ForEach(Route.allCases, id: \.self) { route in
                Text(route.title).tag(route)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: AppRule
    var iconSize: CGFloat = 24
    /// Shows a trash button after the picker.
    var removable = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: rule.path, size: iconSize)
            Text(rule.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            RoutePicker(route: Binding(
                get: { model.route(for: rule) },
                set: { model.setRoute($0, for: rule) }
            ))
            if removable {
                RemoveButton {
                    model.remove(rule)
                }
                .help("Remove \(rule.name)")
            }
        }
    }
}

/// A quiet trash icon that turns red under the pointer.
private struct RemoveButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .accessibilityLabel("Remove")
    }
}

/// Route for apps without a rule, laid out like a `RuleRow` so the pickers line up.
/// "Follow system routing" has no segment here; Settings offers it, and while it
/// is chosen no segment is selected.
struct UnlistedRow: View {
    @Environment(AppModel.self) private var model
    var iconSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(iconSize / 8)
                .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text("All other apps")
                    .lineLimit(1)
                if model.config.unlisted == nil {
                    Text("Follow system")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Picker("All other apps", selection: Binding(
                get: { model.config.unlisted },
                set: { model.setUnlisted($0) }
            )) {
                ForEach(Route.allCases, id: \.self) { route in
                    Text(route.title).tag(Route?.some(route))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct ExitNodeRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.exitNodes) { node in
            Toggle(isOn: Binding(
                get: { node.isSelected },
                set: { model.setExitNode(node, selected: $0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("NetBird exit node")
                    Text(node.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isChangingExitNode)
        }
    }
}

struct WireGuardRows: View {
    @Environment(AppModel.self) private var model
    /// Settings shows a remove button; the menu stays compact.
    var removable = false

    var body: some View {
        ForEach(model.wireGuardTunnels) { tunnel in
            HStack {
                Toggle(isOn: Binding(
                    get: { tunnel.isOn },
                    set: { model.setTunnel(tunnel, connected: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("WireGuard: \(tunnel.info.name)")
                        Text([tunnel.info.endpoint, tunnel.statusText].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.changingTunnel != nil)
                if removable {
                    Button {
                        model.removeTunnel(tunnel)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this tunnel")
                    .disabled(tunnel.isOn)
                }
            }
        }
    }
}
