import Foundation
import AppKit

enum RunState {
    case running
    case stopped
    case launching
    case quitting
}

/// Thin wrapper around NSWorkspace for launching/quitting apps by bundle
/// identifier, plus a helper for discovering installed apps for the
/// profile editor's picker. Holds no mutable state of its own — every call
/// just forwards to NSWorkspace/NSRunningApplication — so it's safe to
/// share across isolation contexts.
final class AppLauncherService: @unchecked Sendable {
    static let shared = AppLauncherService()

    func runState(for bundleIdentifier: String) -> RunState {
        isRunning(bundleIdentifier) ? .running : .stopped
    }

    func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func launch(_ bundleIdentifier: String, completion: ((Bool) -> Void)? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            completion?(false)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            completion?(error == nil)
        }
    }

    /// Sends a normal Quit (apps can still show "save changes?" dialogs).
    func quit(_ bundleIdentifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.terminate()
        }
    }

    func displayName(forBundleIdentifier bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Scans /Applications (and ~/Applications) for installed apps, for the
    /// "add app to profile" picker.
    func installedApplications() -> [(bundleIdentifier: String, name: String, url: URL)] {
        let fm = FileManager.default
        let searchDirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var results: [(String, String, URL)] = []
        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "app" {
                guard let bundle = Bundle(url: item), let bid = bundle.bundleIdentifier else { continue }
                let name = fm.displayName(atPath: item.path).replacingOccurrences(of: ".app", with: "")
                results.append((bid, name, item))
            }
        }
        return results.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

