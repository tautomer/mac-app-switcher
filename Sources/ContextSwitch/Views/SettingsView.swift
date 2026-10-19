import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var newFolder = ""
    @State private var showingFolderImporter = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch ContextSwitch at login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))
            }

            appFolders

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
        .fileImporter(isPresented: $showingFolderImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach { appState.addAppFolder($0.path) }
            }
        }
        // A grouped Form is a scroll view that will happily fill the whole
        // screen; size the window to the content instead.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 460)
        .keepsAppActiveWhileOpen()
        .onAppear { appState.refreshNetwork() }
    }

    private var appFolders: some View {
        Section {
            ForEach(appState.appFolders, id: \.self) { folder in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: AppFolders.url(for: folder).path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(folder)
                    if !AppFolders.isFolder(folder) {
                        Text("Not found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RemoveButton { appState.removeAppFolder(folder) }
                }
            }
            HStack {
                TextField("Folder", text: $newFolder, prompt: Text("e.g. ~/Applications or /opt/bin"))
                    .labelsHidden()
                    .onSubmit(addTypedFolder)
                Button("Add", action: addTypedFolder)
                    .disabled(!AppFolders.isFolder(newFolder))
                Button("Choose…") { showingFolderImporter = true }
            }
        } header: {
            Text("App Folders")
        } footer: {
            Text("“Add App…” lists the apps in these folders and their subfolders, and the scripts and command-line tools directly inside. /Applications includes Apple's built-in apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addTypedFolder() {
        guard AppFolders.isFolder(newFolder) else { return }
        appState.addAppFolder(newFolder)
        newFolder = ""
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
