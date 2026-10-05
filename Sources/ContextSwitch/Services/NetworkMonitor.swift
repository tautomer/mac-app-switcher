import Foundation
import Network
import SystemConfiguration
import CoreWLAN
import Combine

/// Watches for network changes (interface up/down, Wi-Fi join/leave, IP
/// changes) and publishes a fresh `NetworkSnapshot` whenever something
/// moves. Uses SystemConfiguration for addresses/routers/DNS (no permission
/// required) and CoreWLAN for SSID (requires Location permission, nil
/// otherwise). Marked @unchecked Sendable because callbacks arrive on
/// background queues, but snapshots are built on `monitorQueue` and every
/// mutation of `snapshot` happens on the main queue.
final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot: NetworkSnapshot = .empty

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "ContextSwitch.NetworkMonitor")
    private var dynamicStore: SCDynamicStore?

    func start() {
        let path = NWPathMonitor()
        path.pathUpdateHandler = { [weak self] _ in
            self?.refresh()
        }
        path.start(queue: monitorQueue)
        pathMonitor = path

        // Also watch SystemConfiguration directly so we catch SSID / router
        // changes that NWPathMonitor sometimes coalesces or misses.
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "ContextSwitch" as CFString, { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.refresh()
        }, &context) else {
            refresh()
            return
        }
        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/DNS",
        ] as CFArray
        let patterns = [
            "State:/Network/Service/.*/IPv4",
            "State:/Network/Interface/.*/AirPort",
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/Link",
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        if let runLoopSource = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        dynamicStore = store

        refresh()
    }

    /// Rebuilds the snapshot off the main thread (SystemConfiguration and
    /// CoreWLAN reads can block), then publishes it on main.
    func refresh() {
        monitorQueue.async { [weak self] in
            let snap = NetworkMonitor.buildSnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                var next = snap
                next.location = self.snapshot.location
                if next != self.snapshot {
                    self.snapshot = next
                }
            }
        }
    }

    /// Called by LocationMonitor when a new location fix comes in; merged
    /// into the snapshot without re-reading network state.
    func updateLocation(_ location: SimpleLocation?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.snapshot
            next.location = location
            if next != self.snapshot {
                self.snapshot = next
            }
        }
    }

    private static func buildSnapshot() -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        guard let store = SCDynamicStoreCreate(nil, "ContextSwitch.read" as CFString, nil, nil) else {
            return snap
        }

        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            let domains = [dns["DomainName"] as? String].compactMap { $0 } + (dns["SearchDomains"] as? [String] ?? [])
            var seen = Set<String>()
            snap.dnsDomains = domains.filter { seen.insert($0.lowercased()).inserted }
        }

        let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primaryService = globalIPv4?["PrimaryService"] as? String

        let wifiClient = CWWiFiClient.shared()
        for service in NetworkInventory.services() {
            guard let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service.id)/IPv4" as CFString) as? [String: Any],
                  let address = (ipv4["Addresses"] as? [String])?.first
            else { continue }
            var connection = NetworkConnection(
                serviceName: service.name,
                interfaceName: service.interfaceName,
                kind: service.kind,
                localIPv4: address,
                routerIPv4: ipv4["Router"] as? String,
                routerMAC: (ipv4["NetworkSignature"] as? String).flatMap(MACAddress.router(fromNetworkSignature:))
            )
            if service.kind == .wifi {
                connection.ssid = wifiClient.interface(withName: service.interfaceName)?.ssid()
            }
            if service.id == primaryService {
                snap.connections.insert(connection, at: 0)
            } else {
                snap.connections.append(connection)
            }
        }
        return snap
    }
}
