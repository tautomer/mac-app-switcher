import SwiftUI

/// Command-line options (see `CommandLineCommand`) run a one-off command and
/// exit; any other launch starts the menu bar app.
@main
enum EntryPoint {
    @MainActor
    static func main() {
        if let command = CommandLineCommand(arguments: Array(CommandLine.arguments.dropFirst())) {
            exit(CommandLineInterface.run(command))
        }
        ContextSwitchApp.main()
    }
}

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
            #if DEBUG
            DebugCommands()
            #endif
        }

        #if DEBUG
        Window("Menu Preview", id: DebugSnapshot.menuPreviewID) {
            MenuBarContentView(appState: appState)
        }
        .windowResizability(.contentSize)
        #endif
    }
}

private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
            .keyboardShortcut(",")
    }
}
