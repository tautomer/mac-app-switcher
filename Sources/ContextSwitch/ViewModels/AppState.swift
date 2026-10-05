import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published private(set) var activeProfile: Profile?
    @Published var isManualOverride: Bool = false
    @Published private(set) var snapshot: NetworkSnapshot = .empty
    @Published var launchAtLogin: Bool = LoginItemManager.isEnabled

    private let store = ProfileStore()
    private let networkMonitor = NetworkMonitor()
    private let locationMonitor = LocationMonitor()
    private let launcher = AppLauncherService.shared
    private var cancellables = Set<AnyCancellable>()

    /// Set while applying a profile so re-entrant snapshot updates (caused
    /// by our own launch/quit calls nudging the network stack) don't
    /// trigger a redundant re-apply.
    private var isApplying = false

    init() {
        profiles = store.profiles
        // Synchronous on purpose: the store is only mutated from the main
        // thread, and callers (e.g. the editor selecting a just-added
        // profile, or reevaluate() after a save) need the new list at once.
        store.$profiles
            .sink { [weak self] in self?.profiles = $0 }
            .store(in: &cancellables)

        networkMonitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.snapshot = snap
                self?.reevaluate()
            }
            .store(in: &cancellables)

        locationMonitor.onLocationUpdate = { [weak self] loc in
            self?.networkMonitor.updateLocation(loc)
        }

        start()
    }

    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        networkMonitor.start()
        if profiles.contains(where: { $0.conditions.contains(where: { $0.id.hasPrefix("location:") }) }) {
            let regions = locationRegions()
            locationMonitor.startMonitoring(regions: regions)
        }
    }

    private func locationRegions() -> [(name: String, latitude: Double, longitude: Double, radius: Double)] {
        profiles.flatMap { profile in
            profile.conditions.compactMap { condition -> (String, Double, Double, Double)? in
                if case .location(let name, let lat, let lon, let radius) = condition {
                    return (name, lat, lon, radius)
                }
                return nil
            }
        }
    }

    // MARK: - Profile selection

    func reevaluate() {
        guard !isManualOverride else { return }
        guard let best = ProfileMatcher.bestMatch(for: snapshot, in: profiles) else { return }
        if best.id != activeProfile?.id {
            apply(best)
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
        isApplying = true
        activeProfile = profile
        for rule in profile.appRules {
            switch rule.effectiveAction {
            case .launch:
                if !launcher.isRunning(rule.bundleIdentifier) {
                    launcher.launch(rule.bundleIdentifier)
                }
            case .quit:
                if launcher.isRunning(rule.bundleIdentifier) {
                    launcher.quit(rule.bundleIdentifier)
                }
            case .ignore:
                break
            }
        }
        isApplying = false
    }

    /// Re-applies the currently active profile (e.g. after editing its
    /// rules, or after a manual per-app override).
    func reapplyActiveProfile() {
        guard let active = activeProfile else { return }
        apply(active)
    }

    // MARK: - Per-app manual override

    func setOverride(_ action: AppAction?, forAppIn profile: Profile, bundleIdentifier: String) {
        guard var updated = activeProfile, updated.id == profile.id,
              let idx = updated.appRules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        updated.appRules[idx].manualOverride = action
        activeProfile = updated
        switch (action ?? updated.appRules[idx].action) {
        case .launch:
            if !launcher.isRunning(bundleIdentifier) { launcher.launch(bundleIdentifier) }
        case .quit:
            if launcher.isRunning(bundleIdentifier) { launcher.quit(bundleIdentifier) }
        case .ignore:
            break
        }
    }

    func runState(for bundleIdentifier: String) -> RunState {
        launcher.runState(for: bundleIdentifier)
    }

    // MARK: - Profile CRUD (delegates to store, re-derives active profile)

    func saveProfile(_ profile: Profile) {
        store.upsert(profile)
        if activeProfile?.id == profile.id {
            activeProfile = profile
        }
        reevaluate()
    }

    func deleteProfile(_ profile: Profile) {
        store.delete(profile)
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
