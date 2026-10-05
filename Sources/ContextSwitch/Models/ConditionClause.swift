import Foundation

/// One row in a profile's condition list: a condition, optionally negated,
/// joined to the previous row by "and" or "or". "and" binds tighter than
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

    init(_ condition: NetworkCondition, connector: Connector = .and, isNegated: Bool = false) {
        self.condition = condition
        self.connector = connector
        self.isNegated = isNegated
    }

    /// nil when it can't be told yet (see `NetworkCondition.evaluate`).
    func evaluate(_ snapshot: NetworkSnapshot) -> Bool? {
        condition.evaluate(snapshot).map { $0 != isNegated }
    }

    var summary: String {
        "\(isNegated ? "not " : "")\(condition.kindLabel) “\(condition.valueLabel)”"
    }

    private enum CodingKeys: String, CodingKey {
        case id, connector, isNegated, condition
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
