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

    @Test func exportAndImport() {
        #expect(CommandLineCommand(arguments: ["--export"]) == .export(file: nil, profile: nil))
        #expect(CommandLineCommand(arguments: ["--export", "-"]) == .export(file: "-", profile: nil))
        #expect(CommandLineCommand(arguments: ["--export", "--profile", "Office"]) == .export(file: nil, profile: "Office"))
        #expect(CommandLineCommand(arguments: ["--profile", "Office", "--export", "office.json"]) == .export(file: "office.json", profile: "Office"))
        #expect(CommandLineCommand(arguments: ["--export", "--profile", "Office", "office.json"]) == .export(file: "office.json", profile: "Office"))
        #expect(CommandLineCommand(arguments: ["--export", "--profile", "Office", "-"]) == .export(file: "-", profile: "Office"))
        #expect(CommandLineCommand(arguments: ["--export=all.json"]) == .export(file: "all.json", profile: nil))
        #expect(CommandLineCommand(arguments: ["--import", "all.json"]) == .importProfiles(file: "all.json", onMatch: .stop, dryRun: false))
        #expect(CommandLineCommand(arguments: ["--import", "-", "--replace"]) == .importProfiles(file: "-", onMatch: .replace, dryRun: false))
        #expect(CommandLineCommand(arguments: ["--keep-both", "--dry-run", "--import=a.json"])
                == .importProfiles(file: "a.json", onMatch: .keepBoth, dryRun: true))
    }

    @Test func mistakesAreUsageErrors() {
        for arguments in [["--profile"], ["--profile", "--switch"], ["--profile", " "], ["--switch", "--list"],
                          ["--dry-run"], ["--list", "--dry-run"], ["--switch", "extra"],
                          ["--import"], ["--import", "--replace"], ["--import="], ["--export="], ["--export", "a", "b"], ["--export", "--profile", "x", "a", "b"], ["--list", "-"],
                          ["--export", "--dry-run"], ["--export", "--import", "a.json"], ["--import", "a.json", "--profile", "x"],
                          ["--replace"], ["--switch", "--keep-both"], ["--import", "a.json", "--replace", "--keep-both"]] {
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

    @Test func spacesAroundEitherNameDontCount() {
        let profiles = [Profile(name: "Office ")]
        #expect(profiles.profile(named: "Office ")?.name == "Office ")
        #expect(profiles.profile(named: "office") != nil)
        #expect(profiles.uniqueName(for: "Office ") == "Office 2")
    }

    @Test func repeatedNamesPickTheHighestPriority() {
        let low = Profile(name: "Work", priority: 0), high = Profile(name: "work", priority: 5)
        #expect([low, high].profile(named: "Work")?.id == high.id)
    }
}

@Suite struct RemoteCommandTests {
    @Test func onlyAnAnswerHasAStatus() throws {
        // A version without the other kinds needs a status to take a reply for an answer.
        for (reply, kind) in [(RemoteCommand.Reply(ignoring: "1"), RemoteCommand.Reply.Kind.ignored),
                              (RemoteCommand.Reply(accepting: "1"), .accepted)] {
            #expect(reply.userInfo["status"] == nil)
            let received = try #require(RemoteCommand.Reply(userInfo: reply.userInfo))
            #expect(received.kind == kind && received.id == "1")
        }
        let answer = try #require(RemoteCommand.Reply(userInfo: RemoteCommand.Reply(id: "2", status: 3, output: "x").userInfo))
        #expect(answer.kind == .answer && answer.status == 3 && answer.output == "x")
    }

    @Test func anImportRequestComesThroughAsSentAndExpires() throws {
        let contents = Data([0xFF, 0xFE, 0x00, 0x7B])  // not UTF-8
        let sent = Date(timeIntervalSince1970: 1_000_000.25)
        let request = RemoteCommand.ImportRequest(profilesPath: "/p.json", fileName: "a.json", contents: contents,
                                                  onMatch: .keepBoth, sentAt: sent)
        let received = try #require(RemoteCommand.ImportRequest(userInfo: request.userInfo))
        #expect(received.contents == contents && received.onMatch == .keepBoth && received.fileName == "a.json")
        #expect(received.sentAt == sent)
        #expect(!received.isExpired(at: sent.addingTimeInterval(1)))
        #expect(received.isExpired(at: sent.addingTimeInterval(RemoteCommand.importExpiry)))
        #expect(RemoteCommand.importExpiry < RemoteCommand.replyTimeout)
        #expect(RemoteCommand.replyTimeout < RemoteCommand.acceptedTimeout)
    }
}
