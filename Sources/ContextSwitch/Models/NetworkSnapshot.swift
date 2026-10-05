import Foundation

/// A point-in-time read of "where are we, network-wise". Produced by
/// NetworkMonitor + LocationMonitor and fed to ProfileMatcher.
struct NetworkSnapshot: Equatable {
    var localIPv4: String?
    var gatewayIPv4: String?
    var gatewayMAC: String?
    var ssid: String?
    var interfaceName: String?
    var isWiFi: Bool = false
    var isWired: Bool = false
    var location: SimpleLocation?

    static let empty = NetworkSnapshot()
}

struct SimpleLocation: Equatable {
    var latitude: Double
    var longitude: Double

    func distanceMeters(toLatitude lat2: Double, longitude lon2: Double) -> Double {
        // Haversine formula.
        let r = 6_371_000.0
        let lat1Rad = latitude * .pi / 180
        let lat2Rad = lat2 * .pi / 180
        let dLat = (lat2 - latitude) * .pi / 180
        let dLon = (lon2 - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1Rad) * cos(lat2Rad) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }
}

/// Minimal IPv4 CIDR containment check, e.g. "192.168.1.0/24".
struct IPv4Subnet {
    let networkBits: UInt32
    let maskBits: UInt32

    init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefixLen = UInt32(parts[1]),
              prefixLen <= 32,
              let addr = IPv4Subnet.toUInt32(String(parts[0]))
        else { return nil }
        let mask: UInt32 = prefixLen == 0 ? 0 : ~UInt32(0) << (32 - prefixLen)
        self.maskBits = mask
        self.networkBits = addr & mask
    }

    func contains(_ ip: String) -> Bool {
        guard let addr = IPv4Subnet.toUInt32(ip) else { return false }
        return (addr & maskBits) == networkBits
    }

    static func toUInt32(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        return octets[0] << 24 | octets[1] << 16 | octets[2] << 8 | octets[3]
    }
}
