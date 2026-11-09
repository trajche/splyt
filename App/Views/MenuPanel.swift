import SplytCore
import SwiftUI

struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private static let maxRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Splyt").font(.headline)
                    Text(model.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { model.wantsOn },
                    set: { model.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isBusy)
            }

            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !model.exitNodes.isEmpty || !model.wireGuardTunnels.isEmpty {
                Divider()
                WireGuardRows().toggleStyle(.switch).controlSize(.small)
                ExitNodeRows().toggleStyle(.switch).controlSize(.small)
            }

            Divider()
            UnlistedRow(iconSize: 20).controlSize(.small)
            if !model.config.rules.isEmpty {
                ForEach(model.config.rules.prefix(Self.maxRows)) { rule in
                    RuleRow(rule: rule, iconSize: 20).controlSize(.small)
                }
                if model.config.rules.count > Self.maxRows {
                    Text("\(model.config.rules.count - Self.maxRows) more in Splyt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Button("Open Splyt") {
                    openWindow(id: WindowID.main)
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 340)
    }
}
