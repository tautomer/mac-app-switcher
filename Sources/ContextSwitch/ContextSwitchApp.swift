import SwiftUI

@main
struct ContextSwitchApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appState: appState)
        } label: {
            MenuBarIcon(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Window("Edit Profiles", id: "profile-editor") {
            ProfileEditorView(appState: appState)
        }
        .defaultSize(width: 680, height: 460)

        Settings {
            SettingsView(appState: appState)
        }
    }
}
