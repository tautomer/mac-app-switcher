import AppKit

/// Runs a `CommandLineCommand` and returns the process exit status. If the
/// menu bar app is running, switching is handed to it; otherwise it's done
/// here, in this short-lived process.
@MainActor
enum CommandLineInterface {
    enum ExitStatus {
        static let success: Int32 = 0
        static let noMatchingProfile: Int32 = 1
        static let unknownProfile: Int32 = 2
        static let usage: Int32 = 64
    }

    static func run(_ command: CommandLineCommand) -> Int32 {
        switch command {
        case .help:
            print(CommandLineCommand.usage)
            return ExitStatus.success
        case .usageError(let message):
            printError("\(message)\n\n\(CommandLineCommand.usage)")
            return ExitStatus.usage
        case .list:
            return list()
        case .autoSwitch(let dryRun):
            return switchProfile(named: nil, dryRun: dryRun)
        case .switchTo(let name, let dryRun):
            return switchProfile(named: name, dryRun: dryRun)
        }
    }

    // MARK: - Commands

    private static func list() -> Int32 {
        let profiles = ProfileStore().profiles.sorted { $0.priority > $1.priority }
        let snapshot = NetworkMonitor.buildSnapshot()
        let chosen = ProfileMatcher.bestMatch(for: snapshot, in: profiles)
        print(networkSummary(snapshot))
        let width = profiles.map(\.name.count).max() ?? 0
        for profile in profiles {
            let mark: String
            switch profile.evaluate(snapshot) {
            case _ where profile.isFallback: mark = "·"
            case true?: mark = "✓"
            case false?: mark = "✗"
            case nil: mark = "?"
            }
            let detail = profile.isFallback ? "fallback" : "priority \(profile.priority)"
            let pointer = profile.id == chosen?.id ? "   ← current match" : ""
            print("  \(mark) \(profile.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(detail)\(pointer)")
        }
        if profiles.contains(where: { $0.evaluate(snapshot) == nil }) {
            print("\n? = can't be checked here: \(unknownExplanation)")
        }
        return ExitStatus.success
    }

    private static func switchProfile(named name: String?, dryRun: Bool) -> Int32 {
        let store = ProfileStore()
        if !dryRun, let reply = forwardToRunningApp(profileName: name, profilesPath: store.fileURL.path) {
            if reply.status == ExitStatus.success { print(reply.output) } else { printError(reply.output) }
            return reply.status
        }

        let profiles = store.profiles
        let snapshot = NetworkMonitor.buildSnapshot()
        let profile: Profile
        let reason: SwitchReason
        if let name {
            guard let named = profiles.profile(named: name) else {
                printError(unknownProfileMessage(name, profiles: profiles))
                return ExitStatus.unknownProfile
            }
            profile = named
            reason = .named
        } else {
            guard let best = ProfileMatcher.bestMatch(for: snapshot, in: profiles) else {
                printError(noMatchMessage(snapshot: snapshot, profiles: profiles))
                return ExitStatus.noMatchingProfile
            }
            profile = best
            reason = best.isFallback ? .fallback : .matched
        }

        let launcher = AppLauncherService.shared
        let launches = LaunchTracker()
        let outcomes = profile.appRules.map { rule in
            let outcome = launcher.enforce(rule.action, for: rule, dryRun: dryRun) { succeeded in
                launches.finished(rule.displayName, succeeded: succeeded)
            }
            if outcome == .launched && !dryRun { launches.pending += 1 }
            return (rule, outcome)
        }
        // Stay alive until the launches have gone through (or 30 s pass).
        let deadline = Date().addingTimeInterval(30)
        while launches.pending > 0 && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        print(report(profile: profile, outcomes: outcomes, reason: reason, dryRun: dryRun))
        if !launches.failed.isEmpty {
            printError("Couldn't launch: \(launches.failed.joined(separator: ", "))")
        }
        if reason != .named, profiles.contains(where: { $0.evaluate(snapshot) == nil }) {
            print("Note: some conditions couldn't be checked here — \(unknownExplanation)")
        }
        return ExitStatus.success
    }

    // MARK: - Running app

    /// Hands the switch to a running menu bar app and waits for its reply.
    /// nil if none is running, or it didn't answer — then we do it here,
    /// which is safe even if it acts late: enforcing a profile twice changes
    /// nothing the second time.
    private static func forwardToRunningApp(profileName: String?, profilesPath: String) -> RemoteCommand.Reply? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.contextswitch.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return nil }

        let request = RemoteCommand.Request(profileName: profileName, profilesPath: profilesPath)
        let box = ReplyBox()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: RemoteCommand.replyName, object: nil, queue: .main) { note in
            guard let reply = RemoteCommand.Reply(userInfo: note.userInfo), reply.id == request.id else { return }
            MainActor.assumeIsolated { box.reply = reply }
        }
        defer { center.removeObserver(observer) }

        RemoteCommand.post(RemoteCommand.requestName, userInfo: request.userInfo)
        let deadline = Date().addingTimeInterval(5)
        while box.reply == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if box.reply == nil {
            printError("The running ContextSwitch didn't answer; switching from here instead.")
        }
        return box.reply
    }

    // MARK: - Messages (shared with the menu bar app's replies)

    enum SwitchReason {
        case matched, fallback, named
    }

    static func report(profile: Profile, outcomes: [(AppRule, EnforceOutcome)], reason: SwitchReason, dryRun: Bool) -> String {
        let because: String
        switch reason {
        case .matched: because = " — its conditions match"
        case .fallback: because = " — the fallback, as no other profile matches"
        case .named: because = ""
        }
        var lines = ["\(dryRun ? "Would switch" : "Switched") to “\(profile.name)”\(because)."]
        for (rule, outcome) in outcomes {
            let name = rule.displayName
            switch outcome {
            case .launched: lines.append("  ▸ \(dryRun ? "would launch" : "launched") \(name)")
            case .quit: lines.append("  ▸ \(dryRun ? "would quit" : "quit") \(name)")
            case .alreadyRunning: lines.append("  · \(name) is already running")
            case .notRunning: lines.append("  · \(name) isn't running")
            case .ignored: lines.append("  · \(name) is left as it is")
            }
        }
        if outcomes.isEmpty { lines.append("  (no apps in this profile)") }
        return lines.joined(separator: "\n")
    }

    static func unknownProfileMessage(_ name: String, profiles: [Profile]) -> String {
        let names = profiles.sorted { $0.priority > $1.priority }.map { "“\($0.name)”" }.joined(separator: ", ")
        return "No profile named “\(name)”. Profiles: \(names.isEmpty ? "none" : names)"
    }

    static func noMatchMessage(snapshot: NetworkSnapshot, profiles: [Profile]) -> String {
        var message = "No profile matches right now, and there's no fallback profile."
        if profiles.contains(where: { $0.evaluate(snapshot) == nil }) {
            message += "\nSome conditions couldn't be checked — \(unknownExplanation)"
        }
        return message
    }

    private static let unknownExplanation =
        "macOS hides the Wi-Fi name without Location access, and places need a location fix. "
        + "With the menu bar app running, switching is done by it, which can check these."

    private static func networkSummary(_ snapshot: NetworkSnapshot) -> String {
        guard let primary = snapshot.primary else { return "Network: offline" }
        var parts: [String] = []
        switch primary.kind {
        case .wifi: parts.append(primary.ssid.map { "Wi-Fi “\($0)”" } ?? "Wi-Fi (name hidden)")
        case .ethernet, .other: parts.append(primary.serviceName)
        }
        if let router = primary.routerIPv4 { parts.append("router \(router)") }
        if !snapshot.dnsDomains.isEmpty { parts.append("DNS \(snapshot.dnsDomains.joined(separator: ", "))") }
        return "Network: " + parts.joined(separator: " · ")
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

@MainActor
private final class LaunchTracker {
    var pending = 0
    var failed: [String] = []

    func finished(_ name: String, succeeded: Bool) {
        pending -= 1
        if !succeeded { failed.append(name) }
    }
}

@MainActor
private final class ReplyBox {
    var reply: RemoteCommand.Reply?
}
