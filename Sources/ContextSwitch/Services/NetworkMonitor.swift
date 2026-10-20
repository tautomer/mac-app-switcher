import Foundation
import Network
import SystemConfiguration
import CoreWLAN
import CoreGraphics
import IOKit
import Combine

/// Watches for network changes (interface up/down, Wi-Fi join/leave, IP
/// changes) and USB devices or displays coming and going, and publishes a
/// fresh `NetworkSnapshot` whenever something moves. Uses
/// SystemConfiguration for addresses/routers/DNS (no permission required),
/// CoreWLAN for SSID (requires Location permission, nil otherwise) and
/// IOKit/CoreGraphics for devices. Marked @unchecked Sendable because
/// callbacks arrive on background queues, but snapshots are built on
/// `monitorQueue` and every mutation of `snapshot` happens on the main
/// queue.
final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot: NetworkSnapshot = .empty

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "ContextSwitch.NetworkMonitor")
    private var dynamicStore: SCDynamicStore?
    private var usbNotifications: IONotificationPortRef?
    private var usbIterators: [io_iterator_t] = []
    /// Main queue only. Until then `snapshot` is the `.empty` placeholder.
    private var hasRead = false

    func start() {
        watchDevices()

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

    private func watchDevices() {
        let info = Unmanaged.passUnretained(self).toOpaque()
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, monitorQueue)
            let callback: IOServiceMatchingCallback = { info, iterator in
                NetworkMonitor.drain(iterator)
                guard let info else { return }
                Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().refresh()
            }
            for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, notification, IOServiceMatching(DeviceInventory.usbDeviceClass),
                                                       callback, info, &iterator) == KERN_SUCCESS
                else { continue }
                NetworkMonitor.drain(iterator)
                usbIterators.append(iterator)
            }
            usbNotifications = port
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard !flags.contains(.beginConfigurationFlag), let info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().refresh()
        }, info)
    }

    /// IOKit only notifies again once the iterator has been read to the end.
    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// Rebuilds the snapshot off the main thread (SystemConfiguration and
    /// CoreWLAN reads can block), then publishes it on main.
    func refresh() {
        monitorQueue.async { [weak self] in
            let snap = NetworkMonitor.readNetworkAndUSB()
            DispatchQueue.main.async {
                guard let self else { return }
                var next = snap
                next.displays = DeviceInventory.displays()
                next.location = self.snapshot.location
                // The first reading is published even if it equals the
                // placeholder (offline, nothing plugged in): subscribers skip
                // the placeholder and wait for a real one.
                if next != self.snapshot || !self.hasRead {
                    self.hasRead = true
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

    /// A one-off, synchronous read of the current network and devices (used
    /// directly by the command line; the app goes through `refresh()`). No
    /// location.
    @MainActor
    static func buildSnapshot() -> NetworkSnapshot {
        var snap = readNetworkAndUSB()
        snap.displays = DeviceInventory.displays()
        return snap
    }

    /// Everything but displays (read on main) and location.
    private static func readNetworkAndUSB() -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        snap.usbDevices = DeviceInventory.usbDevices()
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
