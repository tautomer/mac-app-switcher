import Foundation
import Testing

@Suite struct CommandLineParsingTests {
    @Test func normalLaunchesStartTheApp() {
        #expect(CommandLineCommand(arguments: []) == nil)                                      // Finder, Dock, login item
        #expect(CommandLineCommand(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]) == nil) // Xcode
    }

    @Test func switchAndProfile() {
        #expect(CommandLineCommand(arguments: ["--switch"]) == .autoSwitch(dryRun: false))
        #expect(CommandLineCommand(arguments: ["--switch", "--dry-run"]) == .autoSwitch(dryRun: true))
        #expect(CommandLineCommand(arguments: ["--profile", "Home Office"]) == .switchTo(profile: "Home Office", dryRun: false))
        #expect(CommandLineCommand(arguments: ["--profile=Home", "--dry-run"]) == .switchTo(profile: "Home", dryRun: true))
        #expect(CommandLineCommand(arguments: ["--list"]) == .list)
        #expect(CommandLineCommand(arguments: ["-h"]) == .help)
    }

    @Test func xcodeArgumentsAreSkippedAlongsideOptions() {
        #expect(CommandLineCommand(arguments: ["--switch", "-NSDocumentRevisionsDebugMode", "YES"]) == .autoSwitch(dryRun: false))
    }

    @Test func mistakesAreUsageErrors() {
        for arguments in [["--profile"], ["--profile", "--switch"], ["--profile", " "], ["--switch", "--list"],
                          ["--dry-run"], ["--list", "--dry-run"], ["--switch", "extra"]] {
            guard case .usageError = CommandLineCommand(arguments: arguments) else {
                Issue.record("expected a usage error for \(arguments)")
                continue
            }
        }
    }
}

@Suite struct ProfileLookupTests {
    @Test func namesMatchIgnoringCaseAndAccents() {
        let profiles = [Profile(name: "Café"), Profile(name: "Office", priority: 1)]
        #expect(profiles.profile(named: "cafe")?.name == "Café")
        #expect(profiles.profile(named: " OFFICE ")?.name == "Office")
        #expect(profiles.profile(named: "Home") == nil)
    }

    @Test func repeatedNamesPickTheHighestPriority() {
        let low = Profile(name: "Work", priority: 0), high = Profile(name: "work", priority: 5)
        #expect([low, high].profile(named: "Work")?.id == high.id)
    }
}
