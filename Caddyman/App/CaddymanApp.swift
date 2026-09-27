import SwiftUI

@MainActor
enum CaddymanLifecycle {
    static let model = CaddymanAppModel()
}

struct CaddymanApp: App {
    @NSApplicationDelegateAdaptor(CaddymanAppDelegate.self) private var appDelegate
    @State private var model = CaddymanLifecycle.model

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            CaddymanMenuBarMark()
                .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
