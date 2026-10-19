import SwiftUI
import AppKit

struct MenuBarIcon: View {
    @ObservedObject var appState: AppState

    var body: some View {
        // Template image (Assets.xcassets/MenuBarIcon), so the menu bar
        // tints it for light/dark and highlighted states.
        Image("MenuBarIcon")
            .renderingMode(.template)
    }
}

struct MenuBarContentView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let profile = appState.activeProfile {
                appList(for: profile)
            } else {
                Text("No matching profile")
                    .foregroundStyle(.secondary)
                    .padding()
            }
            Divider()
            profilePicker
            Divider()
            footer
        }
        .frame(width: 300)
        .padding(.vertical, 8)
        // Executables don't post launch/quit notifications; re-check on open.
        .onAppear { appState.refreshRunState() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.activeProfile?.name ?? "No Profile")
                    .font(.headline)
                Text(appState.isAutoSwitchEnabled ? "Auto-detected" : "Auto-switch off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(networkSummary, systemImage: networkSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var networkSummary: String {
        guard let primary = appState.snapshot.primary else { return "Offline" }
        switch primary.kind {
        case .wifi: return primary.ssid.map { "Wi-Fi · \($0)" } ?? "Wi-Fi"
        case .ethernet, .other: return primary.serviceName
        }
    }

    private var networkSymbol: String {
        switch appState.snapshot.primary?.kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .other: return "network"
        case nil: return "wifi.slash"
        }
    }

    private func appList(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if profile.appRules.isEmpty {
                Text("No apps configured for this profile")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding()
            } else {
                ForEach(profile.appRules) { rule in
                    AppRow(appState: appState, rule: rule)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The two ways the active profile gets chosen: by hand, or automatically.
    /// Picking one by hand turns auto-switch off.
    private var profilePicker: some View {
        HStack {
            Menu {
                ForEach(appState.profiles) { profile in
                    Button {
                        appState.selectManually(profile)
                    } label: {
                        if profile.id == appState.activeProfile?.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                Label("Switch Profile", systemImage: "arrow.triangle.2.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Toggle("Auto-switch", isOn: Binding(
                get: { appState.isAutoSwitchEnabled },
                set: { appState.setAutoSwitch($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Switch profiles automatically when the network or connected devices change")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button("Edit Profiles…") {
                WindowActivation.bringToFront()
                openWindow(id: "profile-editor")
            }
            Button {
                WindowActivation.bringToFront()
                openWindow(id: "settings")
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .help("Settings")
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }
}

private struct AppRow: View {
    @ObservedObject var appState: AppState
    let rule: AppRule

    var body: some View {
        let isRunning = appState.isRunning(rule)
        HStack(spacing: 8) {
            Image(nsImage: appState.icon(for: rule))
                .resizable()
                .frame(width: 18, height: 18)
            Text(rule.displayName)
                .lineLimit(1)
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .help(isRunning ? "Running" : "Not running")
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.effectiveAction == .launch },
                set: { appState.setOverride($0 ? .launch : .quit, forRule: rule.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 3)
    }
}
