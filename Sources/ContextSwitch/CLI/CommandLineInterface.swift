import AppKit

/// Runs a `CommandLineCommand` and returns the process exit status. If the
/// menu bar app is running, switching and importing are handed to it;
/// otherwise they're done here, in this short-lived process.
@MainActor
enum CommandLineInterface {
    typealias ExitStatus = CommandLineCommand.ExitStatus

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
        case .export(let file, let profile):
            return export(to: file, profileName: profile)
        case .importProfiles(let file, let onMatch, let dryRun):
            return importProfiles(from: file, onMatch: onMatch, dryRun: dryRun)
        }
    }

    // MARK: - Commands

    private static func list() -> Int32 {
        let store = loadProfiles()
        warnAboutProblem(in: store)
        let profiles = store.profiles.sorted { $0.priority > $1.priority }
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
        let store = loadProfiles()
        warnAboutProblem(in: store)
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
            let outcome = launcher.enforce(rule.action, for: rule, dryRun: dryRun) { failure in
                launches.finished(rule.displayName, failure: failure)
            }
            if outcome == .launched && !dryRun { launches.pending += 1 }
            return (rule, outcome)
        }
        // Stay alive until the launches have gone through (or 30 s pass).
        let deadline = Date().addingTimeInterval(30)
        while launches.pending > 0 && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        let summary = report(profile: profile, outcomes: outcomes, reason: reason, dryRun: dryRun)
        print(summary)
        if !launches.failed.isEmpty {
            printError("Couldn't launch: \(launches.failed.joined(separator: ", "))")
        }
        if !dryRun {
            // The menu bar app logs its own switches; this one happened here.
            let log = ActivityLog.shared
            var lines = summary.components(separatedBy: "\n")
            lines[0] = "From the command line: \(lines[0])"
            lines.insert("  \(networkSummary(snapshot))", at: 1)
            log.record(lines.joined(separator: "\n"))
            for failure in launches.failed {
                log.record("Couldn't launch \(failure)", level: .problem)
            }
            log.flush()
        }
        if reason != .named, profiles.contains(where: { $0.evaluate(snapshot) == nil }) {
            print("Note: some conditions couldn't be checked here — \(unknownExplanation)")
        }
        return ExitStatus.success
    }

    /// All profiles, or the named one, as JSON to `path` or standard output.
    /// Done here even if the menu bar app is running: it saves every change.
    private static func export(to path: String?, profileName: String?) -> Int32 {
        let store = loadProfiles()
        warnAboutProblem(in: store)
        // What there is instead is a blank profile.
        if case .unreadableFile? = store.problem {
            printError("Nothing was exported, as your profiles couldn't be read.")
            return ExitStatus.badData
        }
        var profile: Profile?
        if let profileName {
            guard let named = store.profiles.profile(named: profileName) else {
                printError(unknownProfileMessage(profileName, profiles: store.profiles))
                return ExitStatus.unknownProfile
            }
            profile = named
        }
        do {
            let data = try store.exportData(of: profile.map { Set([$0.id]) })
            guard let path, path != "-" else {
                FileHandle.standardOutput.write(data + Data("\n".utf8))
                return ExitStatus.success
            }
            guard !store.isProfilesFile(path) else {
                printError("\(path) is where ContextSwitch keeps your profiles: export to another file.")
                return ExitStatus.usage
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            let what = profile.map { "“\($0.name)”" } ?? (store.profiles.count == 1 ? "1 profile" : "\(store.profiles.count) profiles")
            var also = ""
            if profile == nil, case .unreadableProfiles(let lost)? = store.problem {
                also = ", and \(lost.count) that this version can't read, as \(lost.count == 1 ? "it was" : "they were")"
            }
            print("Exported \(what) to \(path)\(also).")
            return ExitStatus.success
        } catch {
            printError("Couldn't write \(path ?? "the profiles"): \(error.localizedDescription)")
            return ExitStatus.cannotWrite
        }
    }

    private static func importProfiles(from path: String, onMatch: CommandLineCommand.OnMatch, dryRun: Bool) -> Int32 {
        let fileName = path == "-" ? "standard input" : URL(fileURLWithPath: path).lastPathComponent
        let data: Data
        do {
            data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            printError("Couldn't read \(path): \(error.localizedDescription)")
            return ExitStatus.cannotRead
        }
        // Checked here first, so a mistake needn't trouble the menu bar app.
        // Whether profiles match yours is for whichever has them to say.
        do throws(ImportCommand.Failure) {
            _ = try ImportCommand.read(data, from: fileName)
        } catch {
            printError(error.message)
            return error.status
        }
        let store = loadProfiles()
        warnAboutProblem(in: store)

        // A dry run goes by the saved profiles, as the running app's are.
        guard !dryRun else { return importHere(data, from: fileName, into: store, onMatch: onMatch, dryRun: true) }

        let request = RemoteCommand.ImportRequest(profilesPath: store.fileURL.path, fileName: fileName, contents: data,
                                                  onMatch: onMatch)
        let ignoredBy: Set<pid_t>
        switch forward(RemoteCommand.importRequestName, id: request.id, userInfo: request.userInfo) {
        case .answered(let reply):
            if reply.status == ExitStatus.success { print(reply.output) } else { printError(reply.output) }
            return reply.status
        case .unanswered(accepted: true):
            printError("ContextSwitch took the import on, but hasn't said how it went. "
                       + "Check Edit Profiles before trying again.")
            return ExitStatus.tryAgain
        case .unanswered(accepted: false):
            // Doing it here, it could save over the import. It drops a
            // request it gets too late to take on (see `importExpiry`).
            printError("ContextSwitch is running but didn't answer (it may be a version without --import), "
                       + "so nothing was imported. Try again, or quit ContextSwitch and import then.")
            return ExitStatus.tryAgain
        case .notForwarded(let ignoring):
            ignoredBy = ignoring
        }
        // No app has these profiles now, but one could start: it waits for
        // the lock to load them, and one that has started has them already.
        return ProfileStore.whileLocked(store.fileURL) {
            guard otherInstances().allSatisfy({ ignoredBy.contains($0.processIdentifier) }) else {
                printError("ContextSwitch started meanwhile, so nothing was imported. Try again.")
                return ExitStatus.tryAgain
            }
            store.load()
            return importHere(data, from: fileName, into: store, onMatch: onMatch, dryRun: false)
        }
    }

    /// `--import`, with no menu bar app to carry it out.
    private static func importHere(_ data: Data, from fileName: String, into store: ProfileStore,
                                   onMatch: CommandLineCommand.OnMatch, dryRun: Bool) -> Int32 {
        let imported: ProfileImport, replacing: Bool
        switch ImportCommand.plan(data, from: fileName, into: store.profiles, onMatch: onMatch) {
        case .fail(let status, let message):
            printError(message)
            return status
        case .importing(let planned, let replace):
            (imported, replacing) = (planned, replace)
        }
        let merge = store.merging(imported, replacing: replacing)
        if dryRun {
            print(ImportCommand.report(merge, of: imported, from: fileName, dryRun: true))
            return ExitStatus.success
        }
        let log = ActivityLog.shared
        defer { log.flush() }
        do {
            try store.importProfiles(merge)
        } catch {
            printError("Couldn't save your profiles: \(error.localizedDescription)")
            return ExitStatus.cannotWrite
        }
        if let copy = store.copiedAside {
            let note = "Saved a copy of the original \(store.fileURL.lastPathComponent) as \(copy.lastPathComponent) before saving over it."
            log.record(note)
            printError(note)
        }
        let report = ImportCommand.report(merge, of: imported, from: fileName, dryRun: false)
        log.record("From the command line: \(report)")
        print(report)
        return ExitStatus.success
    }

    /// Loading can save (IDs made up for profiles without one, or the
    /// default profile in a new file), so it's done holding the lock, like
    /// a standalone import (see `ProfileStore.whileLocked`).
    private static func loadProfiles() -> ProfileStore {
        ProfileStore.whileLocked { ProfileStore() }
    }

    // MARK: - Running app

    /// Hands the switch to a running menu bar app and waits for its reply.
    /// nil if none is running for these profiles, or it didn't answer — then
    /// we do it here, which is safe even if it acts late: enforcing a profile
    /// twice changes nothing the second time.
    private static func forwardToRunningApp(profileName: String?, profilesPath: String) -> RemoteCommand.Reply? {
        let request = RemoteCommand.Request(profileName: profileName, profilesPath: profilesPath)
        switch forward(RemoteCommand.requestName, id: request.id, userInfo: request.userInfo) {
        case .answered(let reply):
            return reply
        case .notForwarded:
            return nil
        case .unanswered:
            printError("The running ContextSwitch didn't answer; switching from here instead.")
            return nil
        }
    }

    /// Other ContextSwitch processes running: menu bar apps, mostly.
    private static func otherInstances() -> [NSRunningApplication] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.contextswitch.app"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private enum Forwarding {
        case answered(RemoteCommand.Reply)
        /// No menu bar app is running, or none uses these profiles: the ones
        /// running, by process ID, said so.
        case notForwarded(ignoredBy: Set<pid_t>)
        /// One is running, but didn't answer: it may use these profiles.
        /// `accepted`: it took an import on, but didn't say how it went.
        case unanswered(accepted: Bool)
    }

    /// Posts a request to the running menu bar apps, and waits for the one
    /// using these profiles to answer, or every one to say it doesn't.
    private static func forward(_ name: Notification.Name, id: String, userInfo: [String: String]) -> Forwarding {
        let others = otherInstances()
        guard !others.isEmpty else { return .notForwarded(ignoredBy: []) }

        let box = ReplyBox()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: RemoteCommand.replyName, object: nil, queue: .main) { note in
            guard let reply = RemoteCommand.Reply(userInfo: note.userInfo), reply.id == id else { return }
            MainActor.assumeIsolated { box.replies.append(reply) }
        }
        defer { center.removeObserver(observer) }

        RemoteCommand.post(name, userInfo: userInfo)
        let sent = Date()
        while true {
            if let answer = box.replies.first(where: { $0.kind == .answer }) { return .answered(answer) }
            if box.replies.filter({ $0.kind == .ignored }).count >= others.count {
                return .notForwarded(ignoredBy: Set(others.map(\.processIdentifier)))
            }
            let accepted = box.replies.contains { $0.kind == .accepted }
            guard Date() < sent.addingTimeInterval(accepted ? RemoteCommand.acceptedTimeout : RemoteCommand.replyTimeout) else {
                return .unanswered(accepted: accepted)
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
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
        return (["\(dryRun ? "Would switch" : "Switched") to “\(profile.name)”\(because)."]
            + outcomeLines(outcomes, dryRun: dryRun)).joined(separator: "\n")
    }

    /// One line per app, e.g. "  ▸ launched Slack".
    static func outcomeLines(_ outcomes: [(AppRule, EnforceOutcome)], dryRun: Bool) -> [String] {
        var lines: [String] = []
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
        return lines
    }

    static func unknownProfileMessage(_ name: String, profiles: [Profile]) -> String {
        let names = profiles.sorted { $0.priority > $1.priority }.map { "“\($0.name)”" }.joined(separator: ", ")
        return "No profile named “\(name)”. Profiles: \(names.isEmpty ? "none" : names)"
    }

    static func noMatchMessage(snapshot: NetworkSnapshot, profiles: [Profile], history: SnapshotHistory? = nil) -> String {
        var message = "No profile matches right now, and there's no fallback profile."
        if profiles.contains(where: { $0.evaluate(snapshot, history: history) == nil }) {
            message += "\nSome conditions couldn't be checked — \(unknownExplanation)"
        }
        return message
    }

    private static let unknownExplanation =
        "macOS hides the Wi-Fi name without Location access, places need a location fix, "
        + "and timed conditions (“for 5 min”) need watching over time. "
        + "With the menu bar app running, switching is done by it, which can check these."

    static func networkSummary(_ snapshot: NetworkSnapshot) -> String {
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

    private static func warnAboutProblem(in store: ProfileStore) {
        guard let problem = store.problem else { return }
        printError("Warning: \(problem.details)\n")
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

@MainActor
private final class LaunchTracker {
    var pending = 0
    /// e.g. "OpenRGB (It isn't installed, or has moved.)"
    var failed: [String] = []

    func finished(_ name: String, failure: LaunchFailure?) {
        pending -= 1
        if let failure { failed.append("\(name) (\(failure.reason))") }
    }
}

@MainActor
private final class ReplyBox {
    var replies: [RemoteCommand.Reply] = []
}
