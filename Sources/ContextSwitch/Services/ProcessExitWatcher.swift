import Foundation
import Darwin

/// Says when a process exits, and how, even one that isn't ours: an app
/// opened through Launch Services is a child of launchd. kqueue's
/// NOTE_EXITSTATUS gives the exit status to any process allowed to signal
/// the one exiting (any of the same user's), not only to its parent as
/// `man kqueue` says — <sys/event.h> has it right. That's what tells a
/// crash from a quit.
@MainActor
final class ProcessExitWatcher {
    /// With how it ended, or nil if macOS wouldn't say.
    var onExit: ((pid_t, ProcessExit?) -> Void)?

    private let descriptor = kqueue()
    private var source: DispatchSourceRead?
    /// Those being watched, and whether we'll hear how they end.
    private var watched: [pid_t: Bool] = [:]

    init() {
        // Out of file descriptors: then `watch` just fails.
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readEvents() }
        }
        source.resume()
        self.source = source
    }

    /// Watches `pid` until it exits; false if it's gone already.
    @discardableResult
    func watch(_ pid: pid_t) -> Bool {
        // Not a process: an app without one (e.g. terminated automatically) has -1.
        guard pid > 0 else { return false }
        guard watched[pid] == nil else { return true }
        var getsStatus = true
        var error = register(pid, notes: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS))
        if error == EACCES {
            // Not allowed to know how it ends: at least hear that it did.
            getsStatus = false
            error = register(pid, notes: UInt32(NOTE_EXIT))
        }
        guard error == 0 else { return false }
        watched[pid] = getsStatus
        return true
    }

    /// 0, or the error kevent(2) gave.
    private func register(_ pid: pid_t, notes: UInt32) -> Int32 {
        var change = kevent()
        change.ident = UInt(pid)
        change.filter = Int16(EVFILT_PROC)
        change.flags = UInt16(EV_ADD | EV_ONESHOT)
        change.fflags = notes
        return kevent(descriptor, &change, 1, nil, 0, nil) < 0 ? errno : 0
    }

    private func readEvents() {
        // Not [kevent](…), which Swift reads as an array of the function.
        var events = Array(repeating: kevent(), count: 8)
        var noWait = timespec()
        while true {
            let count = Int(kevent(descriptor, nil, 0, &events, Int32(events.count), &noWait))
            guard count > 0 else { return }
            for event in events.prefix(count) {
                let pid = pid_t(event.ident)
                guard let getsStatus = watched.removeValue(forKey: pid) else { continue }
                onExit?(pid, getsStatus ? ProcessExit(waitStatus: Int32(truncatingIfNeeded: event.data)) : nil)
            }
            if count < events.count { return }
        }
    }
}
