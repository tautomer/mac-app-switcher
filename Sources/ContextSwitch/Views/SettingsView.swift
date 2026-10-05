import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch ContextSwitch at login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))
            }

            Section {
                LabeledContent("Status", value: locationStatusText)
                if !appState.isLocationAuthorized {
                    LocationAccessBanner(appState: appState, message: "Needed to read Wi-Fi network names and to detect Places.")
                }
            } header: {
                Text("Location Access")
            } footer: {
                Text("Places use region monitoring (geofencing), not continuous tracking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Current Network") {
                if appState.snapshot.connections.isEmpty {
                    Text("Offline").foregroundStyle(.secondary)
                }
                ForEach(appState.snapshot.connections, id: \.self) { connection in
                    ConnectionDetails(connection: connection, isPrimary: connection == appState.snapshot.primary)
                }
                if !appState.snapshot.dnsDomains.isEmpty {
                    LabeledContent("DNS Domains", value: appState.snapshot.dnsDomains.joined(separator: ", "))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420)
        .keepsAppActiveWhileOpen()
        .onAppear { appState.refreshNetwork() }
    }

    private var locationStatusText: String {
        if appState.isLocationAuthorized { return "Allowed" }
        if appState.isLocationDenied { return "Denied" }
        return "Not requested"
    }
}

private struct ConnectionDetails: View {
    let connection: NetworkConnection
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(connection.serviceName, systemImage: connection.kind == .wifi ? "wifi" : "cable.connector.horizontal")
                    .font(.headline)
                if isPrimary {
                    Text("Primary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                if connection.kind == .wifi {
                    LabeledContent("Wi-Fi Network", value: connection.ssid ?? "Hidden — needs Location access")
                }
                LabeledContent("Address", value: connection.localIPv4 ?? "—")
                LabeledContent("Router", value: [connection.routerIPv4, connection.routerMAC].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "—")
                LabeledContent("Interface", value: connection.interfaceName)
            }
            .font(.callout)
        }
        .textSelection(.enabled)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
