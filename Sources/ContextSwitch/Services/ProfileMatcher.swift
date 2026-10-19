import Foundation

/// A profile that will match once a timer runs out, if nothing changes.
struct PendingMatch: Equatable {
    let profile: Profile
    let at: Date
}

enum ProfileMatcher {
    /// Picks the best profile for the given snapshot: the highest-priority
    /// profile among those whose conditions all match, falling back to the
    /// explicit fallback profile (no conditions) if nothing else matches,
    /// and finally nil if there's no fallback either.
    static func bestMatch(for snapshot: NetworkSnapshot, in profiles: [Profile],
                          history: SnapshotHistory? = nil, at now: Date = Date()) -> Profile? {
        let matched = profiles.filter { $0.matches(snapshot, history: history, at: now) }
        if let best = matched.max(by: { $0.priority < $1.priority }) {
            return best
        }
        return profiles.first { $0.isFallback }
    }

    /// What auto-switch should be on: the best match — unless a profile that
    /// would outrank it is only waiting on a timer. Then `current` stays
    /// until the timer runs out (or things change), so unplugging the dock
    /// for a few minutes doesn't pass through an in-between profile.
    /// `pending` is the first such profile, to check on when it's due.
    static func autoSwitch(for snapshot: NetworkSnapshot, in profiles: [Profile], current: Profile?,
                           history: SnapshotHistory, at now: Date) -> (profile: Profile?, pending: PendingMatch?) {
        let best = bestMatch(for: snapshot, in: profiles, history: history, at: now)
        let pending = profiles
            .compactMap { profile -> PendingMatch? in
                guard let at = profile.matchesFrom(snapshot, history: history, at: now), at > now,
                      outranks(profile, best)
                else { return nil }
                return PendingMatch(profile: profile, at: at)
            }
            .min { $0.at < $1.at }
        if pending != nil, let current {
            return (current, pending)
        }
        return (best, pending)
    }

    private static func outranks(_ profile: Profile, _ best: Profile?) -> Bool {
        guard let best, !best.isFallback else { return true }
        return profile.priority > best.priority
    }
}
