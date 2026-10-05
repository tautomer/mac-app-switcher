import Foundation

/// A single signal a profile can match against. A profile matches when ALL
/// of its conditions are satisfied (logical AND) against the current
/// `NetworkSnapshot` / location state.
enum NetworkCondition: Codable, Hashable, Identifiable {
    case ssid(String)
    case gatewayIP(String)
    case gatewayMAC(String)
    case subnet(cidr: String)
    case location(name: String, latitude: Double, longitude: Double, radiusMeters: Double)

    var id: String {
        switch self {
        case .ssid(let v): return "ssid:\(v)"
        case .gatewayIP(let v): return "gatewayIP:\(v)"
        case .gatewayMAC(let v): return "gatewayMAC:\(v)"
        case .subnet(let v): return "subnet:\(v)"
        case .location(let name, let lat, let lon, let r): return "location:\(name):\(lat):\(lon):\(r)"
        }
    }

    var kindLabel: String {
        switch self {
        case .ssid: return "Wi-Fi Network"
        case .gatewayIP: return "Router IP"
        case .gatewayMAC: return "Router (MAC)"
        case .subnet: return "Subnet"
        case .location: return "Place"
        }
    }

    var valueLabel: String {
        switch self {
        case .ssid(let v): return v
        case .gatewayIP(let v): return v
        case .gatewayMAC(let v): return v
        case .subnet(let v): return v
        case .location(let name, _, _, let radius): return "\(name) (±\(Int(radius))m)"
        }
    }

    /// True if this condition needs the user to have granted Location
    /// permission (SSID reads and geofencing both require it on macOS).
    var requiresLocationPermission: Bool {
        switch self {
        case .ssid, .location: return true
        case .gatewayIP, .gatewayMAC, .subnet: return false
        }
    }
}
