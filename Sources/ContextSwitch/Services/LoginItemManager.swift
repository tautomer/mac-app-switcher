import Foundation
import ServiceManagement

/// Launch-at-login toggle via the modern SMAppService API (macOS 13+).
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            ActivityLog.shared.record("Couldn't turn \(enabled ? "on" : "off") launch at login: \(error.localizedDescription)", level: .problem)
        }
    }
}
