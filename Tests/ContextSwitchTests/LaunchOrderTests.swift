import Foundation
import Testing

private func rule(_ name: String, after other: AppRule? = nil, action: AppAction = .launch) -> AppRule {
    var rule = AppRule(bundleIdentifier: nil, path: "/usr/local/bin/\(name)", displayName: name, action: action)
    rule.launchesAfter = other?.id
    return rule
}

@Suite struct LaunchOrderTests {
    @Test func findsTheRuleItWaitsFor() {
        let tailscale = rule("tailscale")
        let proxy = rule("proxy", after: tailscale)
        #expect(LaunchOrder.dependency(of: proxy, in: [proxy, tailscale])?.id == tailscale.id)
        #expect(LaunchOrder.dependency(of: tailscale, in: [proxy, tailscale]) == nil)
    }

    @Test func ignoresARuleThatIsGone() {
        let gone = rule("gone")
        let proxy = rule("proxy", after: gone)
        #expect(LaunchOrder.dependency(of: proxy, in: [proxy]) == nil)
    }

    @Test func ignoresCircles() {
        var a = rule("a")
        var b = rule("b", after: a)
        a.launchesAfter = b.id
        #expect(LaunchOrder.dependency(of: a, in: [a, b]) == nil)
        #expect(LaunchOrder.dependency(of: b, in: [a, b]) == nil)
        // Itself.
        var c = rule("c")
        c.launchesAfter = c.id
        #expect(LaunchOrder.dependency(of: c, in: [c]) == nil)
        // A circle it's merely after, not in.
        let d = rule("d", after: a)
        b.launchesAfter = a.id
        #expect(LaunchOrder.dependency(of: d, in: [a, b, d])?.id == a.id)
    }

    @Test func offersWhatWouldNotMakeACircle() {
        let a = rule("a")
        let b = rule("b", after: a)
        let c = rule("c", after: b)
        let quitting = rule("quitting", action: .quit)
        let all = [a, b, c, quitting]
        // `a` can't be after `b` or `c`, which wait for it; nor after what isn't launched.
        #expect(LaunchOrder.candidates(for: a, in: all).isEmpty)
        #expect(Set(LaunchOrder.candidates(for: c, in: all).map(\.displayName)) == ["a", "b"])
        #expect(Set(LaunchOrder.candidates(for: quitting, in: all).map(\.displayName)) == ["a", "b", "c"])
    }

    @Test func keepsTheLinkInACopyOfAProfile() {
        let tailscale = rule("tailscale")
        var proxy = rule("proxy", after: tailscale)
        proxy.launchDelay = 5
        let copy = Profile(name: "Home", conditions: [], appRules: [proxy, tailscale], priority: 0).withNewIDs()
        #expect(copy.appRules[0].launchesAfter == copy.appRules[1].id)
        #expect(copy.appRules[0].launchesAfter != tailscale.id)
        #expect(copy.appRules[0].launchDelay == 5)
    }

    @Test func removingARuleFreesTheOnesAfterIt() {
        let tailscale = rule("tailscale")
        var proxy = rule("proxy", after: tailscale)
        proxy.launchDelay = 5
        var profile = Profile(name: "Home", conditions: [], appRules: [proxy, tailscale], priority: 0)
        profile.removeRule(id: tailscale.id)
        #expect(profile.appRules.count == 1)
        #expect(profile.appRules[0].launchesAfter == nil)
        #expect(profile.appRules[0].launchDelay == nil)
    }

    @Test func oldProfilesStillLoad() throws {
        let json = #"{"id":"6F0A8F0E-3C0B-4B8E-9C5A-0D6E7E7B2A11","displayName":"x","action":"launch"}"#
        let decoded = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))
        #expect(decoded.launchesAfter == nil)
        #expect(decoded.launchDelay == nil)
        let proxy = rule("proxy", after: rule("tailscale"))
        #expect(try JSONDecoder().decode(AppRule.self, from: JSONEncoder().encode(proxy)) == proxy)
    }
}

@MainActor private final class Recorder {
    var finished: [String] = []
    var failures: [String: String] = [:]

    func record(_ rule: AppRule, _ failure: LaunchFailure?) {
        finished.append(rule.displayName)
        failures[rule.displayName] = failure?.reason
    }
}

/// Real scripts: each one records when it ran in a log, then stays up.
@MainActor @Suite struct LaunchSequencerTests {
    private let folder: URL
    private let log: URL

    init() throws {
        folder = try temporaryFolder()
        log = folder.appendingPathComponent("log")
    }

    private func script(_ name: String) throws -> AppRule {
        let url = folder.appendingPathComponent(name)
        try "#!/bin/sh\necho \(name) >> '\(log.path)'\nexec /bin/sleep 60\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return AppRule(bundleIdentifier: nil, path: url.path, displayName: name, action: .launch)
    }

    private func started() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func wait(_ seconds: Double = 5, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func stop(_ rules: [AppRule]) {
        rules.forEach { AppLauncherService.shared.quit($0) }
    }

    @Test func launchesInOrderAndAfterTheDelay() async throws {
        // Unique names, as a program running is found by its path.
        let first = try script("first-\(UUID().uuidString)")
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        second.launchDelay = 1
        let rules = [second, first]   // the one that waits comes first
        defer { stop(rules) }

        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        let recorder = Recorder()
        let began = Date()
        let outcomes = sequencer.enforce(rules) { recorder.record($0, $1) }
        #expect(outcomes[0].1 == .waiting(for: first.displayName))
        #expect(outcomes[1].1 == .launched)
        #expect(sequencer.hasWaiting)

        // The scripts write their line a moment after they're started.
        await wait { started() == [first.displayName] }
        // The delay hasn't passed.
        #expect(started() == [first.displayName])
        #expect(recorder.finished == [first.displayName])
        await wait { started().count == 2 }
        #expect(started() == [first.displayName, second.displayName])
        #expect(recorder.failures.isEmpty)
        #expect(Date().timeIntervalSince(began) >= 1)
        #expect(!sequencer.hasWaiting)
    }

    @Test func doesNotWaitForOneThatIsRunningAlready() async throws {
        let first = try script("first-\(UUID().uuidString)")
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        second.launchDelay = 30
        defer { stop([first, second]) }

        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        let recorder = Recorder()
        _ = sequencer.enforce([first]) { recorder.record($0, $1) }
        await wait { !recorder.finished.isEmpty }
        #expect(AppLauncherService.shared.isRunning(first))

        let outcomes = sequencer.enforce([first, second])
        #expect(outcomes[0].1 == .alreadyRunning)
        #expect(outcomes[1].1 == .launched)
    }

    @Test func givesUpWhenItNeverComesUp() async throws {
        let first = try script("first-\(UUID().uuidString)")
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        defer { stop([first, second]) }

        // As if `first` were launched but never showed as running.
        let sequencer = LaunchSequencer(dependencyTimeout: .milliseconds(300), pollInterval: .milliseconds(20),
                                        isRunning: { _ in false })
        let recorder = Recorder()
        _ = sequencer.enforce([second, first]) { recorder.record($0, $1) }
        await wait { recorder.failures[second.displayName] != nil }
        #expect(recorder.failures[second.displayName]?.contains("still wasn't running") == true)
        #expect(!started().contains(second.displayName))
    }

    @Test func givesUpAtOnceWhenWhatItWaitsForCannotLaunch() async throws {
        var first = try script("first-\(UUID().uuidString)")
        first.path = folder.appendingPathComponent("missing-\(UUID().uuidString)").path
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        defer { stop([second]) }

        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        let recorder = Recorder()
        _ = sequencer.enforce([first, second]) { recorder.record($0, $1) }
        await wait { recorder.finished.count == 2 }
        #expect(recorder.failures[second.displayName]?.contains("couldn't be launched") == true)
        #expect(!started().contains(second.displayName))
    }

    @Test func switchingProfilesDropsWhatWasWaiting() async throws {
        let first = try script("first-\(UUID().uuidString)")
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        second.launchDelay = 1
        let rules = [second, first]
        defer { stop(rules) }

        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        _ = sequencer.enforce(rules)
        await wait { started() == [first.displayName] }
        // Another profile takes over before the delay is up.
        _ = sequencer.enforce([])
        #expect(!sequencer.hasWaiting)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!started().contains(second.displayName))
    }

    @Test func aChainsTimeoutStartsWhenWhatItWaitsForIsLaunched() async throws {
        // `second` is after `first`, which is after `gate` and waits 2 s: longer than the timeout.
        let gate = try script("gate-\(UUID().uuidString)")
        var first = try script("first-\(UUID().uuidString)")
        first.launchesAfter = gate.id
        first.launchDelay = 2
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        let rules = [second, first, gate]
        defer { stop(rules) }

        let sequencer = LaunchSequencer(dependencyTimeout: .seconds(1), pollInterval: .milliseconds(20))
        let recorder = Recorder()
        _ = sequencer.enforce(rules) { recorder.record($0, $1) }
        await wait(8) { recorder.finished.count == 3 }
        // In the order launched (what they write may land a moment apart).
        #expect(recorder.finished == [gate.displayName, first.displayName, second.displayName])
        #expect(recorder.failures.isEmpty)
    }

    @Test func turningOneOnLaunchesWhatItWaitsFor() async throws {
        let first = try script("first-\(UUID().uuidString)")
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        second.launchDelay = 1
        defer { stop([first, second]) }

        // As from the menu: neither is running, and nothing's under way.
        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        let recorder = Recorder()
        let outcome = sequencer.enforce(second, in: [second, first]) { recorder.record($0, $1) }
        #expect(outcome == .waiting(for: first.displayName))
        await wait { started().count == 2 }
        #expect(started() == [first.displayName, second.displayName])
        #expect(recorder.failures.isEmpty)
    }

    @Test func anEarlierFailureDoesNotCarryOverToTryingAgain() async throws {
        var first = try script("first-\(UUID().uuidString)")
        let installed = first.path!
        first.path = folder.appendingPathComponent("not-yet-\(UUID().uuidString)").path
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        second.launchDelay = 1
        defer { stop([first, second]) }

        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        let before = Recorder()
        _ = sequencer.enforce([first, second]) { before.record($0, $1) }
        await wait { before.finished.count == 2 }
        #expect(before.failures[second.displayName]?.contains("couldn't be launched") == true)

        // It's installed now.
        first.path = installed
        let after = Recorder()
        _ = sequencer.enforce(second, in: [first, second]) { after.record($0, $1) }
        await wait { started().count == 2 }
        #expect(started() == [first.displayName, second.displayName])
        #expect(after.failures.isEmpty)
    }

    @Test func theDelayHoldsWhenWhatItWaitsForComesFirst() async throws {
        let first = try script("first-\(UUID().uuidString)")
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        second.launchDelay = 1
        let rules = [first, second]   // a program we start is running at once
        defer { stop(rules) }

        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        let outcomes = sequencer.enforce(rules)
        #expect(outcomes[0].1 == .launched)
        #expect(outcomes[1].1 == .waiting(for: first.displayName))
        await wait { started() == [first.displayName] }
        #expect(started() == [first.displayName])
        await wait { started().count == 2 }
        #expect(started() == [first.displayName, second.displayName])
    }

    @Test func aDryRunChangesNothing() async throws {
        let first = try script("first-\(UUID().uuidString)")
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        let sequencer = LaunchSequencer(pollInterval: .milliseconds(20))
        let outcomes = sequencer.enforce([second, first], dryRun: true)
        #expect(outcomes[0].1 == .waiting(for: first.displayName))
        #expect(outcomes[1].1 == .launched)
        #expect(!sequencer.hasWaiting)
        try await Task.sleep(for: .milliseconds(200))
        #expect(started().isEmpty)
    }

    @Test func saysWhenWhatItWaitsForWontBeLaunched() throws {
        var first = try script("first-\(UUID().uuidString)")
        first.action = .ignore
        var second = try script("second-\(UUID().uuidString)")
        second.launchesAfter = first.id
        let sequencer = LaunchSequencer()
        let outcomes = sequencer.enforce([second, first], dryRun: true)
        #expect(outcomes[0].1 == .blocked(by: first.displayName))
    }
}
