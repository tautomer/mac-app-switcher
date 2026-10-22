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

    /// How long auto-switch keeps the current profile while the Mac is
    /// offline (see `autoSwitch`).
    static let offlineGrace: TimeInterval = 60

    /// What auto-switch should be on: the best match — unless a profile that
    /// would outrank it is only waiting on a timer. Then `current` stays
    /// until the timer runs out (or things change), so unplugging the dock
    /// for a few minutes doesn't pass through an in-between profile.
    /// `pending` is the first such profile, to show in the menu; `checkAt`
    /// is when to decide again even if nothing changes. A clause in its
    /// grace (the dock being restarted) keeps its profile matching until
    /// the grace runs out; then `pending` is where it'd switch.
    static func autoSwitch(for snapshot: NetworkSnapshot, in profiles: [Profile], current: Profile?,
                           history: SnapshotHistory, at now: Date)
        -> (profile: Profile?, pending: PendingMatch?, checkAt: Date?) {
        let decision = switchOrWait(for: snapshot, in: profiles, current: current, history: history, at: now)
        // "If nothing changes": this snapshot from now on, even if it hasn't
        // settled yet — else a later check would count its change from then.
        var unchanged = history
        unchanged.record(snapshot, at: now)
        let graceEnds = Set(profiles.flatMap { profile in
            profile.conditions.compactMap { $0.graceEnds(snapshot, history: unchanged, at: now) }
        })
        .filter { $0 > now }
        .sorted()
        guard let graceEnd = graceEnds.first, decision.checkAt.map({ graceEnd < $0 }) ?? true else { return decision }
        // What it'll decide then, by the same rules, for the menu to show —
        // past any grace that runs out without changing the profile.
        var forecast: PendingMatch?
        for end in graceEnds {
            if let forecast, forecast.at <= end { break }
            let then = switchOrWait(for: snapshot, in: profiles, current: decision.profile, history: unchanged, at: end)
            if then.profile?.id != decision.profile?.id {
                forecast = then.profile.map { PendingMatch(profile: $0, at: end) }
                break
            }
            forecast = forecast ?? then.pending
        }
        return (decision.profile, forecast, graceEnd)
    }

    private static func switchOrWait(for snapshot: NetworkSnapshot, in profiles: [Profile], current: Profile?,
                                     history: SnapshotHistory, at now: Date)
        -> (profile: Profile?, pending: PendingMatch?, checkAt: Date?) {
        let best = bestMatch(for: snapshot, in: profiles, history: history, at: now)
        let pending = profiles
            .compactMap { profile -> PendingMatch? in
                guard let at = profile.matchesFrom(snapshot, history: history, at: now), at > now,
                      outranks(profile, best)
                else { return nil }
                return PendingMatch(profile: profile, at: at)
            }
            .min { $0.at < $1.at }
        if let pending, let current {
            return (current, pending, pending.at)
        }
        // Offline usually means mid-switch (Wi-Fi rejoining, DHCP pending):
        // keep `current` for a while rather than bouncing to the fallback
        // and back, which would quit and relaunch apps for nothing. Only for
        // a while, though — a Mac that stays offline (undocked with Wi-Fi
        // off, on a plane) should still get the profile that matches.
        if !snapshot.isOnline, let current, best?.id != current.id {
            let until = history.offlineSince(at: now) + offlineGrace
            if until > now {
                return (current, best.map { PendingMatch(profile: $0, at: until) }, until)
            }
        }
        return (best, pending, pending?.at)
    }

    private static func outranks(_ profile: Profile, _ best: Profile?) -> Bool {
        guard let best, !best.isFallback else { return true }
        return profile.priority > best.priority
    }
}
