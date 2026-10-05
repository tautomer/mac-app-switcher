import SwiftUI
import AppKit

struct ProfileEditorView: View {
    @ObservedObject var appState: AppState
    @State private var selectedProfileID: Profile.ID?

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
            if let profile = selectedProfile {
                // Edits save as you make them, like System Settings.
                ProfileDetailEditor(
                    appState: appState,
                    profile: Binding(
                        get: { appState.profiles.first { $0.id == profile.id } ?? profile },
                        set: { appState.saveProfile($0) }
                    )
                )
                .id(profile.id)
            } else {
                Text("Select or create a profile")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = sortedProfiles.first?.id
            }
        }
        .keepsAppActiveWhileOpen()
        .frame(minWidth: 680, minHeight: 460)
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
    @Binding var profile: Profile

    @State private var showingAppPicker = false
    @State private var showingConditionPicker = false

    private var needsLocationAccess: Bool {
        profile.conditions.contains(where: \.condition.requiresLocationPermission) && !appState.isLocationAuthorized
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $profile.name)
                Stepper("Priority: \(profile.priority)", value: $profile.priority)
            }

            Section {
                ForEach($profile.conditions) { $clause in
                    ConditionRow(
                        clause: $clause,
                        isFirst: clause.id == profile.conditions.first?.id,
                        status: clause.evaluate(appState.snapshot),
                        onRemove: { profile.conditions.removeAll { $0.id == clause.id } }
                    )
                }
                if needsLocationAccess {
                    LocationAccessBanner(appState: appState, message: "Wi-Fi and Place conditions can't be checked until ContextSwitch has Location access.")
                }
                Button {
                    showingConditionPicker = true
                } label: {
                    Label("Add Condition…", systemImage: "plus")
                }
            } header: {
                Text("Conditions")
            } footer: {
                conditionsFooter
            }

            Section("Apps") {
                ForEach($profile.appRules) { $rule in
                    HStack {
                        Image(nsImage: appState.icon(for: rule))
                            .resizable()
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.displayName)
                            if rule.isExecutable, let path = rule.path {
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Picker("", selection: $rule.action) {
                            Text("Launch").tag(AppAction.launch)
                            Text("Quit").tag(AppAction.quit)
                            Text("Ignore").tag(AppAction.ignore)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        RemoveButton { profile.appRules.removeAll { $0.id == rule.id } }
                    }
                }
                Button {
                    showingAppPicker = true
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAppPicker) {
            AppPickerView(existingKeys: Set(profile.appRules.map(\.targetKey))) { rule in
                profile.appRules.append(rule)
            }
        }
        .sheet(isPresented: $showingConditionPicker) {
            ConditionPickerView(appState: appState) { condition in
                profile.conditions.append(ConditionClause(condition))
            }
        }
    }

    @ViewBuilder
    private var conditionsFooter: some View {
        if profile.conditions.isEmpty {
            Text("No conditions — this is the fallback profile, used when nothing else matches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Matches when \(profile.conditionSummary).")
                if profile.conditions.count > 1 {
                    Text("“and” is checked before “or”: A and B or C means (A and B) or C.")
                }
                switch profile.evaluate(appState.snapshot) {
                case true?:
                    Label("Matches the current network", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case false?:
                    Label("Doesn't match the current network", systemImage: "xmark.circle")
                case nil:
                    Label("Can't tell yet — waiting on Location access or a location fix", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}

/// One condition row: `If`/`and`/`or` ▸ `not` ▸ condition ▸ live status.
private struct ConditionRow: View {
    @Binding var clause: ConditionClause
    let isFirst: Bool
    /// The clause's value on the current network; nil = can't tell.
    let status: Bool?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isFirst {
                    Text("If")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Connector", selection: $clause.connector) {
                        Text("and").tag(ConditionClause.Connector.and)
                        Text("or").tag(ConditionClause.Connector.or)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .frame(width: 64, alignment: .leading)

            Toggle("not", isOn: $clause.isNegated)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Negate this condition")

            Label(clause.condition.kindLabel, systemImage: clause.condition.systemImage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(clause.condition.valueLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusIcon
            RemoveButton(action: onRemove)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case true?:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("True on the current network")
        case false?:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .help("False on the current network")
        case nil:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
                .help("Can't tell yet — needs Location access or a location fix")
        }
    }
}

private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}
