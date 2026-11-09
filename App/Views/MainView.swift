import SplytCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    private enum Section: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case activity = "Activity"
        case settings = "Settings"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .apps:
                return "square.grid.2x2"
            case .activity:
                return "waveform.path.ecg"
            case .settings:
                return "gearshape"
            }
        }
    }

    @State private var section: Section? = .apps

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            VStack(spacing: 0) {
                StatusBanner()
                switch section ?? .apps {
                case .apps:
                    AppsView()
                case .activity:
                    ActivityView()
                case .settings:
                    SettingsView()
                }
            }
        }
        .alert(
            "Splyt",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

private struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: model.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.isOn ? .green : .secondary)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isOn ? "Splyt is on" : "Splyt is off").font(.headline)
                    Text(model.statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .awaitingApproval {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(
                            string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.network_extension.extension-point"
                        )!)
                    }
                }
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
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.bar)
    }
}
