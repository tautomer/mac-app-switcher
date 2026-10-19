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
    /// latest snapshot disagrees: then it has only just changed.
    func since(_ condition: NetworkCondition, was value: Bool, at now: Date) -> Date {
        var since = now
        for entry in entries.reversed() {
            guard condition.evaluate(entry.snapshot) == value else { break }
            since = entry.since
        }
        return since
    }
}
