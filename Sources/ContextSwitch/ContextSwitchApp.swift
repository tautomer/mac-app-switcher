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
        .defaultSize(width: 720, height: 520)

        // A plain Window rather than a Settings scene: openWindow from the
        // popover is reliable, whereas opening Settings from a menu-bar-only
        // app is not.
        Window("ContextSwitch Settings", id: "settings") {
            SettingsView(appState: appState)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
        }
    }
}

private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
            .keyboardShortcut(",")
    }
}
