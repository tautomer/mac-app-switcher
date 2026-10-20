import Foundation

/// A single signal a profile can match against — something about the
/// network, the location or the attached devices, as read into a
/// `NetworkSnapshot`.
enum NetworkCondition: Codable, Hashable, Identifiable {
    case ssid(String)
    /// A specific wired network. macOS names Ethernet adapters, not the
    /// networks behind them, so — like Windows — we recognise the network
    /// by its router's MAC address and let the user name it.
    case wiredNetwork(name: String, routerMAC: String)
    /// Connected through a particular adapter (network service), e.g. the
    /// Ethernet port of a dock that only lives at one desk.
    case ethernetAdapter(String)
    case dnsDomain(String)
    case gatewayIP(String)
    case gatewayMAC(String)
    case subnet(cidr: String)
    case location(name: String, latitude: Double, longitude: Double, radiusMeters: Double)
    /// Plugged in directly or through a hub or dock. With a serial number
    /// it's that one unit — your office keyboard, not the same model at
    /// home; without, any of the model.
    case usbDevice(name: String, vendorID: Int, productID: Int, serialNumber: String?)
    /// An external display, by the model (and serial number, if recorded)
    /// in its EDID.
    case display(name: String, vendorID: Int, modelID: Int, serialNumber: Int?)

    var id: String {
        switch self {
        case .ssid(let v): return "ssid:\(v)"
        case .wiredNetwork(_, let mac): return "wiredNetwork:\(MACAddress.normalize(mac))"
        case .ethernetAdapter(let v): return "ethernetAdapter:\(v)"
        case .dnsDomain(let v): return "dnsDomain:\(v.lowercased())"
        case .gatewayIP(let v): return "gatewayIP:\(v)"
        case .gatewayMAC(let v): return "gatewayMAC:\(MACAddress.normalize(v))"
        case .subnet(let v): return "subnet:\(v)"
        case .location(let name, let lat, let lon, let r): return "location:\(name):\(lat):\(lon):\(r)"
        case .usbDevice(_, let vendor, let product, let serial): return "usbDevice:\(vendor):\(product):\(serial ?? "*")"
        case .display(_, let vendor, let model, let serial): return "display:\(vendor):\(model):\(serial.map(String.init) ?? "*")"
        }
    }

    var kindLabel: String {
        switch self {
        case .ssid: return "Wi-Fi Network"
        case .wiredNetwork: return "Ethernet Network"
        case .ethernetAdapter: return "Ethernet Adapter"
        case .dnsDomain: return "DNS Domain"
        case .gatewayIP: return "Router IP"
        case .gatewayMAC: return "Router MAC"
        case .subnet: return "Subnet"
        case .location: return "Place"
        case .usbDevice: return "USB Device"
        case .display: return "Display"
        }
    }

    var valueLabel: String {
        switch self {
        case .ssid(let v): return v
        case .wiredNetwork(let name, let mac): return "\(name) (router \(MACAddress.normalize(mac)))"
        case .ethernetAdapter(let v): return v
        case .dnsDomain(let v): return v
        case .gatewayIP(let v): return v
        case .gatewayMAC(let v): return MACAddress.normalize(v)
        case .subnet(let v): return v
        case .location(let name, let lat, let lon, let radius):
            // The name is optional; without one, the place is where it is.
            let place = name.isEmpty ? String(format: "%.4f, %.4f", lat, lon) : name
            return "\(place) (±\(Int(radius))m)"
        case .usbDevice(let name, _, _, _): return name
        case .display(let name, _, _, _): return name
        }
    }

    var systemImage: String {
        switch self {
        case .ssid: return "wifi"
        case .wiredNetwork, .ethernetAdapter: return "cable.connector.horizontal"
        case .dnsDomain: return "globe"
        case .gatewayIP, .gatewayMAC, .subnet: return "point.3.connected.trianglepath.dotted"
        case .location: return "mappin.and.ellipse"
        case .usbDevice: return "cable.connector"
        case .display: return "display"
        }
    }

    /// True if this condition needs the user to have granted Location
    /// permission (SSID reads and geofencing both require it on macOS).
    var requiresLocationPermission: Bool {
        switch self {
        case .ssid, .location: return true
        case .wiredNetwork, .ethernetAdapter, .dnsDomain, .gatewayIP, .gatewayMAC, .subnet, .usbDevice, .display:
            return false
        }
    }
}
