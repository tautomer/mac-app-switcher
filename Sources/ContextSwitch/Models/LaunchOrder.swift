import Foundation

/// Which app waits for which (`AppRule.launchesAfter`), within one profile.
enum LaunchOrder {
    /// The rule `rule` is launched after. nil if it has none, if that rule
    /// has gone (a profile edited by hand), or if the rules wait for each
    /// other in a circle, which would have them wait for ever.
    static func dependency(of rule: AppRule, in rules: [AppRule]) -> AppRule? {
        guard let id = rule.launchesAfter, id != rule.id,
              let first = rules.first(where: { $0.id == id }),
              !waits(first, for: rule.id, in: rules)
        else { return nil }
        return first
    }

    /// Whether `rule`, or a rule it waits for, and so on, is `id`.
    private static func waits(_ rule: AppRule, for id: AppRule.ID, in rules: [AppRule]) -> Bool {
        var seen: Set<AppRule.ID> = []
        var current: AppRule? = rule
        while let rule = current, seen.insert(rule.id).inserted {
            if rule.id == id { return true }
            current = rule.launchesAfter.flatMap { next in rules.first { $0.id == next } }
        }
        return false
    }

    /// What `rule` can be set to launch after, for the editor: the other
    /// apps that the profile launches, bar those that wait for `rule`
    /// already. (And the one it waits for now, whatever that does.)
    static func candidates(for rule: AppRule, in rules: [AppRule]) -> [AppRule] {
        rules.filter { other in
            other.id != rule.id
                && (other.action == .launch || other.id == rule.launchesAfter)
                && !waits(other, for: rule.id, in: rules)
        }
    }
}
