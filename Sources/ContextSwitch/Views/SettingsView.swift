import SwiftUI
import CoreLocation

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

            Section("Current Network") {
                LabeledContent("Interface", value: appState.snapshot.interfaceName ?? "—")
                LabeledContent("Local IP", value: appState.snapshot.localIPv4 ?? "—")
                LabeledContent("Router IP", value: appState.snapshot.gatewayIPv4 ?? "—")
                LabeledContent("Router MAC", value: appState.snapshot.gatewayMAC ?? "—")
                if appState.snapshot.isWiFi {
                    LabeledContent("Wi-Fi SSID", value: appState.snapshot.ssid ?? "(permission needed)")
                }
            }

            Section("Location") {
                Text("Location is only used if a profile has a Place condition. It relies on region monitoring (geofencing), not continuous GPS tracking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 360)
    }
}
