import Foundation

/// What `ContextSwitch <options>` asks for. Only these options make the
/// binary act as a command-line tool: Finder, login items and the Dock start
/// the app with no arguments, and Xcode adds AppKit ones (`-NSFoo value`),
/// so anything else starts the menu bar app.
enum CommandLineCommand: Equatable {
    /// One switch to the profile that matches right now.
    case autoSwitch(dryRun: Bool)
    /// One switch to the named profile.
    case switchTo(profile: String, dryRun: Bool)
    case list
    /// All profiles, or the named one, to `file` (nil = standard output).
    case export(file: String?, profile: String?)
    /// The profiles in `file` ("-" = standard input).
    case importProfiles(file: String, onMatch: OnMatch, dryRun: Bool)
    case help
    case usageError(String)

    /// What `--import` does with profiles that match yours (see
    /// `ProfileImport.matches`).
    enum OnMatch: String {
        /// Imports nothing, and says so.
        case stop
        case replace
        case keepBoth
    }

    enum ExitStatus {
        static let success: Int32 = 0
        static let noMatchingProfile: Int32 = 1
        static let unknownProfile: Int32 = 2
        /// Profiles to import match yours, and nothing was imported.
        static let importMatches: Int32 = 3
        // The rest are from sysexits(3).
        static let usage: Int32 = 64
        /// Not a file of profiles, or your profiles couldn't be read.
        static let badData: Int32 = 65
        static let cannotRead: Int32 = 66
        /// The export, or your profiles, couldn't be written.
        static let cannotWrite: Int32 = 74
        /// The running app didn't answer.
        static let tryAgain: Int32 = 75
    }

    static let usage = """
        Usage: ContextSwitch --switch [--dry-run]
               ContextSwitch --profile NAME [--dry-run]
               ContextSwitch --list
               ContextSwitch --export [FILE] [--profile NAME]
               ContextSwitch --import FILE [--replace | --keep-both] [--dry-run]

          --switch          Switch once to the profile that matches right now.
          --profile NAME    Switch once to the named profile (auto-switch stays as it is).
          --dry-run         Show what would be launched or quit, or imported, without
                            doing it.
          --list            List profiles and whether each matches right now.
          --export [FILE]   Write all profiles, or the one named with --profile, to FILE
                            or standard output, for --import elsewhere.
          --import FILE     Add the profiles in FILE (- for standard input): an export
                            or a profiles.json. If some match yours, by name or as an
                            export of one, nothing is imported unless you add:
            --replace       to replace yours with them, or
            --keep-both     to add them as well, renamed if their names are taken.

        Without these options ContextSwitch starts as a menu bar app. If it's already
        running, --switch, --profile and --import are carried out by it.
        """

    private static let options: Set = ["--switch", "--profile", "--dry-run", "--list", "--export", "--import",
                                       "--replace", "--keep-both", "--help", "-h"]
    private static let valuePrefixes = ["--profile=", "--export=", "--import="]

    /// nil when the arguments aren't a command-line invocation, i.e. the
    /// menu bar app should start.
    init?(arguments: [String]) {
        guard arguments.contains(where: { argument in
            Self.options.contains(argument) || Self.valuePrefixes.contains { argument.hasPrefix($0) }
        }) else {
            return nil
        }
        var autoSwitch = false, list = false, help = false, dryRun = false
        var exporting = false, replace = false, keepBoth = false
        var profile: String?, exportFile: String?, importFile: String?
        // Arguments that aren't options: only the export's file, if it comes later.
        var others: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--switch": autoSwitch = true
            case "--list": list = true
            case "--dry-run": dryRun = true
            case "--replace": replace = true
            case "--keep-both": keepBoth = true
            case "--help", "-h": help = true
            case "--export":
                exporting = true
                // The file is optional; "-" is standard output.
                if index + 1 < arguments.count, arguments[index + 1] == "-" || !arguments[index + 1].hasPrefix("-") {
                    exportFile = arguments[index + 1]
                    index += 1
                }
            case "--import":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    self = .usageError("--import needs a file (- for standard input)")
                    return
                }
                importFile = arguments[index + 1]
                index += 1
            case "--profile":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    self = .usageError("--profile needs a profile name")
                    return
                }
                profile = arguments[index + 1]
                index += 1
            default:
                if argument.hasPrefix("--profile=") {
                    profile = String(argument.dropFirst("--profile=".count))
                } else if argument.hasPrefix("--export=") {
                    exporting = true
                    exportFile = String(argument.dropFirst("--export=".count))
                } else if argument.hasPrefix("--import=") {
                    importFile = String(argument.dropFirst("--import=".count))
                } else if argument == "-" || !argument.hasPrefix("-") {
                    others.append(argument)
                } else if !argument.hasPrefix("--") {
                    // AppKit-style defaults (`-NSDocumentRevisionsDebugMode YES`)
                    // that Xcode passes: skip the key and its value.
                    index += 1
                } else {
                    self = .usageError("Unknown option: \(argument)")
                    return
                }
            }
            index += 1
        }
        if exporting, exportFile == nil, others.count == 1 {
            exportFile = others.removeFirst()
        }
        if let other = others.first {
            self = .usageError("Unknown option: \(other)")
            return
        }

        if help {
            self = .help
            return
        }
        if let profile, profile.trimmingCharacters(in: .whitespaces).isEmpty {
            self = .usageError("--profile needs a profile name")
            return
        }
        if exportFile == "" || importFile == "" {
            self = .usageError("--\(exporting ? "export" : "import")= needs a file")
            return
        }
        if replace && keepBoth {
            self = .usageError("Use --replace or --keep-both, not both")
            return
        }
        if (replace || keepBoth) && importFile == nil {
            self = .usageError("--replace and --keep-both go with --import")
            return
        }
        let oneOf = "Use one of --switch, --profile NAME, --list, --export or --import"
        if exporting {
            if autoSwitch || list || importFile != nil {
                self = .usageError(oneOf)
            } else {
                self = dryRun ? .usageError("--dry-run goes with --switch, --profile or --import")
                    : .export(file: exportFile, profile: profile)
            }
            return
        }
        if let importFile {
            self = autoSwitch || list || profile != nil ? .usageError(oneOf)
                : .importProfiles(file: importFile, onMatch: replace ? .replace : keepBoth ? .keepBoth : .stop, dryRun: dryRun)
            return
        }
        switch (autoSwitch, profile, list) {
        case (true, nil, false):
            self = .autoSwitch(dryRun: dryRun)
        case (false, let name?, false):
            self = .switchTo(profile: name, dryRun: dryRun)
        case (false, nil, true):
            self = dryRun ? .usageError("--dry-run goes with --switch, --profile or --import") : .list
        default:
            self = .usageError(oneOf)
        }
    }
}
