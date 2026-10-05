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
            print("LoginItemManager: failed to \(enabled ? "register" : "unregister"): \(error)")
        }
    }
}
