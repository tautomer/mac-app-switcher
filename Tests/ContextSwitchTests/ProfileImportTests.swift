import Foundation
import Testing

@Suite struct ProfileImportTests {
    let slack = AppRule(bundleIdentifier: "com.tinyspeck.slackmacgap", path: "/Applications/Slack.app",
                        displayName: "Slack", action: .launch)

    @Test func anExportImportsAsItWas() throws {
        let url = try temporaryFolder().appendingPathComponent("profiles.json")
        // "Future" is from a newer version.
        try Data(#"[{"name":"Future","conditions":[{"condition":{"someFutureCondition":{}}}]}]"#.utf8).write(to: url)
        let store = ProfileStore(fileURL: url)
        let office = Profile(name: "Office", conditions: [ConditionClause(.ssid("Corp"), duration: 300)], appRules: [slack], priority: 2)
        try store.upsert(office)
        try store.upsert(Profile(name: "Home", priority: 1))

        let all = try ProfileStore.readImport(store.exportData())
        #expect(all.profiles == store.profiles)
        // Kept, as everything is exported, but can't be imported here either.
        #expect(all.unreadable.map(\.name) == ["Future"])

        let one = try ProfileStore.readImport(store.exportData(of: [office.id]))
        #expect(one.profiles == [office])
        #expect(one.unreadable.isEmpty)
    }

    @Test func anExportIsLaidOutToBeRead() throws {
        let store = ProfileStore(fileURL: try temporaryFolder().appendingPathComponent("profiles.json"))
        try store.upsert(Profile(name: "Office", appRules: [slack]))
        let text = String(decoding: try store.exportData(), as: UTF8.self)
        #expect(text.contains("\n  "))
        #expect(text.contains(#""/Applications/Slack.app""#))
    }

    @Test func aFileThatIsntProfilesIsAnError() {
        #expect(throws: DecodingError.self) { try ProfileStore.readImport(Data("not json".utf8)) }
        #expect(throws: DecodingError.self) { try ProfileStore.readImport(Data(#"{"name":"Office"}"#.utf8)) }
    }

    @Test func matchesByIDBeforeName() {
        let office = Profile(name: "Office"), home = Profile(name: "Home")
        // An earlier export of "Home", since renamed "Office", and a new "Office".
        var renamed = home
        renamed.name = "Office"
        let imported = ProfileImport(profiles: [Profile(name: "office"), renamed, Profile(name: "Mobile")])
        #expect(imported.matches(in: [office, home]).map { $0?.id } == [office.id, home.id, nil])
    }

    @Test func eachOfYoursMatchesOnce() {
        let office = Profile(name: "Office")
        let imported = ProfileImport(profiles: [Profile(name: "Office"), Profile(name: "Office")])
        #expect(imported.matches(in: [office]).map { $0?.id } == [office.id, nil])
    }

    @Test func replacingKeepsYourIDAndPlace() {
        let office = Profile(name: "Office", priority: 2), home = Profile(name: "Home")
        let newOffice = Profile(name: "OFFICE", appRules: [slack], priority: 5), mobile = Profile(name: "Mobile")
        let merge = ProfileImport(profiles: [newOffice, mobile]).merged(into: [office, home], replacing: true)

        var replaced = newOffice
        replaced.id = office.id
        #expect(merge.profiles == [replaced, home, mobile])
        #expect(merge.imported == [replaced, mobile])
        #expect(merge.replaced == [office.id: office])
    }

    @Test func keepingBothRenamesAndGivesNewIDs() {
        let office = Profile(name: "Office"), office2 = Profile(name: "Office 2")
        var exported = office
        exported.appRules = [slack]
        let merge = ProfileImport(profiles: [exported, Profile(name: "office")]).merged(into: [office, office2], replacing: false)

        #expect(merge.replaced.isEmpty)
        #expect(merge.profiles.prefix(2) == [office, office2])
        #expect(merge.imported.map(\.name) == ["Office 3", "office 4"])
        #expect(merge.imported[0].id != office.id)
        #expect(merge.imported[0].appRules.map(\.id) != [slack.id])
        #expect(Set(merge.profiles.map(\.id)).count == 4)
    }

    @Test func repeatedIDsInTheFileAreMadeUnique() {
        // e.g. pasted together by hand.
        let home = Profile(name: "Home")
        var copy = home
        copy.name = "Cabin"
        for replacing in [true, false] {
            let merge = ProfileImport(profiles: [home, copy]).merged(into: [], replacing: replacing)
            #expect(merge.profiles.map(\.name) == ["Home", "Cabin"])
            #expect(merge.profiles[0].id == home.id)
            #expect(merge.profiles[1].id != home.id)
        }
    }

    @Test func replacementsTakeTheirNamesBeforeAdditions() {
        let office = Profile(name: "Office")
        var renamed = office
        renamed.name = "Home"
        // In either order: the replacement of Office keeps "Home", the added one doesn't.
        for order in [[Profile(name: "Home"), renamed], [renamed, Profile(name: "Home")]] {
            let merge = ProfileImport(profiles: order).merged(into: [office], replacing: true)
            #expect(merge.profiles.map(\.name) == ["Home", "Home 2"])
            #expect(merge.profiles[0].id == office.id)
        }
    }

    @Test func aReplacementTakesANameOnlyIfNoOneElseHasIt() {
        let office = Profile(name: "Office"), work = Profile(name: "Work"), home = Profile(name: "Home")
        // Swapping names is fine: the replaced profiles' names are free.
        var a = office, b = work
        (a.name, b.name) = ("Work", "Office")
        #expect(ProfileImport(profiles: [a, b]).merged(into: [office, work], replacing: true).profiles.map(\.name)
                == ["Work", "Office"])
        // Taking the name of one it doesn't replace isn't.
        var c = office
        c.name = "home"
        #expect(ProfileImport(profiles: [c]).merged(into: [office, home], replacing: true).profiles.map(\.name)
                == ["home 2", "Home"])
    }

    @Test func importsKeepClearOfTheIDsOfUnreadableProfiles() throws {
        let url = try temporaryFolder().appendingPathComponent("profiles.json")
        let id = "11111111-1111-1111-1111-111111111111"
        try Data(#"[{"id":"\#(id)","name":"Future","priority":"high"}]"#.utf8).write(to: url)
        let store = ProfileStore(fileURL: url)
        let imported = try ProfileStore.readImport(Data(#"[{"id":"\#(id)","name":"Office"}]"#.utf8))
        for replacing in [true, false] {
            let merge = store.merging(imported, replacing: replacing)
            #expect(merge.profiles.map(\.name) == ["Office"])
            #expect(merge.profiles[0].id.uuidString != id)
        }
        try store.importProfiles(store.merging(imported, replacing: false))
        let ids = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url)).compactMap { $0["id"]?.stringValue }
        #expect(ids.count == 2 && Set(ids).count == 2)
    }

    @Test func importingSaves() throws {
        let url = try temporaryFolder().appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: url)
        let merge = ProfileImport(profiles: [Profile(name: "Office")]).merged(into: store.profiles, replacing: true)
        try store.importProfiles(merge)
        #expect(ProfileStore(fileURL: url).profiles == merge.profiles)
        #expect(merge.profiles.map(\.name) == ["Default", "Office"])
    }

    @Test func uniqueNamesIgnoreCaseAndAccents() {
        let profiles = [Profile(name: "Café"), Profile(name: "cafe 2")]
        #expect(profiles.uniqueName(for: "Cafe") == "Cafe 3")
        #expect(profiles.uniqueName(for: "Home") == "Home")
    }
}

@Suite struct ImportCommandTests {
    let office = Profile(name: "Office"), home = Profile(name: "Home")

    private func data(_ profiles: [Profile]) throws -> Data {
        try JSONEncoder().encode(profiles)
    }

    @Test func profilesThatMatchYoursStopTheImportUnlessToldWhatToDo() throws {
        let file = try data([Profile(name: "office"), Profile(name: "Mobile")])
        guard case .fail(let status, let message) = ImportCommand.plan(file, from: "a.json", into: [office, home], onMatch: .stop) else {
            Issue.record("expected the import to stop")
            return
        }
        #expect(status == CommandLineCommand.ExitStatus.importMatches)
        #expect(message.contains("your “Office”"))
        #expect(message.contains("--replace") && message.contains("--keep-both"))

        guard case .importing(_, true) = ImportCommand.plan(file, from: "a.json", into: [office, home], onMatch: .replace),
              case .importing(_, false) = ImportCommand.plan(file, from: "a.json", into: [office, home], onMatch: .keepBoth),
              case .importing(_, false) = ImportCommand.plan(file, from: "a.json", into: [home], onMatch: .stop)
        else {
            Issue.record("expected imports")
            return
        }
    }

    @Test func aFileWithoutProfilesToImportFails() {
        for file in ["nope", "[]", #"[{"name":"Future","priority":"high"}]"#] {
            guard case .fail(let status, let message) = ImportCommand.plan(Data(file.utf8), from: "a.json", into: [], onMatch: .stop) else {
                Issue.record("expected \(file) to fail")
                continue
            }
            #expect(status == CommandLineCommand.ExitStatus.badData)
            #expect(message.hasPrefix("Couldn't import a.json: "))
        }
    }

    @Test func theReportSaysWhatHappenedToEach() throws {
        var renamed = office
        renamed.name = "Work"
        let imported = ProfileImport(profiles: [renamed, Profile(name: "home"), Profile(name: "Mobile")],
                                     unreadable: [.init(name: "Future", reason: "at priority: Expected Int")])
        let replacing = ImportCommand.report(imported.merged(into: [office, home], replacing: true), of: imported,
                                             from: "a.json", dryRun: false)
        #expect(replacing == """
            Imported 3 profiles from a.json.
              ▸ replaced your “Office” with “Work”
              ▸ replaced your “Home” with “home”
              ▸ added “Mobile”
              Left out, as it couldn't be read (it may have been saved by a newer version of ContextSwitch, or mistyped by hand):
                “Future”: at priority: Expected Int
            """)
        let keepingBoth = ImportCommand.report(imported.merged(into: [office, home], replacing: false), of: imported,
                                               from: "a.json", dryRun: true)
        #expect(keepingBoth.hasPrefix("""
            Would import 3 profiles from a.json.
              ▸ would add “Work”
              ▸ would add “home” as “home 2”
              ▸ would add “Mobile”
            """))
    }
}
