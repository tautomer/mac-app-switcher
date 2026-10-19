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

    /// Which "and" group the condition sheet adds to; past the last group
    /// means a new "or" group.
    private struct ConditionTarget: Identifiable {
        let groupIndex: Int
        var id: Int { groupIndex }
    }

    @State private var showingAppPicker = false
    @State private var conditionTarget: ConditionTarget?

    private var needsLocationAccess: Bool {
        profile.conditions.contains(where: \.condition.requiresLocationPermission) && !appState.isLocationAuthorized
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $profile.name)
                Stepper("Priority: \(profile.priority)", value: $profile.priority)
            }

            conditionSections

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
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAppPicker) {
            AppPickerView(folders: appState.appFolders, existingKeys: Set(profile.appRules.map(\.targetKey))) { rule in
                profile.appRules.append(rule)
            }
        }
        .sheet(item: $conditionTarget) { target in
            ConditionPickerView(appState: appState) { condition in
                profile.addCondition(condition, toGroup: target.groupIndex)
            }
        }
    }

    // MARK: - Conditions

    /// One card per "or" group; the conditions inside a card must all hold.
    /// Showing the grouping makes "and binds before or" self-evident.
    @ViewBuilder
    private var conditionSections: some View {
        let groups = profile.conditionGroups
        if groups.isEmpty {
            Section {
                addConditionButton(toGroup: 0)
            } header: {
                Text("Conditions")
            } footer: {
                Text("No conditions — this is the fallback profile, used when nothing else matches.")
            }
        } else {
            ForEach(Array(groups.enumerated()), id: \.element.first?.id) { index, group in
                Section {
                    ForEach(group) { clause in
                        ConditionRow(
                            clause: clause,
                            isNegated: negationBinding(for: clause.id),
                            status: clause.evaluate(appState.snapshot),
                            onRemove: { profile.removeCondition(id: clause.id) }
                        )
                    }
                    addConditionButton(toGroup: index)
                } header: {
                    groupHeader(index: index, count: group.count)
                } footer: {
                    if index == groups.count - 1 {
                        conditionsFooter(newGroupIndex: groups.count)
                    }
                }
            }
        }
    }

    private func groupHeader(index: Int, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(index == 0 ? "Match When" : "Or When")
            if count > 1 {
                Text("all of these are true")
                    .font(.callout)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addConditionButton(toGroup index: Int) -> some View {
        Button {
            conditionTarget = ConditionTarget(groupIndex: index)
        } label: {
            Label("Add Condition…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
    }

    private func conditionsFooter(newGroupIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                conditionTarget = ConditionTarget(groupIndex: newGroupIndex)
            } label: {
                Label("Add “Or” Group…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("Also match this profile in another situation")

            if needsLocationAccess {
                LocationAccessBanner(appState: appState, message: "Wi-Fi and Place conditions can't be checked until ContextSwitch has Location access.")
            }

            Group {
                switch profile.evaluate(appState.snapshot) {
                case true?:
                    Label("Matches right now", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case false?:
                    Label("Doesn't match right now", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                case nil:
                    Label("Can't tell yet — waiting on Location access or a location fix", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .help("Matches when \(profile.conditionSummary)")
        }
    }

    private func negationBinding(for id: ConditionClause.ID) -> Binding<Bool> {
        Binding(
            get: { profile.conditions.first { $0.id == id }?.isNegated ?? false },
            set: { newValue in
                if let index = profile.conditions.firstIndex(where: { $0.id == id }) {
                    profile.conditions[index].isNegated = newValue
                }
            }
        )
    }
}

/// `[icon] Kind   is ⌄   value   status  ⊖` — fixed-width leading columns
/// so rows line up into a table.
private struct ConditionRow: View {
    let clause: ConditionClause
    @Binding var isNegated: Bool
    /// The clause's value right now; nil = can't tell.
    let status: Bool?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: clause.condition.systemImage)
                    .frame(width: 18)
                Text(clause.condition.kindLabel)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .leading)

            Menu {
                Picker("Operator", selection: $isNegated) {
                    Text("is").tag(false)
                    Text("is not").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    Text(isNegated ? "is not" : "is")
                        .fontWeight(isNegated ? .semibold : .regular)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(isNegated ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 50, alignment: .leading)
            .help("Match when this is, or isn't, the case")

            Text(clause.condition.valueLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
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
                .help("True right now")
        case false?:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .help("False right now")
        case nil:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
                .help("Can't tell yet — needs Location access or a location fix")
        }
    }
}

struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}
