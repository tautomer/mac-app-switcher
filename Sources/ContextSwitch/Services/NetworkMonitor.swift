import Foundation
import Network
import SystemConfiguration
import CoreWLAN
import Combine

/// Watches for network changes (interface up/down, Wi-Fi join/leave, IP
/// changes) and publishes a fresh `NetworkSnapshot` whenever something
/// moves. Uses SystemConfiguration for IP/gateway info (no permission
/// required) and CoreWLAN for SSID (requires Location permission, handled
/// gracefully if absent). Marked @unchecked Sendable because its callbacks
/// arrive on background queues (NWPathMonitor, SCDynamicStore) but every
/// mutation of `snapshot` is funneled through DispatchQueue.main.async,
/// so access is effectively serialized on the main queue.
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

    func refresh() {
        let snap = NetworkMonitor.buildSnapshot(existingLocation: snapshot.location)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if snap != self.snapshot {
                self.snapshot = snap
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

    private static func buildSnapshot(existingLocation: SimpleLocation?) -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        snap.location = existingLocation

        guard let store = SCDynamicStoreCreate(nil, "ContextSwitch.read" as CFString, nil, nil) else {
            return snap
        }

        guard let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primaryInterface = globalIPv4["PrimaryInterface"] as? String else {
            return snap
        }
        snap.interfaceName = primaryInterface
        snap.gatewayIPv4 = globalIPv4["Router"] as? String

        if let ifaceIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(primaryInterface)/IPv4" as CFString) as? [String: Any],
           let addresses = ifaceIPv4["Addresses"] as? [String], let first = addresses.first {
            snap.localIPv4 = first
        }

        // Wi-Fi vs wired, and SSID via CoreWLAN (needs Location permission).
        let wifiInterfaceNames = Set((CWWiFiClient.shared().interfaces() ?? []).compactMap { $0.interfaceName })
        snap.isWiFi = wifiInterfaceNames.contains(primaryInterface)
        snap.isWired = !snap.isWiFi

        if snap.isWiFi, let cwInterface = CWWiFiClient.shared().interface(withName: primaryInterface) {
            snap.ssid = cwInterface.ssid()
        }

        if let gateway = snap.gatewayIPv4 {
            snap.gatewayMAC = NetworkMonitor.lookupMAC(forIP: gateway)
        }

        return snap
    }

    /// Shells out to `arp -n <ip>` to resolve the router's MAC address.
    /// Best-effort: the ARP cache may be empty right after a network
    /// change, in which case this returns nil and we just rely on IP/SSID.
    private static func lookupMAC(forIP ip: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", ip]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        // Typical line: "? (192.168.1.1) at a1:b2:c3:d4:e5:f6 on en0 ifscope [ethernet]"
        guard let atRange = output.range(of: " at ") else { return nil }
        let rest = output[atRange.upperBound...]
        guard let spaceRange = rest.range(of: " ") else { return nil }
        let mac = String(rest[rest.startIndex..<spaceRange.lowerBound])
        return mac == "(incomplete)" ? nil : mac
    }
}
