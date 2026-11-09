import AppKit
import SplytCore
import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                Picker("All other apps", selection: Binding(
                    get: { model.config.unlisted },
                    set: { model.setUnlisted($0) }
                )) {
                    Text("Follow system routing").tag(Route?.none)
                    ForEach(Route.allCases, id: \.self) { route in
                        Text(route.title).tag(Route?.some(route))
                    }
                }
            } footer: {
                Text(unlistedHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rules") {
                if model.config.rules.isEmpty {
                    Text("Add an app to choose how it connects.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.config.rules) { rule in
                    RuleRow(rule: rule)
                        .contextMenu {
                            Button("Remove Rule", role: .destructive) {
                                model.remove(rule)
                            }
                        }
                }
                .onDelete { offsets in
                    offsets.map { model.config.rules[$0] }.forEach(model.remove)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Apps")
        .toolbar {
            Button {
                isAdding = true
            } label: {
                Label("Add App", systemImage: "plus")
            }
        }
        .sheet(isPresented: $isAdding) {
            AddAppSheet()
        }
    }

    private var unlistedHelp: String {
        switch model.config.unlisted {
        case nil:
            return "Apps without a rule are left alone and use whatever the system routes them through."
        case .direct:
            return "With a VPN or exit node on, only apps set to VPN use it. Everything else stays on your normal connection."
        case .vpn:
            return "Apps without a rule use the VPN."
        case .block:
            return "Apps without a rule cannot connect. VPN clients stay exempt."
        }
    }
}

private struct AddAppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var route: Route = .direct

    private var matches: [CatalogApp] {
        let existing = Set(model.config.rules.map(\.id))
        return model.catalog.filter { app in
            !existing.contains(app.signingID)
                && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                RoutePicker(route: $route)
            }
            List(matches) { app in
                Button {
                    model.add(app, route: route)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        AppIcon(path: app.path)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Choose File...") {
                    choose()
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 460)
    }

    /// Covers apps outside the usual folders and command-line tools.
    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose an app or command-line tool"
        panel.allowedContentTypes = [.application, .unixExecutable]
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let app = AppCatalog.describe(url) else {
            return
        }
        model.add(app, route: route)
        dismiss()
    }
}
