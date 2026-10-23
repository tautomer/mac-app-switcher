import Foundation

/// What `--import` checks and says, wherever it's carried out: here, or in
/// the menu bar app if it's running. The activity log gets the same report
/// for imports from Edit Profiles.
enum ImportCommand {
    typealias ExitStatus = CommandLineCommand.ExitStatus

    enum Plan {
        case fail(status: Int32, message: String)
        case importing(ProfileImport, replacing: Bool)
    }

    struct Failure: Error {
        let status: Int32
        let message: String
    }

    /// The profiles in the file (`data`), if it has any to import.
    static func read(_ data: Data, from fileName: String) throws(Failure) -> ProfileImport {
        let imported: ProfileImport
        do {
            imported = try ProfileStore.readImport(data)
        } catch {
            throw Failure(status: ExitStatus.badData,
                          message: "Couldn't import \(fileName): it isn't a file of ContextSwitch profiles. \(ProfileStore.describe(error))")
        }
        guard !imported.profiles.isEmpty else {
            let why = imported.unreadable.isEmpty ? "it has no profiles."
                : "none of its profiles could be read. They \(unreadableReason).\n" + leftOutLines(imported.unreadable).joined(separator: "\n")
            throw Failure(status: ExitStatus.badData, message: "Couldn't import \(fileName): \(why)")
        }
        return imported
    }

    /// Reads the file (`data`) and checks it against your profiles. Profiles
    /// that match yours stop the import unless `onMatch` says what to do.
    static func plan(_ data: Data, from fileName: String, into existing: [Profile],
                     onMatch: CommandLineCommand.OnMatch) -> Plan {
        let imported: ProfileImport
        do throws(Failure) {
            imported = try read(data, from: fileName)
        } catch {
            return .fail(status: error.status, message: error.message)
        }
        let yours = imported.matches(in: existing).compactMap { $0 }
        switch onMatch {
        case .stop where !yours.isEmpty:
            return .fail(status: ExitStatus.importMatches, message: """
                Nothing was imported: profiles in \(fileName) match your \(names(yours)), by name or as an export of \(yours.count == 1 ? "it" : "them").
                Add --replace to replace yours with them, or --keep-both to add them as well.
                """)
        case .stop, .keepBoth:
            return .importing(imported, replacing: false)
        case .replace:
            return .importing(imported, replacing: true)
        }
    }

    /// e.g. "Imported 2 profiles from backup.json." and a line for each.
    static func report(_ merge: ProfileImport.Merge, of imported: ProfileImport, from fileName: String, dryRun: Bool) -> String {
        let count = merge.imported.count == 1 ? "1 profile" : "\(merge.imported.count) profiles"
        var lines = ["\(dryRun ? "Would import" : "Imported") \(count) from \(fileName)."]
        for (original, profile) in zip(imported.profiles, merge.imported) {
            if let yours = merge.replaced[profile.id] {
                let with = yours.name == profile.name ? "" : " with “\(profile.name)”"
                lines.append("  ▸ \(dryRun ? "would replace" : "replaced") your “\(yours.name)”\(with)")
            } else {
                let renamed = original.name == profile.name ? "" : " as “\(profile.name)”"
                lines.append("  ▸ \(dryRun ? "would add" : "added") “\(original.name)”\(renamed)")
            }
        }
        if !imported.unreadable.isEmpty {
            lines.append("  Left out, as \(imported.unreadable.count == 1 ? "it" : "they") couldn't be read "
                         + "(\(imported.unreadable.count == 1 ? "it" : "they") \(unreadableReason)):")
            lines += leftOutLines(imported.unreadable).map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    private static let unreadableReason = "may have been saved by a newer version of ContextSwitch, or mistyped by hand"

    private static func leftOutLines(_ lost: [ProfileStore.UnreadableProfile]) -> [String] {
        lost.map { "  \($0.name.map { "“\($0)”" } ?? "(no name)"): \($0.reason)" }
    }

    /// e.g. `“Office” and “Home”`
    private static func names(_ profiles: [Profile]) -> String {
        ListFormatter.localizedString(byJoining: profiles.map { "“\($0.name)”" })
    }
}
