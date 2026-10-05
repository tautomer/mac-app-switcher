import Foundation

enum AppAction: String, Codable, CaseIterable {
    case launch   // ensure the app is running when this profile is active
    case quit     // ensure the app is NOT running when this profile is active
    case ignore   // don't touch the app's running state
}

struct AppRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var bundleIdentifier: String
    var displayName: String
    var action: AppAction

    /// Session-only manual override set from the menu bar popover. Not
    /// persisted — it resets whenever the profile re-activates.
    var manualOverride: AppAction?

    var effectiveAction: AppAction {
        manualOverride ?? action
    }
}
