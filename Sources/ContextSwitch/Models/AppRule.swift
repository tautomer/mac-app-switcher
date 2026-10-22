import Foundation

enum AppAction: String, Codable, CaseIterable {
    case launch   // ensure the app is running when this profile is active
    case quit     // ensure the app is NOT running when this profile is active
    case ignore   // don't touch the app's running state
}

struct AppRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// nil for plain executables (scripts, command-line tools).
    var bundleIdentifier: String?
    /// Where the app or executable lives. For apps it's a fallback for when
    /// Launch Services can't resolve the bundle identifier.
    var path: String?
    var displayName: String
    var action: AppAction
    /// Passed when ContextSwitch launches it, e.g. `--server --port 6742`.
    /// Not applied to an instance that's already running.
    var arguments: [String]?
    /// For an app: run the program inside the bundle directly, as Terminal
    /// does, instead of opening the app. For server/daemon modes (e.g.
    /// `OpenRGB --server`) that never finish launching as an app, so the
    /// Dock icon would bounce for good.
    var runsDirectly: Bool?
    /// Launch it again if it crashes while its profile keeps it running —
    /// but not if it's quit, even with Force Quit (see `ProcessExit.isCrash`).
    var relaunchesOnCrash: Bool?

    /// Session-only manual override set from the menu bar popover. Not
    /// persisted — it resets whenever the profile re-activates.
    var manualOverride: AppAction?

    var effectiveAction: AppAction {
        manualOverride ?? action
    }

    /// Scripts and command-line tools are run directly rather than through
    /// Launch Services.
    var isExecutable: Bool {
        bundleIdentifier == nil && !(path?.hasSuffix(".app") ?? false)
    }

    /// Identifies the same app/executable across rules, for de-duplication.
    var targetKey: String {
        bundleIdentifier ?? path ?? displayName
    }
}
