import Foundation
import Testing

@Suite struct ActivityLogTests {
    /// As when the menu bar app and a command-line run write at once: each
    /// has its own queue and file handle.
    @Test func writersSharingTheFileDoNotOverwriteEachOther() async throws {
        let url = try temporaryFolder().appendingPathComponent("ContextSwitch.log")
        let logs = [ActivityLog(fileURL: url), ActivityLog(fileURL: url)]
        await withTaskGroup(of: Void.self) { group in
            for (index, log) in logs.enumerated() {
                group.addTask {
                    for entry in 0..<300 { log.record("writer \(index) entry \(entry)") }
                    log.flush()
                }
            }
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 600)
    }

    @Test func aSandboxLogIsNeverTheProfilesFile() {
        // CONTEXTSWITCH_PROFILES can name any file, even one called ContextSwitch.log.
        for path in ["/x/ContextSwitch.log", "/x/ContextSwitch.old.log", "/x/profiles.json", "/x/no-extension"] {
            let profiles = URL(fileURLWithPath: path)
            let log = ActivityLog.fileURL(besideProfilesAt: profiles)
            #expect(log != profiles)
            #expect(ActivityLog.rotatedURL(for: log) != profiles)
        }
        #expect(ActivityLog.fileURL(besideProfilesAt: URL(fileURLWithPath: "/x/profiles.json")).lastPathComponent == "profiles.json.log")
    }
}
