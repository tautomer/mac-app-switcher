import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var apps: [(bundleIdentifier: String, name: String, url: URL)] = []
    @State private var showingFileImporter = false
    @State private var importError: String?

    /// `AppRule.targetKey`s already in the profile, shown as added.
    let existingKeys: Set<String>
    var onPick: (AppRule) -> Void

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
                let added = existingKeys.contains(app.bundleIdentifier)
                Button {
                    pick(app.url)
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        if added {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(added)
            }

            Divider()
            HStack {
                Button("Choose…") { showingFileImporter = true }
                    .help("Pick any app or executable (script, command-line tool)")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 380, height: 460)
        .onAppear {
            apps = AppLauncherService.shared.installedApplications()
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.applicationBundle, .unixExecutable, .script]
        ) { result in
            if case .success(let url) = result { pick(url) }
        }
        .alert("Can't add this file", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func pick(_ url: URL) {
        guard let rule = AppLauncherService.shared.rule(forFileAt: url) else {
            importError = "“\(url.lastPathComponent)” isn't executable. Make it executable (chmod +x) and try again."
            return
        }
        guard !existingKeys.contains(rule.targetKey) else {
            importError = "“\(rule.displayName)” is already in this profile."
            return
        }
        onPick(rule)
        dismiss()
    }
}
