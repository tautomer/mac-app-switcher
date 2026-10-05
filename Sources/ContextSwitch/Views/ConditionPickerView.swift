import SwiftUI

private enum ConditionKind: String, CaseIterable, Identifiable {
    case ssid = "Wi-Fi Network"
    case gatewayIP = "Router IP"
    case gatewayMAC = "Router (MAC)"
    case subnet = "Subnet"
    case location = "Place"

    var id: String { rawValue }
}

struct ConditionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let currentSnapshot: NetworkSnapshot
    var onAdd: (NetworkCondition) -> Void

    @State private var kind: ConditionKind = .ssid
    @State private var textValue: String = ""
    @State private var placeName: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var radius: String = "150"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Condition").font(.headline)

            Picker("Type", selection: $kind) {
                ForEach(ConditionKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: kind) { _, _ in prefillCurrentValue() }

            switch kind {
            case .ssid, .gatewayIP, .gatewayMAC, .subnet:
                HStack {
                    TextField(placeholder(for: kind), text: $textValue)
                        .textFieldStyle(.roundedBorder)
                    Button("Use Current") { prefillCurrentValue() }
                }
            case .location:
                TextField("Name (e.g. Home)", text: $placeName).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Latitude", text: $latitude).textFieldStyle(.roundedBorder)
                    TextField("Longitude", text: $longitude).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Radius (meters)")
                    TextField("150", text: $radius).textFieldStyle(.roundedBorder).frame(width: 80)
                }
                Text("Tip: open Maps, drop a pin at this place, and copy its coordinates here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear { prefillCurrentValue() }
    }

    private func placeholder(for kind: ConditionKind) -> String {
        switch kind {
        case .ssid: return "e.g. Home-WiFi"
        case .gatewayIP: return "e.g. 192.168.1.1"
        case .gatewayMAC: return "e.g. a1:b2:c3:d4:e5:f6"
        case .subnet: return "e.g. 192.168.1.0/24"
        case .location: return ""
        }
    }

    private func prefillCurrentValue() {
        switch kind {
        case .ssid: textValue = currentSnapshot.ssid ?? ""
        case .gatewayIP: textValue = currentSnapshot.gatewayIPv4 ?? ""
        case .gatewayMAC: textValue = currentSnapshot.gatewayMAC ?? ""
        case .subnet:
            if let ip = currentSnapshot.localIPv4 {
                let parts = ip.split(separator: ".")
                if parts.count == 4 {
                    textValue = "\(parts[0]).\(parts[1]).\(parts[2]).0/24"
                }
            }
        case .location:
            if let loc = currentSnapshot.location {
                latitude = String(loc.latitude)
                longitude = String(loc.longitude)
            }
        }
    }

    private var isValid: Bool {
        switch kind {
        case .ssid, .gatewayIP, .gatewayMAC, .subnet:
            return !textValue.trimmingCharacters(in: .whitespaces).isEmpty
        case .location:
            return !placeName.isEmpty && Double(latitude) != nil && Double(longitude) != nil && Double(radius) != nil
        }
    }

    private func add() {
        let condition: NetworkCondition
        switch kind {
        case .ssid: condition = .ssid(textValue)
        case .gatewayIP: condition = .gatewayIP(textValue)
        case .gatewayMAC: condition = .gatewayMAC(textValue)
        case .subnet: condition = .subnet(cidr: textValue)
        case .location:
            condition = .location(name: placeName, latitude: Double(latitude) ?? 0, longitude: Double(longitude) ?? 0, radiusMeters: Double(radius) ?? 150)
        }
        onAdd(condition)
        dismiss()
    }
}
