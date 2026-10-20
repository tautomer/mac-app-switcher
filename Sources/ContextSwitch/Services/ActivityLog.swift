import Foundation
import Darwin
import os

/// What ContextSwitch did and why — profile switches, what they launched
/// and quit, and anything that went wrong — so "why did Slack just quit?"
/// has an answer. Entries go to ~/Library/Logs/ContextSwitch/ContextSwitch.log
/// (Settings ▸ Activity Log opens it in Console) and to the unified log,
/// which also gets `debug` detail:
///
///     log stream --level debug --predicate 'subsystem == "com.contextswitch.app"'
final class ActivityLog: Sendable {
    enum Level {
        case info
        /// Something went wrong; marked ⚠ in the file.
        case problem
    }

    static let shared = ActivityLog()

    let fileURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.contextswitch.app", category: "activity")
    /// File writes, in order, off the caller's thread.
    private let queue = DispatchQueue(label: "ContextSwitch.ActivityLog")

    /// Past this the file is moved to `rotatedURL` (replacing the previous
    /// one) and a new one started.
    private static let maxFileSize = 1_000_000

    private static let timestampStyle = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: .current)
        .year().month().day().time(includingFractionalSeconds: false)

    init(fileURL: URL = ActivityLog.defaultFileURL) {
        self.fileURL = fileURL
    }

    private static var defaultFileURL: URL {
        if ProcessInfo.processInfo.environment["CONTEXTSWITCH_PROFILES"]?.isEmpty == false {
            return fileURL(besideProfilesAt: ProfileStore.defaultFileURL)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/ContextSwitch/ContextSwitch.log")
    }

    /// For a CONTEXTSWITCH_PROFILES sandbox file, so trying things out stays
    /// out of your real log: named after it (profiles.json.log), so neither
    /// the log nor its rotated copy can be that file.
    static func fileURL(besideProfilesAt profiles: URL) -> URL {
        profiles.appendingPathExtension("log")
    }

    /// Where a full log is moved, e.g. ContextSwitch.old.log.
    static func rotatedURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("old.log")
    }

    /// An entry in the file and the unified log. Lines after the first are
    /// indented under it.
    func record(_ message: String, level: Level = .info) {
        switch level {
        case .info: logger.notice("\(message, privacy: .public)")
        case .problem: logger.error("\(message, privacy: .public)")
        }
        let stamp = Date().formatted(Self.timestampStyle)
        let indent = String(repeating: " ", count: stamp.count + 2)
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let first = (level == .problem ? "⚠ " : "") + (lines.first.map(String.init) ?? "")
        let text = ([stamp + "  " + first] + lines.dropFirst().map { indent + $0 }).joined(separator: "\n") + "\n"
        queue.async { [fileURL] in Self.append(text, to: fileURL) }
    }

    /// Unified log only: detail for debugging, too chatty for the file.
    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    /// Waits for entries recorded so far to reach the file, e.g. before
    /// opening it or before a command-line run exits.
    func flush() {
        queue.sync {}
    }

    private static func append(_ text: String, to url: URL) {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // The menu bar app and command-line runs can write at once, each with
        // its own queue. A lock on the folder keeps one from rotating the file
        // under the other, and O_APPEND puts every write at the end.
        let lock = open(folder.path, O_RDONLY)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { close(lock) } }

        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxFileSize {
            let old = rotatedURL(for: url)
            try? fileManager.removeItem(at: old)
            try? fileManager.moveItem(at: url, to: old)
        }
        let file = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard file >= 0 else { return }
        defer { close(file) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
    }
}
