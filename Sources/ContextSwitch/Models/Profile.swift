import Foundation

struct Profile: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var conditions: [ConditionClause] = []
    var appRules: [AppRule] = []

    /// Higher priority wins when multiple profiles' conditions all match.
    var priority: Int = 0

    /// A profile with no conditions is the fallback/default — it matches
    /// when nothing else does.
    var isFallback: Bool { conditions.isEmpty }

    /// The clauses split at each "or". The profile matches when every
    /// clause in any one group holds.
    var conditionGroups: [[ConditionClause]] {
        var groups: [[ConditionClause]] = []
        for clause in conditions {
            if groups.isEmpty || clause.connector == .or {
                groups.append([clause])
            } else {
                groups[groups.count - 1].append(clause)
            }
        }
        return groups
    }

    /// nil when the outcome hinges on something we can't read yet (a hidden
    /// Wi-Fi name, no location fix). Fallback profiles evaluate to false.
    func evaluate(_ snapshot: NetworkSnapshot) -> Bool? {
        guard !conditions.isEmpty else { return false }
        return Kleene.any(conditionGroups.map { group in
            Kleene.all(group.map { $0.evaluate(snapshot) })
        })
    }

    func matches(_ snapshot: NetworkSnapshot) -> Bool {
        evaluate(snapshot) == true
    }

    /// e.g. `(Wi-Fi Network “Home” and not Ethernet Adapter “Dock”) or DNS Domain “corp.com”`
    var conditionSummary: String {
        let groups = conditionGroups
        return groups.map { group in
            let text = group.map(\.summary).joined(separator: " and ")
            return groups.count > 1 && group.count > 1 ? "(\(text))" : text
        }
        .joined(separator: " or ")
    }

    /// Adds `condition` to the "and" group at `groupIndex`, or starts a new
    /// "or" group when `groupIndex` is past the last group.
    mutating func addCondition(_ condition: NetworkCondition, toGroup groupIndex: Int) {
        let groups = conditionGroups
        guard groups.indices.contains(groupIndex), let last = groups[groupIndex].last,
              let position = conditions.firstIndex(where: { $0.id == last.id })
        else {
            conditions.append(ConditionClause(condition, connector: .or))
            return
        }
        conditions.insert(ConditionClause(condition, connector: .and), at: position + 1)
    }

    /// Removes a clause. If it started its group, the next clause in that
    /// group takes over the "or", so the group doesn't merge into the one
    /// before it.
    mutating func removeCondition(id: ConditionClause.ID) {
        guard let index = conditions.firstIndex(where: { $0.id == id }) else { return }
        let removed = conditions.remove(at: index)
        let startedGroup = index == 0 || removed.connector == .or
        if startedGroup, conditions.indices.contains(index), conditions[index].connector == .and {
            conditions[index].connector = .or
        }
    }
}

extension Array where Element == Profile {
    /// Looks a profile up by name, ignoring case and accents. If names
    /// repeat, the highest-priority one wins.
    func profile(named name: String) -> Profile? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            .max { $0.priority < $1.priority }
    }
}

extension NetworkCondition {
    /// nil when it can't be told yet: a Wi-Fi name macOS is hiding (no
    /// Location access) or no location fix. Everything else is read
    /// directly from the network state, so it's always known.
    func evaluate(_ snapshot: NetworkSnapshot) -> Bool? {
        let connections = snapshot.connections
        switch self {
        case .ssid(let want):
            let wifi = connections.filter { $0.kind == .wifi }
            if wifi.contains(where: { $0.ssid?.caseInsensitiveCompare(want) == .orderedSame }) { return true }
            return wifi.contains { $0.ssid == nil } ? nil : false
        case .wiredNetwork(_, let routerMAC):
            let want = MACAddress.normalize(routerMAC)
            return connections.contains { $0.kind == .ethernet && $0.routerMAC.map(MACAddress.normalize) == want }
        case .ethernetAdapter(let name):
            return connections.contains { $0.kind == .ethernet && $0.serviceName == name }
        case .dnsDomain(let want):
            return snapshot.dnsDomains.contains { $0.caseInsensitiveCompare(want) == .orderedSame }
        case .gatewayIP(let want):
            return connections.contains { $0.routerIPv4 == want }
        case .gatewayMAC(let want):
            let want = MACAddress.normalize(want)
            return connections.contains { $0.routerMAC.map(MACAddress.normalize) == want }
        case .subnet(let cidr):
            guard let subnet = IPv4Subnet(cidr: cidr) else { return false }
            return connections.contains { $0.localIPv4.map(subnet.contains) ?? false }
        case .location(_, let lat, let lon, let radius):
            guard let here = snapshot.location else { return nil }
            return here.distanceMeters(toLatitude: lat, longitude: lon) <= radius
        }
    }

    func isSatisfied(by snapshot: NetworkSnapshot) -> Bool {
        evaluate(snapshot) == true
    }
}
