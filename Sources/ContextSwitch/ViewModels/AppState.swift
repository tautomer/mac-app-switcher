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
    /// Settled snapshots, for timed conditions ("for 5 min").
    @Published private(set) var history = SnapshotHistory()
    /// A profile auto-switch will move to once its timer (or the wait while
    /// offline) runs out, unless things change first.
    @Published private(set) var pendingSwitch: PendingMatch?
    @Published var launchAtLogin: Bool = LoginItemManager.isEnabled
    /// Where "Add App…" looks (see `AppFolders`).
    @Published private(set) var appFolders: [String] = AppState.defaults.stringArray(forKey: DefaultsKey.appFolders) ?? AppFolders.defaults
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    /// Bumped whenever an app or executable starts/stops, so views showing
    /// running state re-render.
    @Published private(set) var runStateRevision = 0
    /// Shown in the menu while profiles.json, or part of it, couldn't be read.
    @Published private(set) var profilesProblem: String?
    /// Settings ▸ General. Problems go to the activity log either way.
    @Published private(set) var notifiesOnSwitch: Bool = AppState.defaults.object(forKey: DefaultsKey.notifyOnSwitch) as? Bool ?? true
    @Published private(set) var notifiesOnProblems: Bool = AppState.defaults.object(forKey: DefaultsKey.notifyOnProblems) as? Bool ?? true
    /// Whether macOS lets us post notifications; nil until the user's been asked.
    @Published private(set) var notificationsAllowed: Bool?

    private let store = ProfileStore()
    private let networkMonitor = NetworkMonitor()
    private let locationMonitor = LocationMonitor()
    private let launcher = AppLauncherService.shared
    private let log = ActivityLog.shared
    private let notifier = Notifier()
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    /// Set from a failed save until one works again (see `save`).
    private var isSaveFailing = false
    /// Re-checks when a timer or the wait while offline runs out: that
    /// doesn't change the snapshot, so nothing else would notice.
    private var pendingCheck: Task<Void, Never>?
    /// So relaunching stops when something keeps crashing.
    private var crashes = CrashHistory()
    /// Relaunches waiting out `relaunchDelay`, by `AppRule.targetKey`. A
    /// newer exit of the same app cancels its one.
    private var pendingRelaunches: [String: Task<Void, Never>] = [:]
    /// When the Mac last began to log out, restart or shut down. Apps that
    /// end then aren't relaunched, even if they crash on the way out.
    private var poweringOffAt: Date?

    /// How long the network has to stay put before we switch profiles.
    /// Joining a network goes through several intermediate states (link up,
    /// no address, DHCP…) and we don't want to launch/quit apps for each.
    private static let settleDelay: DispatchQueue.SchedulerTimeType.Stride = .seconds(3)
    /// Between a crash and the relaunch, so a crash report can be written
    /// and the old process is really gone.
    private static let relaunchDelay: Duration = .seconds(2)

    private enum DefaultsKey {
        static let autoSwitch = "autoSwitchEnabled"
        static let lastActiveProfile = "lastActiveProfileID"
        static let appFolders = "appFolders"
        static let notifyOnSwitch = "notifyOnSwitch"
        static let notifyOnProblems = "notifyOnProblems"
    }

    private typealias CLI = CommandLineInterface

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
        // for them to settle, and so do timers — a blip doesn't restart one.
        networkMonitor.$snapshot
            .sink { [weak self] in self?.snapshot = $0 }
            .store(in: &cancellables)
        networkMonitor.$snapshot
            .dropFirst()  // the placeholder; the first reading always follows
            .debounce(for: Self.settleDelay, scheduler: DispatchQueue.main)
            .sink { [weak self] settled in
                self?.log.debug("Settled: \(CLI.networkSummary(settled))")
                self?.history.record(settled, at: Date())
                self?.reevaluate()
            }
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
        // An app opened by hand, while the profile keeps it running. Not the
        // launch notification: macOS doesn't post it for menu bar apps
        // (LSUIElement), such as OmniLED.
        NSWorkspace.shared.publisher(for: \.runningApplications)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.watchExits(in: self?.activeProfile) }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.willPowerOffNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.poweringOffAt = Date() }
            .store(in: &cancellables)
        // With the new value: this runs before activeProfile changes.
        $activeProfile
            .sink { [weak self] in self?.watchExits(in: $0) }
            .store(in: &cancellables)
        launcher.onExit = { [weak self] in self?.handleExit($0) }
        notifier.onClick = { [weak self] in self?.openActivityLog() }

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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log.record("ContextSwitch \(version) started, with \(profiles.count) profile\(profiles.count == 1 ? "" : "s")")
        if notifiesOnSwitch || notifiesOnProblems { requestNotificationPermission() }
        if let problem = store.problem {
            profilesProblem = problem.summary
            reportProblem(problem.summary, problem.explanation, details: problem.details)
        }
        // Loading can save already (IDs it had to make up), copying the file first.
        if let copy = store.copiedAside {
            log.record("Saved a copy of the original \(store.fileURL.lastPathComponent) as \(copy.lastPathComponent) before saving over it.")
        }
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

    /// One-shot fix, delivered to `completion` and into `snapshot.location`.
    func requestCurrentLocation(_ completion: @escaping (Result<SimpleLocation, Error>) -> Void) {
        locationMonitor.requestCurrentLocation(completion)
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
        let decision = ProfileMatcher.autoSwitch(for: snapshot, in: profiles, current: activeProfile,
                                                 history: history, at: Date())
        setPendingSwitch(decision.pending, checkAt: decision.checkAt)
        guard decision.profile?.id != activeProfile?.id else { return }
        if let profile = decision.profile {
            apply(profile, trigger: .auto)
        } else {
            log.record("No profile matches now, and there's no fallback profile, so apps are left as they are.\n"
                       + "  \(CLI.networkSummary(snapshot))")
            activeProfile = nil
        }
    }

    private func setPendingSwitch(_ pending: PendingMatch?, checkAt: Date? = nil) {
        if let pending, pending.profile.id != pendingSwitch?.profile.id {
            log.debug("Will switch to “\(pending.profile.name)” at \(pending.at) unless things change first")
        }
        pendingSwitch = pending
        pendingCheck?.cancel()
        guard let checkAt else { return }
        pendingCheck = Task { [weak self] in
            // The continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(max(0, checkAt.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }

    func selectManually(_ profile: Profile) {
        setAutoSwitch(false)
        apply(profile, trigger: .menu)
    }

    func setAutoSwitch(_ enabled: Bool) {
        if enabled != isAutoSwitchEnabled { log.record("Auto-switch turned \(enabled ? "on" : "off")") }
        isAutoSwitchEnabled = enabled
        Self.defaults.set(enabled, forKey: DefaultsKey.autoSwitch)
        if enabled { reevaluate() } else { setPendingSwitch(nil) }
    }

    /// What made a profile active, for the activity log.
    private enum Trigger {
        case auto, menu, commandLine
    }

    @discardableResult
    private func apply(_ profile: Profile, trigger: Trigger) -> [(AppRule, EnforceOutcome)] {
        let previous = activeProfile
        activeProfile = profile
        Self.defaults.set(profile.id.uuidString, forKey: DefaultsKey.lastActiveProfile)
        let outcomes = profile.appRules.map { ($0, enforce($0)) }
        recordSwitch(from: previous, to: profile, trigger: trigger, outcomes: outcomes)
        return outcomes
    }

    /// Has the launcher bring `rule` to its effective action, reporting a
    /// launch that fails.
    @discardableResult
    private func enforce(_ rule: AppRule) -> EnforceOutcome {
        launcher.enforce(rule.effectiveAction, for: rule) { [weak self] failure in
            if let failure { self?.reportProblem("Couldn't launch \(rule.displayName)", failure.reason) }
        }
    }

    /// Logs the switch and why, and if it happened on its own, says so in
    /// a notification.
    private func recordSwitch(from previous: Profile?, to profile: Profile, trigger: Trigger,
                              outcomes: [(AppRule, EnforceOutcome)]) {
        let why: String
        switch trigger {
        case .menu: why = "picked from the menu"
        case .commandLine: why = "asked for on the command line"
        case .auto where profile.isFallback: why = "the fallback, as no other profile matches"
        case .auto: why = "its conditions match: \(profile.conditionSummary)"
        }
        let headline: String
        if let previous, previous.id == profile.id {
            headline = "Applied “\(profile.name)” again"
        } else if let previous {
            headline = "Switched from “\(previous.name)” to “\(profile.name)”"
        } else {
            headline = "Switched to “\(profile.name)”"
        }
        let lines = ["\(headline) — \(why).", "  \(CLI.networkSummary(snapshot))"] + CLI.outcomeLines(outcomes, dryRun: false)
        log.record(lines.joined(separator: "\n"))

        guard trigger == .auto, notifiesOnSwitch else { return }
        // One id, so a new switch replaces the last one's notification.
        notifier.post(id: "profile-switch", title: "Switched to “\(profile.name)”", body: Self.changes(outcomes))
    }

    /// e.g. "Launching Slack and Outlook, quitting Steam."
    private static func changes(_ outcomes: [(AppRule, EnforceOutcome)]) -> String {
        let launching = outcomes.filter { $0.1 == .launched }.map { $0.0.displayName }
        let quitting = outcomes.filter { $0.1 == .quit }.map { $0.0.displayName }
        var parts: [String] = []
        if !launching.isEmpty { parts.append("launching \(ListFormatter.localizedString(byJoining: launching))") }
        if !quitting.isEmpty { parts.append("quitting \(ListFormatter.localizedString(byJoining: quitting))") }
        guard !parts.isEmpty else { return "No apps to launch or quit." }
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    /// Logs a problem and, unless that's turned off, posts a notification.
    /// `details` is what the log gets, if there's more to say.
    private func reportProblem(_ title: String, _ message: String, details: String? = nil) {
        log.record(details ?? "\(title): \(message)", level: .problem)
        guard notifiesOnProblems else { return }
        notifier.post(title: title, body: message)
    }

    // MARK: - Crashes

    /// Watches what `profile` keeps running, so `handleExit` hears how it
    /// ends. (What ContextSwitch launches is watched already.)
    private func watchExits(in profile: Profile?) {
        for rule in profile?.appRules ?? [] where rule.effectiveAction == .launch {
            launcher.watchForExit(rule)
        }
    }

    /// The active profile's rule for `targetKey`, if it keeps it running.
    private func keptRunningRule(for targetKey: String) -> AppRule? {
        activeProfile?.appRules.first { $0.targetKey == targetKey && $0.effectiveAction == .launch }
    }

    /// Long after it began, the logout must have been cancelled: macOS
    /// doesn't say when one is.
    private var isPoweringOff: Bool {
        poweringOffAt.map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    /// Something ContextSwitch launched or watches has ended: reports a
    /// crash, and relaunches it if its rule says to and the active profile
    /// still keeps it running.
    private func handleExit(_ exit: TargetExit) {
        runStateRevision += 1
        log.debug("\(exit.name) ended. \(exit.status?.description ?? "macOS didn't say how.")"
                  + (exit.wasAskedToStop ? " We'd asked it to." : ""))
        // Superseded: e.g. reopened by hand and quit again, or past the cap.
        pendingRelaunches.removeValue(forKey: exit.targetKey)?.cancel()
        guard !exit.wasAskedToStop else { return }
        let rule = keptRunningRule(for: exit.targetKey).flatMap { $0.relaunchesOnCrash == true ? $0 : nil }
        // So "why didn't it come back?" has an answer.
        guard let status = exit.status else {
            if rule != nil { log.record("\(exit.name) quit, but macOS didn't say how, so it was left closed.") }
            return
        }
        guard status.isCrash else {
            if rule != nil {
                log.record("\(exit.name) quit, and was left closed: only crashes are relaunched. \(status.description)")
            }
            return
        }
        guard let rule else {
            reportProblem("\(exit.name) stopped", status.description)
            return
        }
        // Everything quits then, some apps by crashing on the way out.
        guard !isPoweringOff else {
            reportProblem("\(exit.name) stopped",
                          "\(status.description) The Mac began to log out or shut down in the last 2 minutes, so it was left closed.")
            return
        }
        guard crashes.record(rule.targetKey) else {
            reportProblem("\(exit.name) keeps crashing",
                          "\(status.description) That's \(CrashHistory.limit) crashes in \(Int(CrashHistory.window / 60)) minutes, "
                          + "so ContextSwitch has stopped relaunching it for now.")
            return
        }
        reportProblem("\(exit.name) stopped", "\(status.description) Relaunching it.")
        pendingRelaunches[rule.targetKey] = Task { [weak self] in
            try? await Task.sleep(for: Self.relaunchDelay)
            guard !Task.isCancelled else { return }
            self?.pendingRelaunches[rule.targetKey] = nil
            self?.relaunch(rule.targetKey)
        }
    }

    /// Launches a crashed app again, unless things changed while we waited.
    private func relaunch(_ targetKey: String) {
        guard !isPoweringOff, let rule = keptRunningRule(for: targetKey), rule.relaunchesOnCrash == true,
              enforce(rule) == .launched
        else { return }
        log.record("Relaunched \(rule.displayName) after it crashed.")
    }

    // MARK: - Command line

    /// `ContextSwitch --switch` / `--profile NAME` while the app is open: the
    /// switch is done here, so the menu and active profile stay in sync, and
    /// the reply tells the command line what happened. Auto-switch is left
    /// as it is (unlike picking a profile from the menu).
    private func handle(_ request: RemoteCommand.Request) {
        guard request.profilesPath == store.fileURL.path else { return }
        let reply: RemoteCommand.Reply
        if let name = request.profileName {
            if let profile = profiles.profile(named: name) {
                var output = CLI.report(profile: profile, outcomes: apply(profile, trigger: .commandLine), reason: .named, dryRun: false)
                if isAutoSwitchEnabled {
                    output += "\nAuto-switch is on, so ContextSwitch will switch again when the network changes."
                }
                reply = .init(id: request.id, status: CLI.ExitStatus.success, output: output)
            } else {
                reply = .init(id: request.id, status: CLI.ExitStatus.unknownProfile,
                              output: CLI.unknownProfileMessage(name, profiles: profiles))
            }
        } else if let best = ProfileMatcher.bestMatch(for: snapshot, in: profiles, history: history) {
            let output = CLI.report(profile: best, outcomes: apply(best, trigger: .commandLine),
                                    reason: best.isFallback ? .fallback : .matched, dryRun: false)
            reply = .init(id: request.id, status: CLI.ExitStatus.success, output: output)
        } else {
            reply = .init(id: request.id, status: CLI.ExitStatus.noMatchingProfile,
                          output: CLI.noMatchMessage(snapshot: snapshot, profiles: profiles, history: history))
        }
        RemoteCommand.post(RemoteCommand.replyName, userInfo: reply.userInfo)
    }

    // MARK: - Per-app manual override

    func setOverride(_ action: AppAction?, forRule ruleID: AppRule.ID) {
        guard var updated = activeProfile,
              let idx = updated.appRules.firstIndex(where: { $0.id == ruleID }) else { return }
        updated.appRules[idx].manualOverride = action
        activeProfile = updated
        let rule = updated.appRules[idx]
        let outcome = enforce(rule)
        log.record("Turned \(rule.displayName) \(rule.effectiveAction == .launch ? "on" : "off") from the menu, "
                   + "until “\(updated.name)” is applied again.\n"
                   + CLI.outcomeLines([(rule, outcome)], dryRun: false).joined(separator: "\n"))
    }

    func isRunning(_ rule: AppRule) -> Bool {
        launcher.isRunning(rule)
    }

    func icon(for rule: AppRule) -> NSImage {
        launcher.icon(for: rule)
    }

    /// For executables we can't get launch/quit notifications for. Also
    /// starts watching one started outside ContextSwitch, e.g. from
    /// Terminal, so a crash of it is relaunched too.
    func refreshRunState() {
        runStateRevision += 1
        watchExits(in: activeProfile)
    }

    // MARK: - Profile CRUD (delegates to store, re-derives active profile)

    func saveProfile(_ profile: Profile) {
        guard store.profiles.first(where: { $0.id == profile.id }) != profile else { return }
        save { try store.upsert(profile) }
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
        save { try store.delete(profile) }
        syncLocationMonitoring()
        if activeProfile?.id == profile.id {
            activeProfile = nil
            reevaluate()
        }
    }

    /// Runs a store change that saves, reporting a save that fails — and
    /// the copy kept of a profiles.json that couldn't all be read, if one was.
    private func save(_ change: () throws -> Void) {
        let copiedBefore = store.copiedAside
        var failure: Error?
        do {
            try change()
        } catch {
            failure = error
        }
        // Made even if the write after it failed.
        if let copy = store.copiedAside, copy != copiedBefore {
            log.record("Saved a copy of the original \(store.fileURL.lastPathComponent) as \(copy.lastPathComponent) before saving over it.")
        }
        if let failure {
            // The editor saves as you type: say so once, not per keystroke.
            if !isSaveFailing { reportProblem("Couldn't save your profiles", failure.localizedDescription) }
            isSaveFailing = true
            return
        }
        if isSaveFailing {
            log.record("Saved your profiles again.")
            isSaveFailing = false
        }
        if store.problem == nil { profilesProblem = nil }
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

    // MARK: - Notifications and the activity log

    func setNotifiesOnSwitch(_ enabled: Bool) {
        notifiesOnSwitch = enabled
        Self.defaults.set(enabled, forKey: DefaultsKey.notifyOnSwitch)
        if enabled { requestNotificationPermission() }
    }

    func setNotifiesOnProblems(_ enabled: Bool) {
        notifiesOnProblems = enabled
        Self.defaults.set(enabled, forKey: DefaultsKey.notifyOnProblems)
        if enabled { requestNotificationPermission() }
    }

    /// Asks the first time only; after that it just reads the answer.
    private func requestNotificationPermission() {
        notifier.requestPermission { [weak self] in self?.notificationsAllowed = $0 }
    }

    /// For Settings, which says so if notifications are turned off in
    /// System Settings.
    func refreshNotificationPermission() {
        notifier.checkPermission { [weak self] in self?.notificationsAllowed = $0 }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.contextswitch.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// In Console, the default app for .log files.
    func openActivityLog() {
        log.flush()
        NSWorkspace.shared.open(log.fileURL)
    }
}
