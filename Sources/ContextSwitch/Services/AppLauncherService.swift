import Foundation
import AppKit
import Darwin
import UniformTypeIdentifiers

/// Launches/quits the targets of `AppRule`s: app bundles through
/// NSWorkspace, plain executables (scripts, CLI tools) through Process.
@MainActor
final class AppLauncherService {
    static let shared = AppLauncherService()

    /// Called when a launched executable exits, so the UI can refresh.
    /// (App launches/quits are observed via NSWorkspace notifications.)
    var onExecutableExit: (() -> Void)?

    /// Executables we started, by path. A script shows up in the process
    /// table under its interpreter (/bin/sh, python3…), so this is the only
    /// way to tell it's running.
    private var launchedProcesses: [String: Process] = [:]

    func isRunning(_ rule: AppRule) -> Bool {
        if rule.isExecutable {
            guard let path = rule.path else { return false }
            return launchedProcesses[path]?.isRunning == true || !Self.pids(forExecutableAt: path).isEmpty
        }
        return !runningApplications(for: rule).isEmpty
    }

    func launch(_ rule: AppRule) {
        if rule.isExecutable {
            if let path = rule.path { runExecutable(at: path) }
            return
        }
        guard let url = appURL(for: rule) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    /// Sends a normal Quit / SIGTERM, so apps can still show "save
    /// changes?" dialogs.
    func quit(_ rule: AppRule) {
        if rule.isExecutable {
            guard let path = rule.path else { return }
            launchedProcesses[path]?.terminate()
            for pid in Self.pids(forExecutableAt: path) {
                kill(pid, SIGTERM)
            }
            return
        }
        for app in runningApplications(for: rule) {
            app.terminate()
        }
    }

    func appURL(for rule: AppRule) -> URL? {
        if let bundleID = rule.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        return rule.path.map { URL(fileURLWithPath: $0) }
    }

    func icon(for rule: AppRule) -> NSImage {
        if let url = appURL(for: rule), FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: rule.isExecutable ? .unixExecutable : .applicationBundle)
    }

    /// A rule for an app bundle or executable picked from disk, or nil if
    /// the file isn't something we can run.
    func rule(forFileAt url: URL) -> AppRule? {
        let fm = FileManager.default
        if url.pathExtension == "app" {
            return AppRule(
                bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
                path: url.path,
                displayName: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                action: .launch
            )
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              fm.isExecutableFile(atPath: url.path)
        else { return nil }
        return AppRule(bundleIdentifier: nil, path: url.path, displayName: url.lastPathComponent, action: .launch)
    }

    /// Scans the standard application folders (one level of subfolders,
    /// e.g. Utilities) for the "add app" picker.
    func installedApplications() -> [(bundleIdentifier: String, name: String, url: URL)] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var seen = Set<String>()
        var results: [(String, String, URL)] = []
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                                 options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let item as URL in enumerator {
                if enumerator.level > 2 {
                    enumerator.skipDescendants()
                    continue
                }
                guard item.pathExtension == "app",
                      let bid = Bundle(url: item)?.bundleIdentifier,
                      seen.insert(bid).inserted
                else { continue }
                let name = fm.displayName(atPath: item.path).replacingOccurrences(of: ".app", with: "")
                results.append((bid, name, item))
            }
        }
        return results.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func runningApplications(for rule: AppRule) -> [NSRunningApplication] {
        if let bundleID = rule.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        guard let path = rule.path else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
    }

    private func runExecutable(at path: String) {
        guard launchedProcesses[path]?.isRunning != true, Self.pids(forExecutableAt: path).isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] exited in
            let pid = exited.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                if self.launchedProcesses[path]?.processIdentifier == pid {
                    self.launchedProcesses[path] = nil
                }
                self.onExecutableExit?()
            }
        }
        do {
            try process.run()
            launchedProcesses[path] = process
        } catch {
            print("AppLauncherService: failed to run \(path): \(error)")
        }
    }

    /// PIDs whose executable is `path` (symlinks resolved).
    nonisolated static func pids(forExecutableAt path: String) -> [pid_t] {
        // realpath(3) rather than URL.resolvingSymlinksInPath, which strips
        // "/private" and so wouldn't match the kernel's /private/tmp/… paths.
        guard let resolved = realpath(path, nil) else { return [] }
        let target = String(cString: resolved)
        free(resolved)
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return path == target
        }
    }
}
