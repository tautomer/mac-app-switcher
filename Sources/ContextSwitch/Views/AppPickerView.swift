import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var items: [InstalledItem] = []
    @State private var showingFileImporter = false
    @State private var importError: String?

    /// Where to look (see `AppFolders`).
    let folders: [String]
    /// `AppRule.targetKey`s already in the profile, shown as added.
    let existingKeys: Set<String>
    var onPick: (AppRule) -> Void

    private var filtered: [InstalledItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding()

            List {
                let apps = filtered.filter { !$0.isExecutable }
                let tools = filtered.filter(\.isExecutable)
                if tools.isEmpty {
                    rows(apps)
                } else {
                    if !apps.isEmpty {
                        Section("Apps") { rows(apps) }
                    }
                    Section("Scripts & Tools") { rows(tools) }
                }
            }

            Divider()
            HStack {
                Button("Choose…") { showingFileImporter = true }
                    .help("Pick any app or executable (script, command-line tool)")
                Button("Folders…") { openWindow(id: "settings") }
                    .help("Change the folders listed here: \(folders.joined(separator: ", "))")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 380, height: 460)
        .task(id: folders) {
            items = AppLauncherService.shared.installedItems(inFolders: folders)
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

    private func rows(_ items: [InstalledItem]) -> some View {
        ForEach(items) { item in
            let added = existingKeys.contains(item.targetKey)
            Button {
                pick(item.url)
            } label: {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        if item.isExecutable {
                            Text(item.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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
