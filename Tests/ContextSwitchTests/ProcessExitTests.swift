import Foundation
import Darwin
import Testing

@Suite struct ProcessExitTests {
    @Test func decodesWaitStatuses() {
        #expect(ProcessExit(waitStatus: 0) == .exited(0))
        #expect(ProcessExit(waitStatus: 101 << 8) == .exited(101))
        #expect(ProcessExit(waitStatus: SIGSEGV) == .signaled(SIGSEGV))
        // With the "core dumped" bit.
        #expect(ProcessExit(waitStatus: 0x80 | SIGABRT) == .signaled(SIGABRT))
        // Stopped (SIGSTOP), not ended.
        #expect(ProcessExit(waitStatus: SIGSTOP << 8 | 0x7f) == nil)
    }

    @Test func mapsFoundationTerminations() {
        #expect(ProcessExit(.exit, status: 2) == .exited(2))
        #expect(ProcessExit(.uncaughtSignal, status: SIGTERM) == .signaled(SIGTERM))
    }

    @Test func tellsCrashesFromQuits() {
        let cases: [(ProcessExit, Bool)] = [
            (.exited(0), false),
            (.exited(1), true),
            (.exited(101), true),        // a Rust panic
            (.signaled(SIGSEGV), true),
            (.signaled(SIGABRT), true),
            (.signaled(SIGTRAP), true),  // a Swift fatalError
            (.signaled(SIGTERM), false), // asked to quit
            (.signaled(SIGKILL), false), // Force Quit
            (.signaled(SIGINT), false),
            (.signaled(SIGHUP), false),
        ]
        for (exit, isCrash) in cases {
            #expect(exit.isCrash == isCrash, "\(exit)")
        }
    }

    @Test func givesUpOnTheThirdCrashInFiveMinutes() {
        var history = CrashHistory()
        let start = Date()
        let relaunches = [
            history.record("OmniLED", at: start),
            history.record("OmniLED", at: start + 60),
            history.record("Slack", at: start + 90),  // counted on its own
            history.record("OmniLED", at: start + 120),
            // Once the last of those is five minutes old, it starts over.
            history.record("OmniLED", at: start + 120 + CrashHistory.window),
        ]
        #expect(relaunches == [true, true, true, false, true])
    }
}

@Suite struct ProcessExitWatcherTests {
    /// As for an app opened through Launch Services, whose parent is
    /// launchd: the exit status of a process that isn't our child is what
    /// tells a crash from a quit.
    @MainActor @Test(.timeLimit(.minutes(1)))
    func hearsHowAProcessThatIsntOursEnds() async throws {
        for (script, expected) in [("sleep 1; exit 101", ProcessExit.exited(101)),
                                   ("sleep 1; kill -TERM $$", .signaled(SIGTERM))] {
            let pid = try startInBackground(script)
            #expect(parent(of: pid) != getpid())
            let watcher = ProcessExitWatcher()
            try #require(watcher.watch(pid))
            let status = await withCheckedContinuation { continuation in
                watcher.onExit = { exited, status in
                    if exited == pid { continuation.resume(returning: status) }
                }
            }
            #expect(status == expected, "\(script)")
        }
    }

    @MainActor @Test func doesNotWatchAnAppWithoutAProcess() {
        // NSRunningApplication.processIdentifier is -1 for one.
        let watcher = ProcessExitWatcher()
        #expect(!watcher.watch(-1))
        #expect(!watcher.watch(0))
    }

    @MainActor @Test func doesNotWatchAProcessThatHasEnded() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(!ProcessExitWatcher().watch(process.processIdentifier))
    }

    /// Runs `script` in the background from a shell that exits right
    /// away, leaving launchd as its parent. Returns its pid.
    private func startInBackground(_ script: String) throws -> pid_t {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sh -c \"$0\" > /dev/null 2>&1 & echo $!", script]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
    }
}
