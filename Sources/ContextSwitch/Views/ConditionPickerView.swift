import SwiftUI
import AppKit

private enum ConditionKind: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi Network"
    case wiredNetwork = "Ethernet Network"
    case ethernetAdapter = "Ethernet Adapter"
    case dnsDomain = "DNS Domain"
    case place = "Place"
    case usbDevice = "USB Device"
    case display = "Display"
    case routerIP = "Router IP"
    case routerMAC = "Router MAC"
    case subnet = "Subnet"

    var id: String { rawValue }

    static let common: [ConditionKind] = [.wifi, .wiredNetwork, .ethernetAdapter, .dnsDomain, .place]
    static let devices: [ConditionKind] = [.usbDevice, .display]
    static let advanced: [ConditionKind] = [.routerIP, .routerMAC, .subnet]
}

struct ConditionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: AppState
    var onAdd: (NetworkCondition) -> Void

    /// Picker tag for the "Other…" item.
    private static let other = "\u{0}other"

    @State private var kind: ConditionKind = .wifi
    @State private var savedNetworks: [String] = []
    @State private var adapters: [NetworkService] = []

    @State private var ssidChoice = ""
    @State private var customSSID = ""
    @State private var wiredRouterMAC = ""
    @State private var wiredName = ""
    @State private var adapterChoice = ""
    @State private var domainChoice = ""
    @State private var customDomain = ""
    @State private var textValue = ""
    @State private var placeName = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var radius = "150"
    @State private var awaitingLocation = false
    @State private var usbChoice = ""
    @State private var displayChoice = ""
    /// Record the serial number, so only this unit matches.
    @State private var onlyThisUnit = true

    private var snapshot: NetworkSnapshot { appState.snapshot }
    private var currentSSID: String? { snapshot.wifi?.ssid }
    private var wiredConnections: [NetworkConnection] { snapshot.ethernet.filter { $0.routerMAC != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Condition").font(.headline)

            Form {
                Picker("Type", selection: $kind) {
                    ForEach(ConditionKind.common) { Text($0.rawValue).tag($0) }
                    Section("Devices") {
                        ForEach(ConditionKind.devices) { Text($0.rawValue).tag($0) }
                    }
                    Section("Advanced") {
                        ForEach(ConditionKind.advanced) { Text($0.rawValue).tag($0) }
                    }
                }
                fields
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(makeCondition() == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            savedNetworks = NetworkInventory.savedWiFiNetworks()
            adapters = NetworkInventory.services().filter { $0.kind == .ethernet }
            appState.refreshNetwork()
            prefill()
        }
        .onChange(of: kind) { _, _ in prefill() }
        .onChange(of: currentSSID) { _, ssid in
            // Shows up once Location access is granted.
            if kind == .wifi, ssidChoice.isEmpty, let ssid { ssidChoice = ssid }
        }
        // Devices come and go while the sheet is open.
        .onChange(of: snapshot.usbDevices) { _, devices in
            if !devices.contains(where: { $0.id == usbChoice }) { usbChoice = devices.first?.id ?? "" }
        }
        .onChange(of: snapshot.displays) { _, displays in
            if !displays.contains(where: { $0.id == displayChoice }) { displayChoice = displays.first?.id ?? "" }
        }
        .onChange(of: snapshot.location) { _, location in
            guard awaitingLocation, let location else { return }
            awaitingLocation = false
            latitude = String(format: "%.6f", location.latitude)
            longitude = String(format: "%.6f", location.longitude)
        }
    }

    // MARK: - Per-kind fields

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .wifi:
            Picker("Network", selection: $ssidChoice) {
                placeholder("Select a network", while: ssidChoice)
                if let currentSSID {
                    Text("\(currentSSID) — connected").tag(currentSSID)
                }
                Section("Saved Networks") {
                    ForEach(savedNetworks.filter { $0 != currentSSID }, id: \.self) { Text($0).tag($0) }
                }
                Divider()
                Text("Other…").tag(Self.other)
            }
            if ssidChoice == Self.other {
                TextField("Name", text: $customSSID, prompt: Text("Network name"))
            }
            if !appState.isLocationAuthorized {
                LocationAccessBanner(
                    appState: appState,
                    message: "macOS only reveals the Wi-Fi network you're on — and Wi-Fi conditions can only match — once ContextSwitch has Location access."
                )
            }
            hint("The list shows networks this Mac has joined before.")

        case .wiredNetwork:
            if wiredConnections.isEmpty {
                hint(snapshot.ethernet.isEmpty
                     ? "Connect this Mac to the network with an Ethernet cable, then add it here."
                     : "Couldn't read the router's address yet. Try again in a moment.")
            } else {
                Picker("Connection", selection: $wiredRouterMAC) {
                    placeholder("Select a connection", while: wiredRouterMAC)
                    ForEach(wiredConnections, id: \.self) { connection in
                        Text("\(connection.serviceName) — router \(connection.routerIPv4 ?? "?")")
                            .tag(connection.routerMAC ?? "")
                    }
                }
                TextField("Name", text: $wiredName, prompt: Text("e.g. Office"))
                hint("macOS names Ethernet adapters, not the networks behind them, so ContextSwitch recognises this network by its router's hardware address (\(wiredRouterMAC)) — the way Windows does. It matches from any Ethernet port on the same network.")
            }

        case .ethernetAdapter:
            if adapters.isEmpty {
                hint("No Ethernet adapters are set up on this Mac.")
            } else {
                Picker("Adapter", selection: $adapterChoice) {
                    placeholder("Select an adapter", while: adapterChoice)
                    ForEach(sortedAdapters) { adapter in
                        Text(isConnected(adapter) ? "\(adapter.name) — connected" : adapter.name)
                            .tag(adapter.name)
                    }
                }
                hint("Matches whenever this adapter is connected, whatever network it's on — handy for a dock or dongle that stays at one desk. Names come from System Settings ▸ Network.")
            }

        case .dnsDomain:
            if !snapshot.dnsDomains.isEmpty {
                Picker("Domain", selection: $domainChoice) {
                    placeholder("Select a domain", while: domainChoice)
                    ForEach(snapshot.dnsDomains, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Other…").tag(Self.other)
                }
            }
            if snapshot.dnsDomains.isEmpty || domainChoice == Self.other {
                TextField("Domain", text: $customDomain, prompt: Text("e.g. corp.example.com"))
            }
            hint("Matches when the network assigns this DNS search domain — common on office networks. A VPN can assign one too.")

        case .place:
            TextField("Name", text: $placeName, prompt: Text("Optional, e.g. Home"))
            TextField("Latitude", text: $latitude)
            TextField("Longitude", text: $longitude)
            TextField("Radius (m)", text: $radius)
            if appState.isLocationDenied {
                LocationAccessBanner(appState: appState, message: "Places need Location access.")
            } else {
                Button(awaitingLocation ? "Locating…" : "Use Current Location") {
                    awaitingLocation = true
                    appState.requestCurrentLocation()
                }
                .disabled(awaitingLocation)
            }

        case .usbDevice:
            if snapshot.usbDevices.isEmpty {
                hint("No USB devices are connected. Plug the device in, then add it here.")
            } else {
                Picker("Device", selection: $usbChoice) {
                    placeholder("Select a device", while: usbChoice)
                    ForEach(snapshot.usbDevices) { device in
                        Text(label(for: device)).tag(device.id)
                    }
                }
                if let serial = selectedUSBDevice?.serialNumber {
                    Toggle("Only this unit (serial number \(serial))", isOn: $onlyThisUnit)
                }
                hint("Matches while the device is plugged in — directly, or through a hub or dock. A dock's own entry, or its audio or Ethernet, identifies the desk it's on.")
            }

        case .display:
            if snapshot.displays.isEmpty {
                hint("No external displays are connected. Connect the display, then add it here.")
            } else {
                Picker("Display", selection: $displayChoice) {
                    placeholder("Select a display", while: displayChoice)
                    ForEach(snapshot.displays) { display in
                        Text(label(for: display)).tag(display.id)
                    }
                }
                if let serial = selectedDisplay?.serialNumber {
                    Toggle("Only this unit (serial number \(serial))", isOn: $onlyThisUnit)
                }
                hint("Matches while this display is connected.")
            }

        case .routerIP, .routerMAC, .subnet:
            HStack {
                TextField(kind.rawValue, text: $textValue, prompt: Text(placeholder))
                    .labelsHidden()
                Button("Use Current") { prefillAdvanced() }
                    .disabled(snapshot.primary == nil)
            }
            hint(advancedHint)
        }
    }

    /// A "" item while nothing is selected yet. Defaults are filled in by
    /// prefill() after the first render, and SwiftUI faults if a Picker's
    /// selection has no matching tag even for that one frame.
    @ViewBuilder
    private func placeholder(_ text: String, while selection: String) -> some View {
        if selection.isEmpty {
            Text(text).tag("")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sortedAdapters: [NetworkService] {
        adapters.filter(isConnected) + adapters.filter { !isConnected($0) }
    }

    private func isConnected(_ adapter: NetworkService) -> Bool {
        snapshot.ethernet.contains { $0.serviceName == adapter.name }
    }

    private var selectedUSBDevice: USBDevice? {
        snapshot.usbDevices.first { $0.id == usbChoice }
    }

    private var selectedDisplay: ConnectedDisplay? {
        snapshot.displays.first { $0.id == displayChoice }
    }

    /// e.g. "USB Receiver — Logitech"; the serial number is added when
    /// several devices share a name.
    private func label(for device: USBDevice) -> String {
        var label = device.name
        if let maker = device.manufacturer, !device.name.localizedCaseInsensitiveContains(maker) {
            label += " — \(maker)"
        }
        if let serial = device.serialNumber, snapshot.usbDevices.filter({ $0.name == device.name }).count > 1 {
            label += " (\(serial))"
        }
        return label
    }

    private func label(for display: ConnectedDisplay) -> String {
        guard let serial = display.serialNumber, snapshot.displays.filter({ $0.name == display.name }).count > 1
        else { return display.name }
        return "\(display.name) (\(serial))"
    }

    private var placeholder: String {
        switch kind {
        case .routerIP: return "e.g. 192.168.1.1"
        case .routerMAC: return "e.g. a1:b2:c3:d4:e5:f6"
        default: return "e.g. 192.168.1.0/24"
        }
    }

    private var advancedHint: String {
        switch kind {
        case .routerIP: return "Matches any connection whose router has this address. Many routers share addresses like 192.168.1.1, so Wi-Fi or Ethernet Network is usually more precise."
        case .routerMAC: return "Matches any connection — Wi-Fi or Ethernet — through this router."
        default: return "Matches when this Mac's address is in this range."
        }
    }

    // MARK: - Prefill & build

    private func prefill() {
        switch kind {
        case .wifi:
            if ssidChoice.isEmpty, let currentSSID { ssidChoice = currentSSID }
        case .wiredNetwork:
            if wiredRouterMAC.isEmpty { wiredRouterMAC = wiredConnections.first?.routerMAC ?? "" }
        case .ethernetAdapter:
            if adapterChoice.isEmpty { adapterChoice = sortedAdapters.first?.name ?? "" }
        case .dnsDomain:
            if domainChoice.isEmpty { domainChoice = snapshot.dnsDomains.first ?? Self.other }
        case .place:
            break
        case .usbDevice:
            if usbChoice.isEmpty { usbChoice = snapshot.usbDevices.first?.id ?? "" }
        case .display:
            if displayChoice.isEmpty { displayChoice = snapshot.displays.first?.id ?? "" }
        case .routerIP, .routerMAC, .subnet:
            textValue = ""
            prefillAdvanced()
        }
    }

    private func prefillAdvanced() {
        guard let primary = snapshot.primary else { return }
        switch kind {
        case .routerIP:
            textValue = primary.routerIPv4 ?? ""
        case .routerMAC:
            textValue = primary.routerMAC ?? ""
        case .subnet:
            if let ip = primary.localIPv4 {
                let parts = ip.split(separator: ".")
                if parts.count == 4 { textValue = "\(parts[0]).\(parts[1]).\(parts[2]).0/24" }
            }
        default:
            break
        }
    }

    private func makeCondition() -> NetworkCondition? {
        func trimmed(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        switch kind {
        case .wifi:
            let ssid = ssidChoice == Self.other ? trimmed(customSSID) : trimmed(ssidChoice)
            return ssid.map { .ssid($0) }
        case .wiredNetwork:
            guard let mac = trimmed(wiredRouterMAC), let name = trimmed(wiredName) else { return nil }
            return .wiredNetwork(name: name, routerMAC: mac)
        case .ethernetAdapter:
            return trimmed(adapterChoice).map { .ethernetAdapter($0) }
        case .dnsDomain:
            let domain = snapshot.dnsDomains.isEmpty || domainChoice == Self.other ? trimmed(customDomain) : trimmed(domainChoice)
            return domain.map { .dnsDomain($0) }
        case .place:
            guard let lat = Double(latitude), let lon = Double(longitude),
                  let r = Double(radius), (-90...90).contains(lat), (-180...180).contains(lon), r > 0
            else { return nil }
            return .location(name: trimmed(placeName) ?? "", latitude: lat, longitude: lon, radiusMeters: r)
        case .usbDevice:
            guard let device = selectedUSBDevice else { return nil }
            return .usbDevice(name: device.name, vendorID: device.vendorID, productID: device.productID,
                              serialNumber: onlyThisUnit ? device.serialNumber : nil)
        case .display:
            guard let display = selectedDisplay else { return nil }
            return .display(name: display.name, vendorID: display.vendorID, modelID: display.modelID,
                            serialNumber: onlyThisUnit ? display.serialNumber : nil)
        case .routerIP:
            guard let ip = trimmed(textValue), IPv4Subnet.toUInt32(ip) != nil else { return nil }
            return .gatewayIP(ip)
        case .routerMAC:
            guard let mac = trimmed(textValue), MACAddress.normalize(mac).count == 17 else { return nil }
            return .gatewayMAC(MACAddress.normalize(mac))
        case .subnet:
            guard let cidr = trimmed(textValue), IPv4Subnet(cidr: cidr) != nil else { return nil }
            return .subnet(cidr: cidr)
        }
    }

    private func add() {
        guard let condition = makeCondition() else { return }
        if condition.requiresLocationPermission && !appState.isLocationAuthorized && !appState.isLocationDenied {
            appState.requestLocationPermission()
        }
        onAdd(condition)
        dismiss()
    }
}

/// Explains why Location access is needed, with a button to grant it (or to
/// open System Settings once it's been denied).
struct LocationAccessBanner: View {
    @ObservedObject var appState: AppState
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "location.slash")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if appState.isLocationDenied {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Button("Allow…") { appState.requestLocationPermission() }
            }
        }
    }
}
