import Foundation

enum ProfileMatcher {
    /// Picks the best profile for the given snapshot: the highest-priority
    /// profile among those whose conditions all match, falling back to the
    /// explicit fallback profile (no conditions) if nothing else matches,
    /// and finally nil if there's no fallback either.
    static func bestMatch(for snapshot: NetworkSnapshot, in profiles: [Profile]) -> Profile? {
        let matched = profiles.filter { $0.matches(snapshot) }
        if let best = matched.max(by: { $0.priority < $1.priority }) {
            return best
        }
        return profiles.first { $0.isFallback }
    }
}
