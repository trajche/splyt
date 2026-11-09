import SwiftUI

@main
struct SplytApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Splyt", id: WindowID.main) {
            MainView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 820, height: 560)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

enum WindowID {
    static let main = "main"
}
