import Foundation
import AppKit
import Combine
import CoreLocation

@MainActor
final class AppState: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published private(set) var activeProfile: Profile?
    @Published var isManualOverride: Bool = false
    @Published private(set) var snapshot: NetworkSnapshot = .empty
    @Published var launchAtLogin: Bool = LoginItemManager.isEnabled
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

    init() {
        profiles = store.profiles
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
        profiles.contains { $0.conditions.contains(where: \.requiresLocationPermission) }
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
            profile.conditions.compactMap { condition -> (name: String, latitude: Double, longitude: Double, radius: Double)? in
                if case .location(let name, let lat, let lon, let radius) = condition {
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
        guard !isManualOverride else { return }
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
        isManualOverride = true
        apply(profile)
    }

    func resumeAutoDetection() {
        isManualOverride = false
        reevaluate()
    }

    private func apply(_ profile: Profile) {
        activeProfile = profile
        for rule in profile.appRules {
            enforce(rule.effectiveAction, for: rule)
        }
    }

    private func enforce(_ action: AppAction, for rule: AppRule) {
        switch action {
        case .launch:
            if !launcher.isRunning(rule) { launcher.launch(rule) }
        case .quit:
            if launcher.isRunning(rule) { launcher.quit(rule) }
        case .ignore:
            break
        }
    }

    // MARK: - Per-app manual override

    func setOverride(_ action: AppAction?, forRule ruleID: AppRule.ID) {
        guard var updated = activeProfile,
              let idx = updated.appRules.firstIndex(where: { $0.id == ruleID }) else { return }
        updated.appRules[idx].manualOverride = action
        activeProfile = updated
        enforce(updated.appRules[idx].effectiveAction, for: updated.appRules[idx])
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
}
