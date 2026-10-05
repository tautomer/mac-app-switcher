import Foundation
import SystemConfiguration
import CoreWLAN

/// A network service from the current network Location (System Settings ▸
/// Network), e.g. "Wi-Fi" or "USB 10/100/1000 LAN".
struct NetworkService: Hashable, Identifiable {
    let id: String
    let name: String
    let interfaceName: String
    let kind: NetworkConnection.Kind
}

enum NetworkInventory {
    /// Enabled services in the current Location, in service order. Reads
    /// only the current set — SCNetworkServiceCopyAll would return every
    /// Location's copy of each service.
    static func services() -> [NetworkService] {
        guard let prefs = SCPreferencesCreate(nil, "ContextSwitch" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService]
        else { return [] }

        let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let result = services.compactMap { service -> NetworkService? in
            guard SCNetworkServiceGetEnabled(service),
                  let id = SCNetworkServiceGetServiceID(service) as String?,
                  let name = SCNetworkServiceGetName(service) as String?,
                  let iface = SCNetworkServiceGetInterface(service),
                  let bsd = SCNetworkInterfaceGetBSDName(iface) as String?
            else { return nil }
            let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            let kind: NetworkConnection.Kind
            if type == kSCNetworkInterfaceTypeIEEE80211 as String {
                kind = .wifi
            } else if type == kSCNetworkInterfaceTypeEthernet as String {
                kind = .ethernet
            } else {
                kind = .other
            }
            return NetworkService(id: id, name: name, interfaceName: bsd, kind: kind)
        }
        return result.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// Wi-Fi networks this Mac has joined before. Unlike the current SSID,
    /// macOS lists these without Location permission.
    static func savedWiFiNetworks() -> [String] {
        let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        var seen = Set<String>()
        return profiles.compactMap(\.ssid).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
