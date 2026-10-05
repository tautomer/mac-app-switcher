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
