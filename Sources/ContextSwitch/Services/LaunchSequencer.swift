import Foundation

/// Launches the apps of a profile in order: one that has to start after
/// another (`AppRule.launchesAfter`) is held back until that one is running,
/// and then for its `launchDelay`. Everything else starts at once.
@MainActor
final class LaunchSequencer {
    /// Called once for each outcome that `completesLater`, when its launch has
    /// gone through (nil) or why it didn't. Not for a wait that's cancelled,
    /// as when another profile takes over.
    typealias Finished = @MainActor @Sendable (AppRule, LaunchFailure?) -> Void

    /// How long a rule waits for the app it's after to be running.
    static let defaultDependencyTimeout: Duration = .seconds(60)

    private let launcher: AppLauncherService
    let dependencyTimeout: Duration
    private let pollInterval: Duration
    /// What says an app is running: `AppLauncherService`'s, but for tests.
    private let isRunning: (AppRule) -> Bool
    /// The rules held back, by `AppRule.id`.
    private var waiting: [AppRule.ID: Task<Void, Never>] = [:]
    /// Why launches of this batch failed, so those after them needn't wait.
    private var failures: [AppRule.ID: String] = [:]
    /// When this batch launched each app, as a program started by us is
    /// running at once, though it needs time (`AppRule.launchDelay`) to be ready.
    private var launchedAt: [AppRule.ID: ContinuousClock.Instant] = [:]

    init(launcher: AppLauncherService = .shared, dependencyTimeout: Duration = LaunchSequencer.defaultDependencyTimeout,
         pollInterval: Duration = .milliseconds(500), isRunning: ((AppRule) -> Bool)? = nil) {
        self.launcher = launcher
        self.isRunning = isRunning ?? { launcher.isRunning($0) }
        self.dependencyTimeout = dependencyTimeout
        self.pollInterval = pollInterval
    }

    var hasWaiting: Bool { !waiting.isEmpty }

    /// Drops what's still held back, e.g. when another profile takes over.
    func cancelAll() {
        waiting.values.forEach { $0.cancel() }
        waiting = [:]
        failures = [:]
        launchedAt = [:]
    }

    /// Brings every rule of a profile to its action, as a new batch: what was
    /// held back from the last one is dropped. `dryRun` changes nothing.
    func enforce(_ rules: [AppRule], dryRun: Bool = false, onFinished: Finished? = nil) -> [(AppRule, EnforceOutcome)] {
        if !dryRun { cancelAll() }
        return rules.map { ($0, enforceOne($0, in: rules, dryRun: dryRun, onFinished: onFinished)) }
    }

    /// Brings one rule of `rules` to its action again (from the menu, or to
    /// relaunch it). What it was waiting for, if it was, is forgotten, and
    /// what it launches after, and so on, is launched too if it isn't running
    /// or on its way: it would otherwise wait for nothing.
    func enforce(_ rule: AppRule, in rules: [AppRule], onFinished: Finished? = nil) -> EnforceOutcome {
        waiting.removeValue(forKey: rule.id)?.cancel()
        // An earlier failure says nothing of this try.
        failures[rule.id] = nil
        if rule.effectiveAction == .launch, !isRunning(rule),
           let dependency = LaunchOrder.dependency(of: rule, in: rules),
           dependency.effectiveAction == .launch, !isRunning(dependency), waiting[dependency.id] == nil {
            _ = enforce(dependency, in: rules, onFinished: onFinished)
        }
        return enforceOne(rule, in: rules, dryRun: false, onFinished: onFinished)
    }

    private func enforceOne(_ rule: AppRule, in rules: [AppRule], dryRun: Bool, onFinished: Finished?) -> EnforceOutcome {
        guard rule.effectiveAction == .launch, !isRunning(rule),
              let dependency = LaunchOrder.dependency(of: rule, in: rules),
              !isReady(dependency, for: rule)
        else {
            return start(rule, dryRun: dryRun, onFinished)
        }
        // It can only come up if the profile has it launched.
        guard isRunning(dependency) || dependency.effectiveAction == .launch else {
            if !dryRun {
                let reason = "\(dependency.displayName) isn't running, and this profile doesn't launch it."
                Task { @MainActor [weak self] in self?.finished(rule, failure: LaunchFailure(reason: reason), onFinished) }
            }
            return .blocked(by: dependency.displayName)
        }
        if !dryRun { wait(to: rule, after: dependency, onFinished) }
        return .waiting(for: dependency.displayName)
    }

    /// Whether `rule` can launch: `dependency` is running, and if we
    /// launched it, for as long as `rule` waits after that.
    private func isReady(_ dependency: AppRule, for rule: AppRule) -> Bool {
        guard isRunning(dependency) else { return false }
        return remainingDelay(of: rule, after: dependency) <= .zero
    }

    private func remainingDelay(of rule: AppRule, after dependency: AppRule) -> Duration {
        let delay = Duration.seconds(max(0, rule.launchDelay ?? 0))
        guard let launched = launchedAt[dependency.id] else { return .zero }
        return delay - (ContinuousClock.now - launched)
    }

    private func start(_ rule: AppRule, dryRun: Bool, _ onFinished: Finished?) -> EnforceOutcome {
        let outcome = launcher.enforce(rule.effectiveAction, for: rule, dryRun: dryRun) { [weak self] failure in
            self?.finished(rule, failure: failure, onFinished)
        }
        if outcome == .launched, !dryRun { launchedAt[rule.id] = .now }
        return outcome
    }

    private func finished(_ rule: AppRule, failure: LaunchFailure?, _ onFinished: Finished?) {
        if let failure { failures[rule.id] = failure.reason }
        onFinished?(rule, failure)
    }

    private func wait(to rule: AppRule, after dependency: AppRule, _ onFinished: Finished?) {
        waiting[rule.id] = Task { [weak self] in
            guard let self else { return }
            var deadline = ContinuousClock.now + dependencyTimeout
            while !isRunning(dependency) {
                guard !Task.isCancelled else { return }
                if failures[dependency.id] != nil {
                    return giveUp(rule, "\(dependency.displayName) couldn't be launched.", onFinished)
                }
                // Not due yet to be launched itself, as it waits for another
                // (or its delay): the time starts when it's launched.
                if waiting[dependency.id] != nil { deadline = ContinuousClock.now + dependencyTimeout }
                if ContinuousClock.now >= deadline {
                    return giveUp(rule, "\(dependency.displayName) still wasn't running after "
                                  + "\(dependencyTimeout.components.seconds) seconds.", onFinished)
                }
                try? await Task.sleep(for: pollInterval)
            }
            // Counted from when we launched it; if it was started by hand, from now.
            let pause: Duration
            if launchedAt[dependency.id] != nil {
                pause = remainingDelay(of: rule, after: dependency)
            } else {
                pause = .seconds(max(0, rule.launchDelay ?? 0))
            }
            if pause > .zero { try? await Task.sleep(for: pause) }
            guard !Task.isCancelled else { return }
            waiting[rule.id] = nil
            let outcome = start(rule, dryRun: false, onFinished)
            // Started by hand in the meantime.
            if outcome != .launched { onFinished?(rule, nil) }
        }
    }

    private func giveUp(_ rule: AppRule, _ reason: String, _ onFinished: Finished?) {
        waiting[rule.id] = nil
        finished(rule, failure: LaunchFailure(reason: reason), onFinished)
    }
}
