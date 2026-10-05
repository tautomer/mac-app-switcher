import SwiftUI
import AppKit

struct AppPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var apps: [(bundleIdentifier: String, name: String, url: URL)] = []

    var onPick: (_ bundleIdentifier: String, _ name: String) -> Void

    private var filtered: [(bundleIdentifier: String, name: String, url: URL)] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding()

            List(filtered, id: \.bundleIdentifier) { app in
                Button {
                    onPick(app.bundleIdentifier, app.name)
                    dismiss()
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
        }
        .frame(width: 360, height: 420)
        .onAppear {
            apps = AppLauncherService.shared.installedApplications()
        }
    }
}
