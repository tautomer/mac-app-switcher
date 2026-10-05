import SwiftUI
import AppKit

struct MenuBarIcon: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
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
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.activeProfile?.name ?? "No Profile")
                    .font(.headline)
                Text(appState.isManualOverride ? "Manually selected" : "Auto-detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appState.isManualOverride {
                Button("Resume Auto") {
                    appState.resumeAutoDetection()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
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
                    AppRow(appState: appState, profile: profile, rule: rule)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var profilePicker: some View {
        Menu {
            ForEach(appState.profiles) { profile in
                Button(profile.name) {
                    appState.selectManually(profile)
                }
            }
        } label: {
            Label("Switch Profile", systemImage: "arrow.triangle.2.circlepath")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button("Edit Profiles…") {
                // As an LSUIElement app we're never activated by clicks in
                // the popover, so the window would open behind the frontmost
                // app. Become a regular app while the editor is open;
                // ProfileEditorView reverts this when it closes.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                openWindow(id: "profile-editor")
            }
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
    let profile: Profile
    let rule: AppRule

    var isRunning: Bool {
        appState.runState(for: rule.bundleIdentifier) == .running
    }

    var body: some View {
        HStack {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(rule.displayName)
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.effectiveAction == .launch },
                set: { newValue in
                    appState.setOverride(newValue ? .launch : .quit, forAppIn: profile, bundleIdentifier: rule.bundleIdentifier)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 3)
    }
}
