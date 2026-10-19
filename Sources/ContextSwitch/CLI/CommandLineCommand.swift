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
    case help
    case usageError(String)

    static let usage = """
        Usage: ContextSwitch --switch [--dry-run]
               ContextSwitch --profile NAME [--dry-run]
               ContextSwitch --list

          --switch        Switch once to the profile that matches right now.
          --profile NAME  Switch once to the named profile (auto-switch stays as it is).
          --dry-run       Show what would be launched or quit, without doing it.
          --list          List profiles and whether each matches right now.

        Without these options ContextSwitch starts as a menu bar app. If it's already
        running, --switch and --profile are carried out by it.
        """

    private static let options: Set = ["--switch", "--profile", "--dry-run", "--list", "--help", "-h"]

    /// nil when the arguments aren't a command-line invocation, i.e. the
    /// menu bar app should start.
    init?(arguments: [String]) {
        guard arguments.contains(where: { Self.options.contains($0) || $0.hasPrefix("--profile=") }) else {
            return nil
        }
        var autoSwitch = false, list = false, help = false, dryRun = false
        var profile: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--switch": autoSwitch = true
            case "--list": list = true
            case "--dry-run": dryRun = true
            case "--help", "-h": help = true
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
                } else if argument.hasPrefix("-") && !argument.hasPrefix("--") {
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

        if help {
            self = .help
            return
        }
        if let profile, profile.trimmingCharacters(in: .whitespaces).isEmpty {
            self = .usageError("--profile needs a profile name")
            return
        }
        switch (autoSwitch, profile, list) {
        case (true, nil, false):
            self = .autoSwitch(dryRun: dryRun)
        case (false, let name?, false):
            self = .switchTo(profile: name, dryRun: dryRun)
        case (false, nil, true):
            self = dryRun ? .usageError("--dry-run goes with --switch or --profile") : .list
        default:
            self = .usageError("Use one of --switch, --profile NAME or --list")
        }
    }
}
