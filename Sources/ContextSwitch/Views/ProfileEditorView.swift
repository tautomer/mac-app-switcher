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
                            // e.g. "/usr/local/bin/sync-notes --quiet"
                            let detail = [rule.isExecutable ? rule.path : nil, rule.arguments.map(ShellWords.join)]
                                .compactMap { $0 }.filter { !$0.isEmpty }
                            if !detail.isEmpty {
                                Text(detail.joined(separator: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        ArgumentsButton(rule: $rule)
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
                            duration: durationBinding(for: clause.id),
                            snapshot: appState.snapshot,
                            history: appState.history,
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
                if profile.conditions.contains(where: { $0.duration != nil }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in matchStatus(at: context.date) }
                } else {
                    matchStatus(at: Date())
                }
            }
            .font(.caption)
            .help("Matches when \(profile.conditionSummary)")
        }
    }

    @ViewBuilder
    private func matchStatus(at now: Date) -> some View {
        let snapshot = appState.snapshot, history = appState.history
        if let from = profile.matchesFrom(snapshot, history: history, at: now), from > now {
            Label("Matches in \(countdownLabel(from.timeIntervalSince(now))) if nothing changes", systemImage: "hourglass")
                .foregroundStyle(.tint)
        } else {
            switch profile.evaluate(snapshot, history: history, at: now) {
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

    private func durationBinding(for id: ConditionClause.ID) -> Binding<TimeInterval?> {
        Binding(
            get: { profile.conditions.first { $0.id == id }?.duration },
            set: { newValue in
                if let index = profile.conditions.firstIndex(where: { $0.id == id }) {
                    profile.conditions[index].duration = newValue
                }
            }
        )
    }
}

/// `[icon] Kind   is ⌄   value   for 5 min ⌄  status  ⊖` — fixed-width
/// leading columns so rows line up into a table.
private struct ConditionRow: View {
    let clause: ConditionClause
    @Binding var isNegated: Bool
    @Binding var duration: TimeInterval?
    let snapshot: NetworkSnapshot
    let history: SnapshotHistory
    let onRemove: () -> Void

    private static let presetMinutes: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60]

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
            durationMenu
            if duration == nil {
                statusIcon(at: Date())
            } else {
                // Counts down.
                TimelineView(.periodic(from: .now, by: 1)) { context in statusIcon(at: context.date) }
            }
            RemoveButton(action: onRemove)
        }
    }

    private var durationMenu: some View {
        Menu {
            Picker("Duration", selection: $duration) {
                Text("Right away").tag(TimeInterval?.none)
                Section("Only once it's held for") {
                    ForEach(Self.presetMinutes, id: \.self) { minutes in
                        Text(ConditionClause.label(forDuration: minutes * 60)).tag(TimeInterval?(minutes * 60))
                    }
                    // A duration set in profiles.json by hand.
                    if let duration, !Self.presetMinutes.contains(duration / 60) {
                        Text(ConditionClause.label(forDuration: duration)).tag(TimeInterval?(duration))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if let duration {
                HStack(spacing: 3) {
                    Text("for \(ConditionClause.label(forDuration: duration))")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(duration.map { "Counts once this has held for \(ConditionClause.label(forDuration: $0))" }
              ?? "Add a timer: count this only once it has held for a while — e.g. a dock unplugged for 5 minutes, not just for a quick chat")
    }

    @ViewBuilder
    private func statusIcon(at now: Date) -> some View {
        if let from = clause.holdsFrom(snapshot, history: history, at: now), from > now {
            Image(systemName: "hourglass")
                .foregroundStyle(.tint)
                .help("Counts in \(countdownLabel(from.timeIntervalSince(now))) if nothing changes")
        } else {
            switch clause.evaluate(snapshot, history: history, at: now) {
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
}

/// e.g. "4:59", or "1:04:59" for an hour or more.
func countdownLabel(_ interval: TimeInterval) -> String {
    let duration = Duration.seconds(max(0, interval.rounded(.up)))
    return duration.formatted(.time(pattern: interval >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

/// Opens a popover to paste what an app or executable is launched with.
private struct ArgumentsButton: View {
    @Binding var rule: AppRule
    @State private var isEditing = false

    var body: some View {
        let arguments = rule.arguments ?? []
        let isSet = !arguments.isEmpty || rule.runsDirectly == true
        Button {
            isEditing = true
        } label: {
            Image(systemName: "terminal")
                .foregroundStyle(isSet ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .help(isSet ? "Launches \(rule.runsDirectly == true ? "directly " : "")with: \(ShellWords.join(arguments))"
                    : "Launch options")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            ArgumentsEditor(rule: rule) { rule = $0 }
        }
    }
}

private struct ArgumentsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let rule: AppRule
    let onSave: (AppRule) -> Void
    @State private var text: String
    @State private var runsDirectly: Bool

    init(rule: AppRule, onSave: @escaping (AppRule) -> Void) {
        self.rule = rule
        self.onSave = onSave
        _text = State(initialValue: ShellWords.join(rule.arguments ?? []))
        _runsDirectly = State(initialValue: rule.runsDirectly == true)
    }

    /// nil while a quote is open.
    private var arguments: [String]? {
        ShellWords.arguments(fromCommandLine: text, program: AppLauncherService.shared.executableURL(for: rule))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launch Options for \(rule.displayName)")
                .font(.headline)
            Text("Arguments")
                .font(.subheadline)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .frame(width: 400, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            Group {
                if let arguments {
                    if arguments.isEmpty {
                        Text("Paste them as you'd type them in Terminal — quotes and \\ line breaks are fine, and so is the whole command.")
                    } else {
                        Text("Runs: \(rule.displayName) \(ShellWords.join(arguments))")
                            .textSelection(.enabled)
                    }
                } else {
                    Text("A quote isn't closed.")
                        .foregroundStyle(.red)
                }
                Text("Used when ContextSwitch launches it — not if it's already running.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !rule.isExecutable {
                Divider()
                Toggle("Start the program directly, as Terminal does", isOn: $runsDirectly)
                Text("For server or daemon modes, like OpenRGB --server, that never finish launching as an app — the Dock icon keeps bouncing. ContextSwitch runs the program inside the app instead, and quits it the same way, so it can't ask to save changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let arguments else { return }
                    var updated = rule
                    updated.arguments = arguments.isEmpty ? nil : arguments
                    updated.runsDirectly = runsDirectly ? true : nil
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(arguments == nil)
            }
        }
        .padding()
        .frame(width: 432)
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
