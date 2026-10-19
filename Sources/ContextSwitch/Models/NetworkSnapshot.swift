import Foundation

/// A point-in-time read of "where are we": the network, the attached
/// devices and the location. Produced by NetworkMonitor + LocationMonitor
/// and fed to ProfileMatcher.
struct NetworkSnapshot: Equatable {
    /// One entry per network service that currently has an IPv4 address,
    /// primary connection first. Wi-Fi and Ethernet can both be up at once
    /// (e.g. docked at a desk), so conditions look at every connection.
    var connections: [NetworkConnection] = []
    /// DNS domain + search domains, e.g. ["corp.example.com"]. A VPN can
    /// add these as well as the physical network.
    var dnsDomains: [String] = []
    var location: SimpleLocation?
    /// Sorted, one entry per distinct device; hubs are left out.
    var usbDevices: [USBDevice] = []
    /// External displays, sorted.
    var displays: [ConnectedDisplay] = []

    static let empty = NetworkSnapshot()

    var isOnline: Bool { !connections.isEmpty }
    var primary: NetworkConnection? { connections.first }
    var wifi: NetworkConnection? { connections.first { $0.kind == .wifi } }
    var ethernet: [NetworkConnection] { connections.filter { $0.kind == .ethernet } }
}

struct NetworkConnection: Equatable, Hashable {
    enum Kind: Hashable {
        case wifi
        case ethernet
        case other
    }

    /// Service name as shown in System Settings ▸ Network, e.g. "Wi-Fi" or
    /// "USB 10/100/1000 LAN". For Ethernet this names the adapter, not the
    /// network behind it.
    var serviceName: String
    var interfaceName: String
    var kind: Kind
    var localIPv4: String?
    var routerIPv4: String?
    var routerMAC: String?
    /// Wi-Fi only. nil without Location permission — macOS redacts it.
    var ssid: String?
}

enum MACAddress {
    /// Canonical lowercase, zero-padded form, e.g. "F8-D0-E-23-50-FF" →
    /// "f8:d0:0e:23:50:ff". `arp` drops leading zeros and people type
    /// dashes, so both sides of a comparison go through this.
    static func normalize(_ raw: String) -> String {
        let octets = raw.lowercased().split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard octets.count == 6, octets.allSatisfy({ (1...2).contains($0.count) }) else {
            return raw.lowercased()
        }
        return octets.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    /// The router's MAC from a service's NetworkSignature, which macOS
    /// publishes as e.g.
    /// "IPv4.Router=10.0.0.1;IPv4.RouterHardwareAddress=f8:d0:0e:23:50:ff".
    /// (Running `arp` instead doesn't work: for apps that aren't
    /// Apple-signed, macOS reports the router as "no entry".)
    static func router(fromNetworkSignature signature: String) -> String? {
        for pair in signature.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "IPv4.RouterHardwareAddress" {
                return normalize(String(parts[1]))
            }
        }
        return nil
    }
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
