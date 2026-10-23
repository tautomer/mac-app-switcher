import Foundation
import Combine

/// Persists profiles as JSON under
/// ~/Library/Application Support/ContextSwitch/profiles.json, or at
/// $CONTEXTSWITCH_PROFILES if set (handy for trying things out without
/// touching your real profiles).
///
/// It never throws profiles away: one this version can't read (saved by a
/// newer version, or mistyped by hand) is left out but written back, and a
/// file that can't be read at all is left alone. Either way, a copy of the
/// file is kept before profiles are first saved over it. `problem` says
/// what couldn't be read.
final class ProfileStore: ObservableObject {
    enum Problem: Equatable {
        /// Nothing could be read, so there's a blank profile for now. The
        /// file is left as it is until profiles are saved, when it's first
        /// copied to `backupURL` (and the problem cleared). No `backupURL`
        /// for a folder, which is never copied or saved over.
        case unreadableFile(reason: String, backupURL: URL?)
        /// These are left out, but written back to the file. Not every value
        /// comes back exactly (a number past the 64-bit integers, say), so
        /// the file is copied aside too before it's first saved over.
        case unreadableProfiles([UnreadableProfile])
    }

    struct UnreadableProfile: Equatable {
        /// nil if it hasn't a name either.
        let name: String?
        let reason: String
    }

    enum SaveError: LocalizedError {
        case isAFolder(URL)

        var errorDescription: String? {
            switch self {
            case .isAFolder(let url): return "\(url.path) is a folder, not a file."
            }
        }
    }

    @Published var profiles: [Profile] = []
    private(set) var problem: Problem?

    let fileURL: URL
    /// Profiles that couldn't be read, written back after the others.
    private var unreadable: [JSONValue] = []
    /// While the file on disk has something that couldn't be read: where
    /// to copy it before first saving over it (or the first free name after).
    private var backupBeforeSaving: URL?
    /// Where this store copied the file, once it has.
    private(set) var copiedAside: URL?

    static var defaultFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["CONTEXTSWITCH_PROFILES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("ContextSwitch/profiles.json")
    }

    convenience init() {
        self.init(fileURL: Self.defaultFileURL)
    }

    /// Runs `body` holding a lock on these profiles (a .lock file beside
    /// them), so the menu bar app can't load them in the middle of an
    /// import from the command line, and later save over it: the app takes
    /// it while it loads them, and the command line while it imports with
    /// no app running. Without a lock file (a folder that can't be written
    /// to), `body` runs anyway.
    static func whileLocked<T>(_ fileURL: URL = defaultFileURL, _ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(fileURL.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        // Closing it lets go.
        defer { if lock >= 0 { close(lock) } }
        if lock >= 0 { flock(lock, LOCK_EX) }
        return try body()
    }

    /// Whether `path` is this file, by whatever name: /tmp/x and
    /// /private/tmp/x are the same file, say.
    func isProfilesFile(_ path: String) -> Bool {
        var info = stat(), mine = stat()
        guard stat(path, &info) == 0, stat(fileURL.path, &mine) == 0 else { return path == fileURL.path }
        return info.st_dev == mine.st_dev && info.st_ino == mine.st_ino
    }

    /// e.g. CONTEXTSWITCH_PROFILES pointed at one by mistake.
    private var isFolder: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    func load() {
        problem = nil
        unreadable = []
        backupBeforeSaving = nil
        copiedAside = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Nothing to lose: start with the default and save it, so its
            // ID (remembered as the active profile) stays the same.
            profiles = ProfileStore.defaultProfiles()
            try? save()
            return
        }
        do {
            let entries = try JSONDecoder().decode([StoredProfile].self, from: Data(contentsOf: fileURL))
            var lost: [UnreadableProfile] = []
            var generatedIDs = false
            profiles = entries.compactMap { entry in
                switch entry {
                case .readable(let profile, let generatedID):
                    generatedIDs = generatedIDs || generatedID
                    return profile
                case .unreadable(let raw, let reason):
                    unreadable.append(raw)
                    lost.append(UnreadableProfile(name: raw["name"]?.stringValue, reason: reason))
                    return nil
                }
            }
            if !lost.isEmpty {
                problem = .unreadableProfiles(lost)
                backupBeforeSaving = Self.backupURL(for: fileURL, at: Date())
            }
            // The active profile is remembered by ID, so IDs made up for
            // profiles without one are saved, to be the same next time.
            if generatedIDs { try? save() }
        } catch {
            profiles = ProfileStore.defaultProfiles()
            if isFolder {
                problem = .unreadableFile(reason: "It's a folder, not a file.", backupURL: nil)
            } else {
                let backup = Self.backupURL(for: fileURL, at: Date())
                backupBeforeSaving = backup
                problem = .unreadableFile(reason: Self.describe(error), backupURL: backup)
            }
        }
    }

    /// What's saved: the profiles, then those that couldn't be read.
    private var entries: [StoredProfile] {
        profiles.map { .readable($0, generatedID: false) } + unreadable.map { .unreadable($0, reason: "") }
    }

    func save() throws {
        guard !isFolder else { throw SaveError.isAFolder(fileURL) }
        let data = try JSONEncoder().encode(entries)
        // Copied rather than moved, so a write that fails leaves the file as
        // it was, and nothing is cleared until the write has worked. A retry
        // after one that failed keeps the copy already made.
        if let backup = backupBeforeSaving, copiedAside == nil, FileManager.default.fileExists(atPath: fileURL.path) {
            copiedAside = try copy(to: backup)
        }
        try data.write(to: fileURL, options: .atomic)
        backupBeforeSaving = nil
        // Whatever couldn't be read is now in the copy (or was a folder that
        // has since gone), and the file is one this version wrote.
        if case .unreadableFile? = problem { problem = nil }
    }

    /// Copies the file to `destination`, or if that's taken (another copy in
    /// the same second, say), to the first free …-2.json, …-3.json: never
    /// over a file already there.
    private func copy(to destination: URL) throws -> URL {
        let name = destination.deletingPathExtension().lastPathComponent
        var lastError: Error?
        for attempt in 1...100 {
            let candidate = attempt == 1 ? destination
                : destination.deletingLastPathComponent().appendingPathComponent("\(name)-\(attempt).json")
            do {
                try FileManager.default.copyItem(at: fileURL, to: candidate)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    func upsert(_ profile: Profile) throws {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        try save()
    }

    func delete(_ profile: Profile) throws {
        profiles.removeAll { $0.id == profile.id }
        try save()
    }

    /// `imported` merged into the profiles (see `ProfileImport.merged`),
    /// keeping clear of the IDs of those that couldn't be read: they're
    /// saved too.
    func merging(_ imported: ProfileImport, replacing: Bool) -> ProfileImport.Merge {
        let unreadableIDs = unreadable.compactMap { $0["id"]?.stringValue.flatMap(UUID.init(uuidString:)) }
        return imported.merged(into: profiles, replacing: replacing, reserving: Set(unreadableIDs))
    }

    /// Takes in profiles from a file, as `merging` puts them.
    func importProfiles(_ merge: ProfileImport.Merge) throws {
        profiles = merge.profiles
        try save()
    }

    /// The profiles with these IDs, or all of them (with any that couldn't
    /// be read, as they were), for a file to import elsewhere: the format of
    /// profiles.json, laid out to be read.
    func exportData(of ids: Set<Profile.ID>? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let ids else { return try encoder.encode(entries) }
        return try encoder.encode(profiles.filter { ids.contains($0.id) })
    }

    /// Reads a file to import: an export, or a profiles.json (such as a copy
    /// kept aside). Profiles it can't read are left out, and listed.
    static func readImport(_ data: Data) throws -> ProfileImport {
        var result = ProfileImport(profiles: [])
        for entry in try JSONDecoder().decode([StoredProfile].self, from: data) {
            switch entry {
            case .readable(let profile, _):
                result.profiles.append(profile)
            case .unreadable(let raw, let reason):
                result.unreadable.append(UnreadableProfile(name: raw["name"]?.stringValue, reason: reason))
            }
        }
        return result
    }

    private static func defaultProfiles() -> [Profile] {
        [Profile(name: "Default", conditions: [], appRules: [], priority: 0)]
    }

    /// e.g. profiles-unreadable-2026-10-20-135342.json, next to the file.
    private static func backupURL(for fileURL: URL, at date: Date) -> URL {
        let stamp = date.formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let name = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(name)-unreadable-\(stamp).json")
    }

    /// What was wrong, and where, e.g. "at [0].conditions[0].condition:
    /// Invalid number of keys found, expected one."
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        var message: String
        switch error {
        case .keyNotFound(let key, let ctx):
            context = ctx
            message = "“\(key.stringValue)” is missing."
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            context = ctx
            message = ctx.debugDescription
        case .dataCorrupted(let ctx):
            context = ctx
            // Not JSON at all: the parser's own message says where.
            let parser = (ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            message = parser.map { "Not valid JSON: \($0)" } ?? ctx.debugDescription
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }.joined()
        if !path.isEmpty {
            message = "at \(path.hasPrefix(".") ? String(path.dropFirst()) : path): \(message)"
        }
        return message
    }
}

extension ProfileStore.Problem {
    /// One line, e.g. for the menu or a notification's title.
    var summary: String {
        switch self {
        case .unreadableFile:
            return "Couldn't read your profiles"
        case .unreadableProfiles(let lost):
            if lost.count == 1, let name = lost[0].name { return "Couldn't read the profile “\(name)”" }
            return lost.count == 1 ? "Couldn't read a profile" : "Couldn't read \(lost.count) profiles"
        }
    }

    /// What it means and what's been done about it.
    var explanation: String {
        switch self {
        case .unreadableFile(_, let backup?):
            return "ContextSwitch is using a blank profile for now and has left the file as it is. "
                + "If you change profiles, a copy of it is first saved as \(backup.lastPathComponent)."
        case .unreadableFile(_, nil):
            return "ContextSwitch is using a blank profile for now, and can't save profiles there."
        case .unreadableProfiles(let lost):
            return "\(lost.count == 1 ? "It" : "They") may have been saved by a newer version of ContextSwitch, "
                + "and \(lost.count == 1 ? "is" : "are") left out for now but kept in the file, "
                + "which is also copied before it's first saved over."
        }
    }

    /// Everything, for the log: what couldn't be read, and why.
    var details: String {
        switch self {
        case .unreadableFile(let reason, _):
            return "\(summary): \(reason)\n\(explanation)"
        case .unreadableProfiles(let lost):
            let reasons = lost.map { "  \($0.name.map { "“\($0)”" } ?? "(no name)"): \($0.reason)" }
            return ([summary + ". " + explanation] + reasons).joined(separator: "\n")
        }
    }
}

/// One entry in profiles.json: a profile, or one this version can't read,
/// kept as it was.
private enum StoredProfile: Codable {
    /// `generatedID`: it had no ID, so it was given one, which needs saving.
    case readable(Profile, generatedID: Bool)
    case unreadable(JSONValue, reason: String)

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        do {
            self = .readable(try Profile(from: decoder), generatedID: (raw["id"] ?? .null) == .null)
        } catch {
            self = .unreadable(raw, reason: ProfileStore.describe(error))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .readable(let profile, _): try profile.encode(to: encoder)
        case .unreadable(let raw, _): try raw.encode(to: encoder)
        }
    }
}
