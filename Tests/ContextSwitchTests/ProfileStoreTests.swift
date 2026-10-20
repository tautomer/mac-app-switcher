import Foundation
import Testing

/// A new, empty temporary folder.
func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContextSwitchTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// profiles.json in a new temporary folder.
private func temporaryProfilesURL() throws -> URL {
    try temporaryFolder().appendingPathComponent("profiles.json")
}

@Suite struct ProfileStoreTests {
    /// "Office" has a condition from a newer version; "Home" is fine.
    let mixed = """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Office","priority":5,
          "conditions":[{"id":"22222222-2222-2222-2222-222222222222","condition":{"someFutureCondition":{"_0":"x"}},"futureFlag":true}],
          "appRules":[]},
         {"id":"44444444-4444-4444-4444-444444444444","name":"Home","priority":2,"conditions":[],"appRules":[]}]
        """

    @Test func leavesOutAProfileItCannotReadAndWritesItBackAsItWas() throws {
        let url = try temporaryProfilesURL()
        try Data(mixed.utf8).write(to: url)
        let store = ProfileStore(fileURL: url)
        #expect(store.profiles.map(\.name) == ["Home"])
        guard case .unreadableProfiles(let lost)? = store.problem else {
            Issue.record("expected unreadableProfiles, got \(String(describing: store.problem))")
            return
        }
        #expect(lost.map(\.name) == ["Office"])
        #expect(lost[0].reason.contains("conditions[0].condition"))
        #expect(store.problem?.summary == "Couldn't read the profile “Office”")

        var home = store.profiles[0]
        home.priority = 3
        try store.upsert(home)

        let original = try JSONDecoder().decode([JSONValue].self, from: Data(mixed.utf8))
        let saved = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
        #expect(saved.contains(original[0]))
        let reloaded = ProfileStore(fileURL: url)
        #expect(reloaded.profiles.map(\.priority) == [3])
        // Still unreadable, now after the others.
        #expect(reloaded.problem?.summary == store.problem?.summary)
    }

    @Test func leavesAnUnreadableFileAloneUntilSavingThenMovesItAside() throws {
        let url = try temporaryProfilesURL()
        let broken = Data(#"[{"name": "Office","#.utf8)
        try broken.write(to: url)
        let store = ProfileStore(fileURL: url)
        #expect(store.profiles.map(\.name) == ["Default"])
        guard case .unreadableFile(let reason, let backup?)? = store.problem else {
            Issue.record("expected unreadableFile, got \(String(describing: store.problem))")
            return
        }
        #expect(reason.hasPrefix("Not valid JSON"))
        #expect(backup.lastPathComponent.hasPrefix("profiles-unreadable-"))
        #expect(try Data(contentsOf: url) == broken)
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        try store.upsert(Profile(name: "New"))
        #expect(try Data(contentsOf: backup) == broken)
        #expect(store.problem == nil)
        #expect(ProfileStore(fileURL: url).profiles.map(\.name) == ["Default", "New"])
    }

    @Test func copiesAFileWithUnreadableProfilesBeforeFirstSavingOverIt() throws {
        // Not every number can be written back exactly (this one is past
        // Int64.min), so the original is kept too, once.
        let url = try temporaryProfilesURL()
        let original = Data(#"[{"name":"Future","priority":-9223372036854775809}]"#.utf8)
        try original.write(to: url)
        let store = ProfileStore(fileURL: url)
        try store.upsert(Profile(name: "Home"))
        try store.upsert(Profile(name: "Work"))

        let folder = url.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("profiles-unreadable-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(try #require(backups.first))) == original)
        guard case .unreadableProfiles? = store.problem else {
            Issue.record("expected unreadableProfiles, got \(String(describing: store.problem))")
            return
        }
    }

    @Test func aFailedSaveKeepsTheFileAndTheProblemUntilOneWorks() throws {
        let url = try temporaryProfilesURL()
        let broken = Data("[".utf8)
        try broken.write(to: url)
        let store = ProfileStore(fileURL: url)
        // An immutable file can be copied but not replaced. (The copy is
        // immutable too, so unlock everything after.)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.appendingPathComponent(name).path)
            }
        }
        let new = Profile(name: "New")
        #expect(throws: (any Error).self) { try store.upsert(new) }
        #expect(try Data(contentsOf: url) == broken)
        guard case .unreadableFile? = store.problem else {
            Issue.record("a failed save cleared the problem")
            return
        }

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        try store.upsert(new)
        #expect(store.problem == nil)
        #expect(ProfileStore(fileURL: url).profiles.map(\.name) == ["Default", "New"])
        // The copy made by the failed attempt is the one kept.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("profiles-unreadable-") }.count == 1)
    }

    @Test func neverCopiesOverAFileAlreadyThere() throws {
        let url = try temporaryProfilesURL()
        let original = Data(#"[{"name":"Office","#.utf8)
        try original.write(to: url)
        let store = ProfileStore(fileURL: url)
        guard case .unreadableFile(_, let planned?)? = store.problem else {
            Issue.record("expected unreadableFile, got \(String(describing: store.problem))")
            return
        }
        // e.g. another recovery in the same second.
        let other = Data("someone else's".utf8)
        try other.write(to: planned)
        try store.upsert(Profile(name: "New"))

        #expect(try Data(contentsOf: planned) == other)
        let folder = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path).map {
            try Data(contentsOf: folder.appendingPathComponent($0))
        }
        #expect(contents.contains(original))
    }

    @Test func aFolderMovedAwayIsFixedByTheNextSave() throws {
        let folder = try temporaryFolder()
        let target = folder.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = ProfileStore(fileURL: target)
        try FileManager.default.moveItem(at: target, to: folder.appendingPathComponent("moved-away"))
        try store.upsert(Profile(name: "New"))
        #expect(store.problem == nil)
    }

    @Test func neverMovesOrReplacesAFolder() throws {
        // e.g. CONTEXTSWITCH_PROFILES pointed at a folder by mistake.
        let folder = try temporaryFolder()
        let target = folder.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        let store = ProfileStore(fileURL: target)
        #expect(store.profiles.map(\.name) == ["Default"])
        #expect(store.problem == .unreadableFile(reason: "It's a folder, not a file.", backupURL: nil))

        #expect(throws: ProfileStore.SaveError.self) { try store.upsert(Profile(name: "New")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["profiles.json"])
        #expect(try String(contentsOf: target.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
    }

    @Test func writesBackNumbersBeyondInt64Exactly() throws {
        let url = try temporaryProfilesURL()
        try Data(#"[{"name":"Future","priority":18446744073709551615}]"#.utf8).write(to: url)
        let store = ProfileStore(fileURL: url)
        #expect(store.profiles.isEmpty)
        try store.upsert(Profile(name: "Home"))
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(#""priority":18446744073709551615"#))
    }

    @Test func aProfileWithoutAnIDKeepsTheOneItIsGiven() throws {
        // Remembered as the active profile by ID, so it has to stay the same.
        let url = try temporaryProfilesURL()
        try Data(#"[{"name":"Hand-written"}]"#.utf8).write(to: url)
        let first = try #require(ProfileStore(fileURL: url).profiles.first?.id)
        #expect(ProfileStore(fileURL: url).profiles.first?.id == first)
    }

    @Test func aFileOfTheWrongShapeIsUnreadableToo() throws {
        let url = try temporaryProfilesURL()
        try Data(#"{"name": "Office"}"#.utf8).write(to: url)
        guard case .unreadableFile? = ProfileStore(fileURL: url).problem else {
            Issue.record("expected unreadableFile")
            return
        }
    }

    @Test func startsWithASavedDefaultProfileWhenThereIsNoFile() throws {
        let url = try temporaryProfilesURL()
        let store = ProfileStore(fileURL: url)
        #expect(store.profiles.map(\.name) == ["Default"])
        #expect(store.problem == nil)
        // Saved, so it has the same ID next time.
        #expect(ProfileStore(fileURL: url).profiles.first?.id == store.profiles.first?.id)
    }

    @Test func aProfileNeedsOnlyAName() throws {
        let profile = try #require(try JSONDecoder().decode([Profile].self, from: Data(#"[{"name":"Hand-written"}]"#.utf8)).first)
        #expect(profile.name == "Hand-written")
        #expect(profile.isFallback)
        #expect(profile.priority == 0)
    }

    @Test func jsonValueRoundTrips() throws {
        let json = #"{"a":[1,1.5,true,null,"x"],"b":{"c":-7}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["a"] == .array([.int(1), .double(1.5), .bool(true), .null, .string("x")]))
        #expect(value["b"]?["c"] == .int(-7))
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }
}
