import SwiftUI
import AppKit

struct ProfileEditorView: View {
    @ObservedObject var appState: AppState
    @State private var selectedProfileID: Profile.ID?
    @State private var draft: Profile?

    private var sortedProfiles: [Profile] {
        appState.profiles.sorted(by: { $0.priority > $1.priority })
    }

    private var selectedProfile: Profile? {
        appState.profiles.first { $0.id == selectedProfileID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProfileID) {
                ForEach(sortedProfiles) { profile in
                    Text(profile.name).tag(profile.id as Profile.ID?)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarActions
            }
            // The sidebar is the only way to pick a profile, so collapsing
            // it is never useful.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if let draft {
                ProfileDetailEditor(
                    appState: appState,
                    draft: Binding(
                        get: { draft },
                        set: { self.draft = $0 }
                    ),
                    onSave: { appState.saveProfile($0) },
                    onDelete: deleteProfile
                )
            } else {
                Text("Select or create a profile")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedProfileID) { _, newID in
            draft = appState.profiles.first { $0.id == newID }
        }
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = appState.profiles.first?.id
            }
        }
        .onDisappear {
            // Back to menu-bar-only once the editor window closes.
            NSApp.setActivationPolicy(.accessory)
        }
        .frame(minWidth: 640, minHeight: 440)
    }

    private var sidebarActions: some View {
        HStack(spacing: 2) {
            SidebarActionButton(title: "Add Profile", systemImage: "plus", action: addProfile)
            SidebarActionButton(title: "Delete Profile", systemImage: "minus") {
                if let selectedProfile { deleteProfile(selectedProfile) }
            }
            .disabled(selectedProfile == nil)
            SidebarActionButton(title: "Duplicate Profile", systemImage: "doc.on.doc", action: duplicateSelectedProfile)
                .disabled(selectedProfile == nil)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func addProfile() {
        let new = Profile(name: "New Profile", conditions: [], appRules: [], priority: (appState.profiles.map(\.priority).max() ?? 0) + 1)
        appState.saveProfile(new)
        selectedProfileID = new.id
    }

    private func duplicateSelectedProfile() {
        guard let original = selectedProfile else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) Copy"
        copy.appRules = original.appRules.map { rule in
            var rule = rule
            rule.id = UUID()
            rule.manualOverride = nil
            return rule
        }
        appState.saveProfile(copy)
        selectedProfileID = copy.id
    }

    /// Deletes the profile and moves the selection to its neighbour in the
    /// sidebar, so the detail pane doesn't go blank.
    private func deleteProfile(_ profile: Profile) {
        let sorted = sortedProfiles
        let neighbour = sorted.firstIndex(where: { $0.id == profile.id }).flatMap { idx in
            sorted.indices.contains(idx + 1) ? sorted[idx + 1] : (idx > 0 ? sorted[idx - 1] : nil)
        }
        appState.deleteProfile(profile)
        selectedProfileID = neighbour?.id
    }
}

/// Icon-only button for the sidebar's bottom bar. The whole 24×22 frame is
/// clickable — a borderless button otherwise only hit-tests the glyph, which
/// for "minus" is a 1pt-tall sliver.
private struct SidebarActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ProfileDetailEditor: View {
    @ObservedObject var appState: AppState
    @Binding var draft: Profile
    var onSave: (Profile) -> Void
    var onDelete: (Profile) -> Void

    @State private var showingAppPicker = false
    @State private var showingConditionPicker = false

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $draft.name)
                Stepper("Priority: \(draft.priority)", value: $draft.priority)
                Text(draft.conditions.isEmpty
                     ? "No conditions — this is the fallback profile, used when nothing else matches."
                     : "Matches when ALL conditions below are true.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Conditions") {
                ForEach(draft.conditions) { condition in
                    HStack {
                        Text(condition.kindLabel).foregroundStyle(.secondary)
                        Text(condition.valueLabel)
                        Spacer()
                        Button(role: .destructive) {
                            draft.conditions.removeAll { $0.id == condition.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    showingConditionPicker = true
                } label: {
                    Label("Add Condition…", systemImage: "plus")
                }
            }

            Section("Apps") {
                ForEach(draft.appRules.indices, id: \.self) { idx in
                    HStack {
                        Text(draft.appRules[idx].displayName)
                        Spacer()
                        Picker("", selection: $draft.appRules[idx].action) {
                            Text("Launch").tag(AppAction.launch)
                            Text("Quit").tag(AppAction.quit)
                            Text("Ignore").tag(AppAction.ignore)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button(role: .destructive) {
                            draft.appRules.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    showingAppPicker = true
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
            }

            Section {
                HStack {
                    Button("Save", action: { onSave(draft) })
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Delete Profile", role: .destructive) { onDelete(draft) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAppPicker) {
            AppPickerView { bundleID, name in
                draft.appRules.append(AppRule(bundleIdentifier: bundleID, displayName: name, action: .launch))
            }
        }
        .sheet(isPresented: $showingConditionPicker) {
            ConditionPickerView(currentSnapshot: appState.snapshot) { condition in
                draft.conditions.append(condition)
            }
        }
    }
}
