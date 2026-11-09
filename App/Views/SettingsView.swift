import AppKit
import SplytCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingUninstall = false
    @State private var importingWireGuard = false

    var body: some View {
        Form {
            Section {
                WireGuardRows(removable: true).toggleStyle(.switch)
                Button("Import WireGuard Configuration...") {
                    importingWireGuard = true
                }
                LabeledContent("Current VPN interface", value: model.snapshot?.vpnInterface ?? "None")
                LabeledContent("Direct interface", value: model.snapshot?.physicalInterface ?? "None")
            } header: {
                Text("VPN")
            } footer: {
                Text("Splyt runs WireGuard tunnels itself. Keep only one VPN that carries all traffic on at a time. Turning Splyt off turns these off too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Kill switch", isOn: Binding(
                    get: { model.config.killSwitch },
                    set: { model.setKillSwitch($0) }
                ))
            } footer: {
                Text("Blocks apps set to VPN whenever no VPN is active, so they never fall back to your normal connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Browser proxy", isOn: Binding(
                    get: { model.config.browserProxy?.enabled == true },
                    set: { model.setBrowserProxy(enabled: $0) }
                ))
                if let settings = model.config.browserProxy, settings.enabled {
                    LabeledContent("VPN port", value: String(settings.vpnPort))
                    LabeledContent("Direct port", value: String(settings.directPort))
                    LabeledContent("Pairing code") {
                        HStack {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(settings.pairingCode, forType: .string)
                            }
                            Button("Regenerate") {
                                model.regenerateBrowserToken()
                            }
                        }
                    }
                    if let problem = model.snapshot?.browserProxyProblem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Browser")
            } footer: {
                Text("Lets the Splyt Firefox extension route individual tabs, sites and containers. Paste the pairing code into the extension's settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("NetBird exit node", isOn: Binding(
                    get: { model.netBirdEnabled },
                    set: { model.setNetBirdEnabled($0) }
                ))
                if model.netBirdEnabled {
                    if model.exitNodes.isEmpty {
                        LabeledContent("Exit nodes", value: "None available")
                    } else {
                        ExitNodeRows().toggleStyle(.switch)
                    }
                }
            } header: {
                Text("NetBird")
            } footer: {
                Text("Shows the exit nodes of an installed NetBird client in the menu, so they can be switched from Splyt. Splyt splits traffic around any VPN without this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                ))
            } footer: {
                Text("Rules stay active after a restart even if the app is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Remove Splyt Extension...", role: .destructive) {
                    confirmingUninstall = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(
            isPresented: $importingWireGuard,
            allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else {
                return
            }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                model.importWireGuard(from: url)
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
        .confirmationDialog("Remove the Splyt extension?", isPresented: $confirmingUninstall) {
            Button("Remove", role: .destructive) {
                model.uninstall()
            }
        } message: {
            Text("All apps return to normal routing. Your rules are kept.")
        }
    }
}
