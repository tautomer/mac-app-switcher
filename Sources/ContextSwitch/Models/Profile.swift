import Foundation

struct Profile: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var conditions: [NetworkCondition] = []
    var appRules: [AppRule] = []

    /// Higher priority wins when multiple profiles' conditions all match.
    var priority: Int = 0

    /// A profile with no conditions is the fallback/default — it matches
    /// when nothing else does.
    var isFallback: Bool { conditions.isEmpty }

    func matches(_ snapshot: NetworkSnapshot) -> Bool {
        guard !conditions.isEmpty else { return false }
        return conditions.allSatisfy { $0.isSatisfied(by: snapshot) }
    }
}

extension NetworkCondition {
    func isSatisfied(by snapshot: NetworkSnapshot) -> Bool {
        let connections = snapshot.connections
        switch self {
        case .ssid(let want):
            return connections.contains { $0.ssid?.caseInsensitiveCompare(want) == .orderedSame }
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
            guard let here = snapshot.location else { return false }
            return here.distanceMeters(toLatitude: lat, longitude: lon) <= radius
        }
    }
}
