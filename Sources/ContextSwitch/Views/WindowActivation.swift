import SwiftUI
import AppKit

/// As an LSUIElement app we're never activated by clicks in the popover, so
/// windows we open would land behind the frontmost app. While any of our
/// windows is open we become a regular app (Dock icon, ⌘-Tab), and drop
/// back to menu-bar-only when the last one closes.
@MainActor
enum WindowActivation {
    private static var openWindowCount = 0

    /// Call right before `openWindow`.
    static func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    fileprivate static func windowAppeared() {
        openWindowCount += 1
        NSApp.setActivationPolicy(.regular)
    }

    fileprivate static func windowDisappeared() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension View {
    /// Apply to the root view of each window scene.
    func keepsAppActiveWhileOpen() -> some View {
        onAppear { WindowActivation.windowAppeared() }
            .onDisappear { WindowActivation.windowDisappeared() }
    }
}
