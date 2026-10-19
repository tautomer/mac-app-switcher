import Foundation

/// One row in a profile's condition list: a condition, optionally negated
/// and optionally timed ("for 5 min"), joined to the previous row by "and"
/// or "or". "and" binds tighter than
/// "or", so `A and B or C` means `(A and B) or C` — any rule can be written
/// this way, at worst by repeating a condition.
struct ConditionClause: Codable, Hashable, Identifiable {
    enum Connector: String, Codable, CaseIterable {
        case and
        case or
    }

    var id = UUID()
    /// Joins this clause to the previous one. Ignored on the first clause.
    var connector: Connector = .and
    var isNegated = false
    var condition: NetworkCondition
    /// Seconds the clause (after any "not") must have held before it
    /// counts, e.g. "dock not connected for 5 minutes" so a quick unplug
    /// doesn't switch. nil = right away.
    var duration: TimeInterval?

    init(_ condition: NetworkCondition, connector: Connector = .and, isNegated: Bool = false, duration: TimeInterval? = nil) {
        self.condition = condition
        self.connector = connector
        self.isNegated = isNegated
        self.duration = duration
    }

    /// nil when it can't be told yet (see `NetworkCondition.evaluate`), or
    /// for a timed clause, without a history to tell how long it's held.
    func evaluate(_ snapshot: NetworkSnapshot, history: SnapshotHistory? = nil, at now: Date = Date()) -> Bool? {
        guard let value = condition.evaluate(snapshot).map({ $0 != isNegated }) else { return nil }
        guard value else { return false }
        return holdsFrom(snapshot, history: history, at: now).map { $0 <= now }
    }

    /// When the clause holds if nothing changes: by `now` if it already
    /// does, later while its timer runs. nil if it doesn't hold, or can't
    /// be told.
    func holdsFrom(_ snapshot: NetworkSnapshot, history: SnapshotHistory?, at now: Date) -> Date? {
        guard let raw = condition.evaluate(snapshot), raw != isNegated else { return nil }
        guard let duration else { return .distantPast }
        // Without a history (the command line) there's no telling how long it's held.
        guard let history else { return nil }
        return history.since(condition, was: raw, at: now) + duration
    }

    var summary: String {
        "\(isNegated ? "not " : "")\(condition.kindLabel) “\(condition.valueLabel)”"
            + (duration.map { " for \(Self.label(forDuration: $0))" } ?? "")
    }

    /// e.g. "5 min", "1 hour", "1 h 30 min".
    static func label(forDuration duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if rest == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours) h \(rest) min"
    }

    private enum CodingKeys: String, CodingKey {
        case id, connector, isNegated, condition, duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.condition) else {
            // Profiles saved before boolean logic stored bare conditions,
            // all joined by "and".
            self = ConditionClause(try NetworkCondition(from: decoder))
            return
        }
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        connector = try container.decodeIfPresent(Connector.self, forKey: .connector) ?? .and
        isNegated = try container.decodeIfPresent(Bool.self, forKey: .isNegated) ?? false
        condition = try container.decode(NetworkCondition.self, forKey: .condition)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
    }
}

/// Three-valued logic over `Bool?`, where nil means "can't tell". It keeps
/// "not" honest: without Location access we don't know the Wi-Fi name, so
/// "not on Home-WiFi" is unknown rather than true.
enum Kleene {
    /// false if any is false, else unknown if any is unknown, else true.
    static func all(_ values: [Bool?]) -> Bool? {
        if values.contains(false) { return false }
        return values.contains(nil) ? nil : true
    }

    /// true if any is true, else unknown if any is unknown, else false.
    static func any(_ values: [Bool?]) -> Bool? {
        if values.contains(true) { return true }
        return values.contains(nil) ? nil : false
    }
}
