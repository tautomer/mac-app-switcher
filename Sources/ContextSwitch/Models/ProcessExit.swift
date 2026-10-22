import Foundation

/// How a program ended, from its wait(2) status (as kqueue gives it for an
/// app opened through Launch Services) or from Foundation's `Process`.
enum ProcessExit: Equatable {
    case exited(Int32)
    /// Ended by a signal it didn't handle, e.g. SIGSEGV.
    case signaled(Int32)

    /// nil for a status that says the program stopped (paused), not ended.
    init?(waitStatus status: Int32) {
        let signal = status & 0x7f
        switch signal {
        case 0: self = .exited((status >> 8) & 0xff)
        case 0x7f: return nil
        default: self = .signaled(signal)
        }
    }

    init(_ reason: Process.TerminationReason, status: Int32) {
        self = reason == .uncaughtSignal ? .signaled(status) : .exited(status)
    }

    /// Signals that end a program on purpose: SIGTERM asks it to (as
    /// quitting a program run directly does), SIGKILL forces it (as Force
    /// Quit does), SIGINT and SIGHUP are Control-C and closing its Terminal.
    private static let deliberateSignals: Set<Int32> = [SIGTERM, SIGKILL, SIGINT, SIGHUP]

    /// Whether it crashed, as far as can be told from outside: it exited
    /// with an error status (a Rust panic exits with 101), or a signal like
    /// SIGSEGV or SIGABRT ended it. Quitting it, ⌘Q or Force Quit, doesn't
    /// count — though an app that crashes while quitting looks like a crash.
    var isCrash: Bool {
        switch self {
        case .exited(let status):
            return status != 0
        case .signaled(let signal):
            return !Self.deliberateSignals.contains(signal)
        }
    }

    /// e.g. "It exited with status 101."
    var description: String {
        switch self {
        case .exited(0):
            return "It exited normally."
        case .exited(let status):
            return "It exited with status \(status)."
        case .signaled(SIGKILL):
            return "It was killed (SIGKILL), as Force Quit does."
        case .signaled(let signal):
            return "It was stopped by a signal (\(String(cString: strsignal(signal))))."
        }
    }
}

/// Recent crashes, so ContextSwitch stops relaunching something that keeps
/// crashing.
struct CrashHistory {
    /// Relaunching gives up at the `limit`th crash within `window`.
    static let limit = 3
    static let window: TimeInterval = 5 * 60

    /// By `AppRule.targetKey`.
    private var crashes: [String: [Date]] = [:]

    /// Notes a crash of `targetKey`; true if it's still worth relaunching.
    mutating func record(_ targetKey: String, at date: Date = Date()) -> Bool {
        let recent = (crashes[targetKey] ?? []).filter { date.timeIntervalSince($0) < Self.window } + [date]
        crashes[targetKey] = recent
        return recent.count < Self.limit
    }
}
