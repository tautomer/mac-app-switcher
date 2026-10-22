import Foundation

/// The snapshots seen lately and when each began, so a timed clause can
/// tell how long it's held ("dock not connected for 5 minutes"). Built from
/// snapshots rather than per condition, so it also answers for conditions
/// added or edited since. Kept by the menu bar app while it runs; the
/// command line has none.
struct SnapshotHistory {
    struct Entry {
        let snapshot: NetworkSnapshot
        let since: Date
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []

    /// Covers timers up to a day.
    static let window: TimeInterval = 24 * 60 * 60

    /// Adds `snapshot` if it differs from the last one. The very first one
    /// counts as long-standing: what ContextSwitch finds when it starts (an
    /// unplugged dock at login) has presumably been that way a while, and
    /// the first profile shouldn't have to wait out a timer.
    mutating func record(_ snapshot: NetworkSnapshot, at now: Date) {
        guard entries.last?.snapshot != snapshot else { return }
        entries.append(Entry(snapshot: snapshot, since: entries.isEmpty ? .distantPast : now))
        // The oldest entry kept always reaches back past the window.
        while entries.count > 1, entries[1].since < now - Self.window {
            entries.removeFirst()
        }
    }

    /// Since when `condition` has been `value` without a break. `now` if the
    /// latest snapshot disagrees: then it has only just changed. Callers
    /// pass a value the current snapshot has.
    func since(_ condition: NetworkCondition, was value: Bool, at now: Date) -> Date {
        since(at: now) { condition.evaluate($0) == value }
    }

    /// When `condition` stopped being `value`, if it was until things became
    /// as they are now; `now` if the latest snapshot still has it. nil if
    /// it wasn't seen being `value` just before: it was unknown then, or
    /// things have been this way since launch. Callers pass the opposite
    /// of the value the current snapshot has.
    func stopped(_ condition: NetworkCondition, being value: Bool, at now: Date) -> Date? {
        var stopped = now
        for entry in entries.reversed() {
            switch condition.evaluate(entry.snapshot) {
            case value?: return stopped
            case nil: return nil
            default: stopped = entry.since
            }
        }
        return nil
    }

    /// Since when the Mac has been offline without a break; `now` if the
    /// latest snapshot was online.
    func offlineSince(at now: Date) -> Date {
        since(at: now) { !$0.isOnline }
    }

    private func since(at now: Date, while holds: (NetworkSnapshot) -> Bool) -> Date {
        // Nothing recorded yet: things are as they were found at launch, which
        // counts as long-standing (see `record`). Counting from `now` would
        // restart every timer at each check.
        guard !entries.isEmpty else { return .distantPast }
        var since = now
        for entry in entries.reversed() {
            guard holds(entry.snapshot) else { break }
            since = entry.since
        }
        return since
    }
}
