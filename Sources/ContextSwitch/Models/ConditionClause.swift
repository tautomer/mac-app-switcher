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
    /// Seconds the clause keeps counting after it stops holding, e.g. "dock
    /// connected, with 5 min grace", so restarting the dock doesn't switch
    /// away from its profile. nil = it stops counting right away. Not used
    /// together with `duration` (see `timer`).
    var grace: TimeInterval?

    /// A clause's timer, as the editor sets it: one kind at a time.
    ///
    /// Saved under "duration": seconds for `holdsFor`, as before grace
    /// existed, and `{"grace": seconds}` for `graceFor`. A version without
    /// grace then can't misread the clause as untimed (and drop the grace
    /// when it saves): it fails to read the profile, so it keeps it as is.
    enum Timer: Hashable, Codable {
        /// Counts only once it has held this long (`duration`).
        case holdsFor(TimeInterval)
        /// Keeps counting this long after it stops holding (`grace`).
        case graceFor(TimeInterval)

        private enum CodingKeys: String, CodingKey {
            case grace
        }

        init(from decoder: Decoder) throws {
            if let seconds = try? decoder.singleValueContainer().decode(TimeInterval.self) {
                self = .holdsFor(seconds)
            } else {
                self = .graceFor(try decoder.container(keyedBy: CodingKeys.self).decode(TimeInterval.self, forKey: .grace))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .holdsFor(let seconds):
                var container = encoder.singleValueContainer()
                try container.encode(seconds)
            case .graceFor(let seconds):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(seconds, forKey: .grace)
            }
        }
    }

    var timer: Timer? {
        get {
            if let duration { return .holdsFor(duration) }
            return grace.map { .graceFor($0) }
        }
        set {
            switch newValue {
            case .holdsFor(let seconds)?: duration = seconds; grace = nil
            case .graceFor(let seconds)?: duration = nil; grace = seconds
            case nil: duration = nil; grace = nil
            }
        }
    }

    init(_ condition: NetworkCondition, connector: Connector = .and, isNegated: Bool = false,
         duration: TimeInterval? = nil, grace: TimeInterval? = nil) {
        self.condition = condition
        self.connector = connector
        self.isNegated = isNegated
        self.duration = duration
        self.grace = grace
    }

    /// nil when it can't be told yet (see `NetworkCondition.evaluate`), or
    /// for a timed clause, without a history to tell how long it's held.
    func evaluate(_ snapshot: NetworkSnapshot, history: SnapshotHistory? = nil, at now: Date = Date()) -> Bool? {
        guard let raw = condition.evaluate(snapshot) else { return nil }
        guard raw != isNegated else {
            guard grace != nil else { return false }
            // Without a history (the command line) there's no telling when it stopped.
            guard history != nil else { return nil }
            return graceEnds(snapshot, history: history, at: now).map { $0 > now } ?? false
        }
        return holdsFrom(snapshot, history: history, at: now).map { $0 <= now }
    }

    /// When the clause holds if nothing changes: by `now` if it already
    /// does (or still counts, see `grace`), later while its timer runs.
    /// nil if it doesn't hold, or can't be told.
    func holdsFrom(_ snapshot: NetworkSnapshot, history: SnapshotHistory?, at now: Date) -> Date? {
        guard let raw = condition.evaluate(snapshot) else { return nil }
        guard raw != isNegated else {
            let counting = graceEnds(snapshot, history: history, at: now).map { $0 > now } ?? false
            return counting ? .distantPast : nil
        }
        guard let duration else { return .distantPast }
        // Without a history (the command line) there's no telling how long it's held.
        guard let history else { return nil }
        return history.since(condition, was: raw, at: now) + duration
    }

    /// For a clause with `grace` that doesn't hold right now: when it stops
    /// counting, if nothing changes — in the past once it has. nil if it
    /// holds, has no grace, wasn't seen holding just before (it was unknown,
    /// or it's been this way since launch), or without a history.
    func graceEnds(_ snapshot: NetworkSnapshot, history: SnapshotHistory?, at now: Date) -> Date? {
        guard let grace, let history, let raw = condition.evaluate(snapshot), raw == isNegated else { return nil }
        return history.stopped(condition, being: !raw, at: now).map { $0 + grace }
    }

    var summary: String {
        "\(isNegated ? "not " : "")\(condition.kindLabel) “\(condition.valueLabel)”"
            + (duration.map { " for \(Self.label(forDuration: $0))" } ?? "")
            + (grace.map { " with \(Self.label(forDuration: $0)) grace" } ?? "")
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
        /// Read only: where builds before `Timer`'s nested form saved grace.
        case grace
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(connector, forKey: .connector)
        try container.encode(isNegated, forKey: .isNegated)
        try container.encode(condition, forKey: .condition)
        try container.encodeIfPresent(timer, forKey: .duration)
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
        timer = try container.decodeIfPresent(Timer.self, forKey: .duration)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .grace).map(Timer.graceFor)
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
