import Foundation
import AppKit
import Darwin
import UniformTypeIdentifiers

/// What `AppLauncherService.enforce` did (or, for a dry run, would do).
enum EnforceOutcome: Equatable {
    case launched
    case quit
    case alreadyRunning
    case notRunning
    case ignored
}

/// An app or executable found in the app folders, for the "add app" picker.
struct InstalledItem: Identifiable {
    let url: URL
    let name: String
    /// The `AppRule.targetKey` of the rule it'd be added as.
    let targetKey: String
    let isExecutable: Bool

    var id: String { targetKey }
}

/// Launches/quits the targets of `AppRule`s: app bundles through
/// NSWorkspace, plain executables (scripts, CLI tools) through Process.
@MainActor
final class AppLauncherService {
    static let shared = AppLauncherService()

    /// Brings `rule`'s target to the state `action` asks for. `onLaunched`
    /// is called (later, on the main actor) only when a launch was started,
    /// with whether it succeeded.
    @discardableResult
    func enforce(_ action: AppAction, for rule: AppRule, dryRun: Bool = false,
                 onLaunched: (@MainActor @Sendable (Bool) -> Void)? = nil) -> EnforceOutcome {
        switch action {
        case .launch:
            guard !isRunning(rule) else { return .alreadyRunning }
            if !dryRun { launch(rule, completion: onLaunched) }
            return .launched
        case .quit:
            guard isRunning(rule) else { return .notRunning }
            if !dryRun { quit(rule) }
            return .quit
        case .ignore:
            return .ignored
        }
    }

    /// Called when a launched executable exits, so the UI can refresh.
    /// (App launches/quits are observed via NSWorkspace notifications.)
    var onExecutableExit: (() -> Void)?

    /// Executables we started, by path. A script shows up in the process
    /// table under its interpreter (/bin/sh, python3…), so this is the only
    /// way to tell it's running.
    private var launchedProcesses: [String: Process] = [:]

    func isRunning(_ rule: AppRule) -> Bool {
        if !rule.isExecutable, !runningApplications(for: rule).isEmpty { return true }
        guard let path = directPath(for: rule) else { return false }
        return launchedProcesses[path]?.isRunning == true || !Self.pids(forExecutableAt: path).isEmpty
    }

    /// The program run without Launch Services: a script or tool, or the
    /// binary inside an app set to run directly. nil for apps opened normally.
    private func directPath(for rule: AppRule) -> String? {
        if rule.isExecutable { return rule.path }
        return rule.runsDirectly == true ? executableURL(for: rule)?.path : nil
    }

    /// `completion` always arrives asynchronously, on the main actor.
    func launch(_ rule: AppRule, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        if rule.isExecutable || rule.runsDirectly == true {
            let started = directPath(for: rule).map { runExecutable(at: $0, arguments: rule.arguments ?? []) } ?? false
            Task { @MainActor in completion?(started) }
            return
        }
        guard let url = appURL(for: rule) else {
            Task { @MainActor in completion?(false) }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.arguments = rule.arguments ?? []
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            let succeeded = error == nil
            Task { @MainActor in completion?(succeeded) }
        }
    }

    /// Sends apps a normal Quit, so they can still show "save changes?"
    /// dialogs; programs run directly get SIGTERM.
    func quit(_ rule: AppRule) {
        // Programs run directly are stopped as Terminal would stop them: an
        // app's binary run that way may never become an app that can be
        // asked to quit (a headless server).
        if let path = directPath(for: rule) {
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

    /// The binary that runs: inside the bundle for an app.
    func executableURL(for rule: AppRule) -> URL? {
        if rule.isExecutable { return rule.path.map { URL(fileURLWithPath: $0) } }
        return appURL(for: rule).flatMap { Bundle(url: $0)?.executableURL }
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

    /// Scans `folders` (see `AppFolders`) for the "add app" picker: apps
    /// there or one subfolder down (e.g. Utilities), and scripts and
    /// command-line tools directly inside, as in a folder on $PATH.
    func installedItems(inFolders folders: [String]) -> [InstalledItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var results: [InstalledItem] = []
        for root in AppFolders.scanRoots(folders) {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                                 options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let item as URL in enumerator {
                if enumerator.level > 2 {
                    enumerator.skipDescendants()
                    continue
                }
                // Apps without a bundle identifier can still be added with "Choose…".
                let wanted = item.pathExtension == "app" ? Bundle(url: item)?.bundleIdentifier != nil : enumerator.level == 1
                guard wanted, let rule = rule(forFileAt: item), seen.insert(rule.targetKey).inserted else { continue }
                results.append(InstalledItem(url: item, name: rule.displayName, targetKey: rule.targetKey,
                                             isExecutable: rule.isExecutable))
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func runningApplications(for rule: AppRule) -> [NSRunningApplication] {
        if let bundleID = rule.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        guard let path = rule.path else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
    }

    /// true if it started, or was already running.
    private func runExecutable(at path: String, arguments: [String]) -> Bool {
        guard launchedProcesses[path]?.isRunning != true, Self.pids(forExecutableAt: path).isEmpty else { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
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
            return true
        } catch {
            print("AppLauncherService: failed to run \(path): \(error)")
            return false
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
