import Foundation
import AppKit
import Combine
import CoreLocation

@MainActor
final class AppState: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published private(set) var activeProfile: Profile?
    /// Off = keep the current profile and ignore network changes. Turned
    /// off by picking a profile by hand; remembered across launches.
    @Published private(set) var isAutoSwitchEnabled: Bool = AppState.defaults.object(forKey: DefaultsKey.autoSwitch) as? Bool ?? true
    @Published private(set) var snapshot: NetworkSnapshot = .empty
    @Published var launchAtLogin: Bool = LoginItemManager.isEnabled
    /// Where "Add App…" looks (see `AppFolders`).
    @Published private(set) var appFolders: [String] = AppState.defaults.stringArray(forKey: DefaultsKey.appFolders) ?? AppFolders.defaults
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    /// Bumped whenever an app or executable starts/stops, so views showing
    /// running state re-render.
    @Published private(set) var runStateRevision = 0

    private let store = ProfileStore()
    private let networkMonitor = NetworkMonitor()
    private let locationMonitor = LocationMonitor()
    private let launcher = AppLauncherService.shared
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false

    /// How long the network has to stay put before we switch profiles.
    /// Joining a network goes through several intermediate states (link up,
    /// no address, DHCP…) and we don't want to launch/quit apps for each.
    private static let settleDelay: DispatchQueue.SchedulerTimeType.Stride = .seconds(3)

    private enum DefaultsKey {
        static let autoSwitch = "autoSwitchEnabled"
        static let lastActiveProfile = "lastActiveProfileID"
        static let appFolders = "appFolders"
    }

    /// A separate domain when CONTEXTSWITCH_PROFILES points at a sandbox
    /// file, so trying things out doesn't touch your real settings either.
    private static let defaults: UserDefaults =
        ProcessInfo.processInfo.environment["CONTEXTSWITCH_PROFILES"].flatMap { _ in
            UserDefaults(suiteName: "com.contextswitch.sandbox")
        } ?? .standard

    init() {
        profiles = store.profiles
        // With auto-switch off, come back on the profile that was active —
        // without launching or quitting anything.
        if !isAutoSwitchEnabled,
           let id = Self.defaults.string(forKey: DefaultsKey.lastActiveProfile).flatMap(UUID.init(uuidString:)) {
            activeProfile = profiles.first { $0.id == id }
        }
        // Synchronous on purpose: the store is only mutated from the main
        // thread, and callers (e.g. the editor selecting a just-added
        // profile, or reevaluate() after a save) need the new list at once.
        store.$profiles
            .sink { [weak self] in self?.profiles = $0 }
            .store(in: &cancellables)

        // The UI shows network changes immediately; profile switching waits
        // for them to settle.
        networkMonitor.$snapshot
            .sink { [weak self] in self?.snapshot = $0 }
            .store(in: &cancellables)
        networkMonitor.$snapshot
            .dropFirst()
            .debounce(for: Self.settleDelay, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reevaluate() }
            .store(in: &cancellables)

        locationMonitor.$authorizationStatus
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self else { return }
                self.locationStatus = status
                // SSIDs only become readable once we're authorized.
                if status == .authorizedAlways { self.networkMonitor.refresh() }
            }
            .store(in: &cancellables)
        locationMonitor.onLocationUpdate = { [weak self] loc in
            self?.networkMonitor.updateLocation(loc)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.runStateRevision += 1 }
        .store(in: &cancellables)
        launcher.onExecutableExit = { [weak self] in self?.runStateRevision += 1 }

        DistributedNotificationCenter.default()
            .publisher(for: RemoteCommand.requestName)
            .compactMap { RemoteCommand.Request(userInfo: $0.userInfo) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)

        start()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        networkMonitor.start()
        syncLocationMonitoring()
    }

    // MARK: - Location

    var isLocationAuthorized: Bool { locationStatus == .authorizedAlways }
    var isLocationDenied: Bool { locationStatus == .denied || locationStatus == .restricted }

    /// True if any profile has a condition that can't match without
    /// Location access (Wi-Fi names, places).
    var needsLocationPermission: Bool {
        profiles.contains { $0.conditions.contains(where: \.condition.requiresLocationPermission) }
    }

    func requestLocationPermission() {
        locationMonitor.requestPermission()
    }

    /// One-shot fix, delivered into `snapshot.location`.
    func requestCurrentLocation() {
        locationMonitor.requestCurrentLocation()
    }

    func refreshNetwork() {
        networkMonitor.refresh()
    }

    private func syncLocationMonitoring() {
        let regions = profiles.flatMap { profile in
            profile.conditions.compactMap { clause -> (name: String, latitude: Double, longitude: Double, radius: Double)? in
                if case .location(let name, let lat, let lon, let radius) = clause.condition {
                    return (name, lat, lon, radius)
                }
                return nil
            }
        }
        locationMonitor.monitor(regions: regions)
        if needsLocationPermission && locationStatus == .notDetermined {
            locationMonitor.requestPermission()
        }
    }

    // MARK: - Profile selection

    func reevaluate() {
        guard isAutoSwitchEnabled else { return }
        // Offline usually means mid-switch (Wi-Fi rejoining, DHCP pending).
        // Keep the current profile rather than bouncing to the fallback and
        // back, which would quit and relaunch apps for nothing.
        if !snapshot.isOnline && activeProfile != nil { return }
        let best = ProfileMatcher.bestMatch(for: snapshot, in: profiles)
        guard best?.id != activeProfile?.id else { return }
        if let best {
            apply(best)
        } else {
            activeProfile = nil
        }
    }

    func selectManually(_ profile: Profile) {
        setAutoSwitch(false)
        apply(profile)
    }

    func setAutoSwitch(_ enabled: Bool) {
        isAutoSwitchEnabled = enabled
        Self.defaults.set(enabled, forKey: DefaultsKey.autoSwitch)
        if enabled { reevaluate() }
    }

    @discardableResult
    private func apply(_ profile: Profile) -> [(AppRule, EnforceOutcome)] {
        activeProfile = profile
        Self.defaults.set(profile.id.uuidString, forKey: DefaultsKey.lastActiveProfile)
        return profile.appRules.map { ($0, launcher.enforce($0.effectiveAction, for: $0)) }
    }

    // MARK: - Command line

    /// `ContextSwitch --switch` / `--profile NAME` while the app is open: the
    /// switch is done here, so the menu and active profile stay in sync, and
    /// the reply tells the command line what happened. Auto-switch is left
    /// as it is (unlike picking a profile from the menu).
    private func handle(_ request: RemoteCommand.Request) {
        guard request.profilesPath == store.fileURL.path else { return }
        typealias CLI = CommandLineInterface
        let reply: RemoteCommand.Reply
        if let name = request.profileName {
            if let profile = profiles.profile(named: name) {
                var output = CLI.report(profile: profile, outcomes: apply(profile), reason: .named, dryRun: false)
                if isAutoSwitchEnabled {
                    output += "\nAuto-switch is on, so ContextSwitch will switch again when the network changes."
                }
                reply = .init(id: request.id, status: CLI.ExitStatus.success, output: output)
            } else {
                reply = .init(id: request.id, status: CLI.ExitStatus.unknownProfile,
                              output: CLI.unknownProfileMessage(name, profiles: profiles))
            }
        } else if let best = ProfileMatcher.bestMatch(for: snapshot, in: profiles) {
            let output = CLI.report(profile: best, outcomes: apply(best),
                                    reason: best.isFallback ? .fallback : .matched, dryRun: false)
            reply = .init(id: request.id, status: CLI.ExitStatus.success, output: output)
        } else {
            reply = .init(id: request.id, status: CLI.ExitStatus.noMatchingProfile,
                          output: CLI.noMatchMessage(snapshot: snapshot, profiles: profiles))
        }
        RemoteCommand.post(RemoteCommand.replyName, userInfo: reply.userInfo)
    }

    // MARK: - Per-app manual override

    func setOverride(_ action: AppAction?, forRule ruleID: AppRule.ID) {
        guard var updated = activeProfile,
              let idx = updated.appRules.firstIndex(where: { $0.id == ruleID }) else { return }
        updated.appRules[idx].manualOverride = action
        activeProfile = updated
        launcher.enforce(updated.appRules[idx].effectiveAction, for: updated.appRules[idx])
    }

    func isRunning(_ rule: AppRule) -> Bool {
        launcher.isRunning(rule)
    }

    func icon(for rule: AppRule) -> NSImage {
        launcher.icon(for: rule)
    }

    /// For executables we can't get launch/quit notifications for.
    func refreshRunState() {
        runStateRevision += 1
    }

    // MARK: - Profile CRUD (delegates to store, re-derives active profile)

    func saveProfile(_ profile: Profile) {
        guard store.profiles.first(where: { $0.id == profile.id }) != profile else { return }
        store.upsert(profile)
        if let active = activeProfile, active.id == profile.id {
            // Keep the session's manual overrides for rules that still exist.
            var updated = profile
            for idx in updated.appRules.indices {
                updated.appRules[idx].manualOverride = active.appRules
                    .first { $0.id == updated.appRules[idx].id }?.manualOverride
            }
            activeProfile = updated
        }
        syncLocationMonitoring()
        reevaluate()
    }

    func deleteProfile(_ profile: Profile) {
        store.delete(profile)
        syncLocationMonitoring()
        if activeProfile?.id == profile.id {
            activeProfile = nil
            reevaluate()
        }
    }

    // MARK: - Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        LoginItemManager.setEnabled(enabled)
    }

    func addAppFolder(_ path: String) {
        let folder = AppFolders.normalize(path)
        guard !appFolders.contains(folder) else { return }
        appFolders.append(folder)
        Self.defaults.set(appFolders, forKey: DefaultsKey.appFolders)
    }

    func removeAppFolder(_ folder: String) {
        appFolders.removeAll { $0 == folder }
        Self.defaults.set(appFolders, forKey: DefaultsKey.appFolders)
    }
}
