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
        switch self {
        case .ssid(let want):
            return snapshot.ssid?.caseInsensitiveCompare(want) == .orderedSame
        case .gatewayIP(let want):
            return snapshot.gatewayIPv4 == want
        case .gatewayMAC(let want):
            return snapshot.gatewayMAC?.caseInsensitiveCompare(want) == .orderedSame
        case .subnet(let cidr):
            guard let ip = snapshot.localIPv4 else { return false }
            return IPv4Subnet(cidr: cidr)?.contains(ip) ?? false
        case .location(_, let lat, let lon, let radius):
            guard let here = snapshot.location else { return false }
            return here.distanceMeters(toLatitude: lat, longitude: lon) <= radius
        }
    }
}
