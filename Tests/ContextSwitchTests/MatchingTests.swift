import Foundation
import Testing

private let wifi = NetworkConnection(
    serviceName: "Wi-Fi", interfaceName: "en0", kind: .wifi,
    localIPv4: "10.0.0.23", routerIPv4: "10.0.0.1", routerMAC: "f8:d0:0e:23:50:ff", ssid: "Home-WiFi"
)
private let dock = NetworkConnection(
    serviceName: "USB 10/100/1000 LAN", interfaceName: "en8", kind: .ethernet,
    localIPv4: "172.16.4.20", routerIPv4: "172.16.4.1", routerMAC: "00:1a:2b:3c:4d:5e"
)

@Suite struct MACAddressTests {
    @Test func padsOctetsThatArpShortens() {
        #expect(MACAddress.normalize("f8:d0:e:23:50:ff") == "f8:d0:0e:23:50:ff")
    }

    @Test func acceptsDashesAndUppercase() {
        #expect(MACAddress.normalize("F8-D0-0E-23-50-FF") == "f8:d0:0e:23:50:ff")
    }

    @Test func leavesNonMACsAlone() {
        #expect(MACAddress.normalize("not-a-mac") == "not-a-mac")
    }

    @Test func readsRouterFromNetworkSignature() {
        #expect(MACAddress.router(fromNetworkSignature: "IPv4.Router=10.0.0.1;IPv4.RouterHardwareAddress=f8:d0:e:23:50:ff") == "f8:d0:0e:23:50:ff")
        #expect(MACAddress.router(fromNetworkSignature: "IPv4.Router=10.0.0.1") == nil)
    }
}

@Suite struct ConditionMatchingTests {
    @Test func wiredNetworkMatchesTypedMACAgainstArpForm() {
        var shortened = dock
        shortened.routerMAC = "0:1a:2b:3c:4d:5e"  // as printed by arp
        let snapshot = NetworkSnapshot(connections: [shortened])
        #expect(NetworkCondition.wiredNetwork(name: "Office", routerMAC: "00:1A:2B:3C:4D:5E").isSatisfied(by: snapshot))
    }

    @Test func wiredNetworkIgnoresSameRouterOverWiFi() {
        var sameRouterWiFi = wifi
        sameRouterWiFi.routerMAC = dock.routerMAC
        let snapshot = NetworkSnapshot(connections: [sameRouterWiFi])
        #expect(!NetworkCondition.wiredNetwork(name: "Office", routerMAC: dock.routerMAC!).isSatisfied(by: snapshot))
        #expect(NetworkCondition.gatewayMAC(dock.routerMAC!).isSatisfied(by: snapshot))
    }

    @Test func wifiMatchesWhileDockedOnEthernet() {
        // Ethernet is primary, Wi-Fi is still associated.
        let snapshot = NetworkSnapshot(connections: [dock, wifi])
        #expect(NetworkCondition.ssid("home-wifi").isSatisfied(by: snapshot))
        #expect(NetworkCondition.ethernetAdapter("USB 10/100/1000 LAN").isSatisfied(by: snapshot))
        #expect(!NetworkCondition.ethernetAdapter("Thunderbolt Ethernet").isSatisfied(by: snapshot))
    }

    @Test func ssidCannotMatchWhenRedacted() {
        var redacted = wifi
        redacted.ssid = nil  // no Location permission
        #expect(!NetworkCondition.ssid("Home-WiFi").isSatisfied(by: NetworkSnapshot(connections: [redacted])))
    }

    @Test func dnsDomainIsCaseInsensitive() {
        let snapshot = NetworkSnapshot(connections: [dock], dnsDomains: ["Corp.Example.com"])
        #expect(NetworkCondition.dnsDomain("corp.example.com").isSatisfied(by: snapshot))
    }

    @Test func subnetAndRouterIPCheckEveryConnection() {
        let snapshot = NetworkSnapshot(connections: [dock, wifi])
        #expect(NetworkCondition.subnet(cidr: "10.0.0.0/24").isSatisfied(by: snapshot))
        #expect(NetworkCondition.gatewayIP("10.0.0.1").isSatisfied(by: snapshot))
        #expect(!NetworkCondition.subnet(cidr: "192.168.1.0/24").isSatisfied(by: snapshot))
    }
}

@Suite struct DeviceConditionTests {
    let dockEntry = USBDevice(name: "40AY", manufacturer: "Lenovo", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM")
    let monitor = ConnectedDisplay(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: 180875)

    @Test func usbDeviceMatchesTheRecordedUnitOrAnyOfTheModel() {
        let snapshot = NetworkSnapshot(usbDevices: [dockEntry])
        #expect(NetworkCondition.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM").isSatisfied(by: snapshot))
        #expect(NetworkCondition.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: nil).isSatisfied(by: snapshot))
        // The same model of dock, at another desk.
        #expect(!NetworkCondition.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USOTHER").isSatisfied(by: snapshot))
        #expect(!NetworkCondition.usbDevice(name: "40AY", vendorID: 6127, productID: 12464, serialNumber: nil).isSatisfied(by: snapshot))
    }

    @Test func displayMatchesTheRecordedUnitOrAnyOfTheModel() {
        let snapshot = NetworkSnapshot(displays: [monitor])
        #expect(NetworkCondition.display(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: 180875).isSatisfied(by: snapshot))
        #expect(NetworkCondition.display(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: nil).isSatisfied(by: snapshot))
        #expect(!NetworkCondition.display(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: 1).isSatisfied(by: snapshot))
        #expect(!NetworkCondition.display(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: nil).isSatisfied(by: .empty))
    }

    @Test func unpluggedIsKnownSoNotMatches() {
        let undocked = Profile(name: "Undocked", conditions: [
            ConditionClause(.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: nil), isNegated: true),
        ])
        #expect(undocked.evaluate(.empty) == true)
        #expect(undocked.evaluate(NetworkSnapshot(usbDevices: [dockEntry])) == false)
    }

    @Test func devicesCombineWithNetworkConditions() {
        // At the office desk: on the office LAN and the big monitor attached.
        let desk = Profile(name: "Desk", conditions: [
            ConditionClause(.ethernetAdapter("USB 10/100/1000 LAN")),
            ConditionClause(.display(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: 180875)),
        ])
        #expect(desk.matches(NetworkSnapshot(connections: [dock], displays: [monitor])))
        #expect(!desk.matches(NetworkSnapshot(connections: [dock])))
        #expect(desk.conditionSummary == "Ethernet Adapter “USB 10/100/1000 LAN” and Display “LG ULTRAWIDE”")
    }
}

@Suite struct TimedConditionTests {
    let tbDock = NetworkCondition.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM")
    let docked = NetworkSnapshot(connections: [dock], usbDevices: [
        USBDevice(name: "40AY", manufacturer: "Lenovo", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM"),
    ])
    let undocked = NetworkSnapshot(connections: [wifi])
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func minutes(_ m: Double) -> Date { t0 + m * 60 }

    /// Docked at launch, unplugged at minute 10.
    private var unpluggedAtTen: SnapshotHistory {
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        return history
    }

    @Test func countsOnceHeldLongEnough() {
        let notDocked5 = ConditionClause(tbDock, isNegated: true, duration: 5 * 60)
        let history = unpluggedAtTen
        #expect(notDocked5.evaluate(undocked, history: history, at: minutes(12)) == false)
        #expect(notDocked5.holdsFrom(undocked, history: history, at: minutes(12)) == minutes(15))
        #expect(notDocked5.evaluate(undocked, history: history, at: minutes(15)) == true)
        #expect(notDocked5.summary == "not USB Device “40AY” for 5 min")
    }

    @Test func aBlipInSomethingElseDoesNotRestartTheTimer() {
        var history = unpluggedAtTen
        var otherNetwork = undocked
        otherNetwork.dnsDomains = ["guest.example.com"]
        history.record(otherNetwork, at: minutes(13))
        let notDocked5 = ConditionClause(tbDock, isNegated: true, duration: 5 * 60)
        #expect(notDocked5.evaluate(otherNetwork, history: history, at: minutes(15)) == true)
    }

    @Test func whatIsFoundAtLaunchCountsAsLongStanding() {
        var history = SnapshotHistory()
        history.record(undocked, at: t0)
        #expect(ConditionClause(tbDock, isNegated: true, duration: 5 * 60).evaluate(undocked, history: history, at: t0) == true)
    }

    @Test func beforeAnythingIsRecordedTheStateCountsAsLongStanding() {
        #expect(ConditionClause(tbDock, isNegated: true, duration: 5 * 60).evaluate(undocked, history: SnapshotHistory(), at: t0) == true)
    }

    @Test func aChangeNotYetRecordedCountsFromNow() {
        // The editor shows the live snapshot; the history only has settled ones.
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        let clause = ConditionClause(tbDock, isNegated: true, duration: 5 * 60)
        #expect(clause.holdsFrom(undocked, history: history, at: minutes(1)) == minutes(6))
    }

    @Test func withoutHistoryATimerCannotBeTold() {
        let clause = ConditionClause(tbDock, isNegated: true, duration: 5 * 60)
        #expect(clause.evaluate(undocked) == nil)
        #expect(clause.evaluate(docked) == false)  // not unplugged at all
    }

    @Test func historyKeepsADay() {
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        for hour in 1...48 {
            history.record(hour.isMultiple(of: 2) ? docked : undocked, at: t0 + Double(hour) * 3600)
        }
        let now = t0 + 48 * 3600
        #expect(history.entries.count < 30)
        #expect(history.entries[0].since <= now - SnapshotHistory.window)
        #expect(history.since(tbDock, was: true, at: now) == now)
    }

    @Test func graceKeepsCountingForAWhileAfterItStops() {
        let dockedWithGrace = ConditionClause(tbDock, grace: 5 * 60)
        let history = unpluggedAtTen
        #expect(dockedWithGrace.evaluate(undocked, history: history, at: minutes(12)) == true)
        #expect(dockedWithGrace.holdsFrom(undocked, history: history, at: minutes(12)) == .distantPast)
        #expect(dockedWithGrace.graceEnds(undocked, history: history, at: minutes(12)) == minutes(15))
        #expect(dockedWithGrace.evaluate(undocked, history: history, at: minutes(15)) == false)
        #expect(dockedWithGrace.holdsFrom(undocked, history: history, at: minutes(15)) == nil)
        #expect(dockedWithGrace.summary == "USB Device “40AY” with 5 min grace")
    }

    @Test func graceDoesNotCoverWhatWasFoundAtLaunch() {
        var history = SnapshotHistory()
        history.record(undocked, at: t0)
        #expect(ConditionClause(tbDock, grace: 5 * 60).evaluate(undocked, history: history, at: t0 + 1) == false)
    }

    @Test func graceNeedsToHaveSeenItHold() {
        // No Location access at first, so the Wi-Fi name is unknown; then it
        // reads as another network. "Office" never held, so no grace.
        var redacted = wifi
        redacted.ssid = nil
        var history = SnapshotHistory()
        history.record(NetworkSnapshot(connections: [redacted]), at: t0)
        history.record(undocked, at: minutes(1))
        let office = ConditionClause(.ssid("Office"), grace: 5 * 60)
        #expect(office.evaluate(undocked, history: history, at: minutes(2)) == false)
        #expect(office.graceEnds(undocked, history: history, at: minutes(2)) == nil)
    }

    @Test func graceIsSavedSoOlderVersionsKeepItAsIs() throws {
        /// How versions before grace read a clause's timer.
        struct OlderClause: Decodable { var duration: TimeInterval? }
        let grace = try JSONEncoder().encode(ConditionClause(tbDock, grace: 300))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OlderClause.self, from: grace) }
        let held = try JSONEncoder().encode(ConditionClause(tbDock, duration: 300))
        #expect(try JSONDecoder().decode(OlderClause.self, from: held).duration == 300)
    }

    @Test func readsGraceAsEarlierBuildsSavedIt() throws {
        // A top-level "grace", before it moved under "duration".
        let earlier = Data(#"{"condition": {"ssid": {"_0": "Office"}}, "grace": 300}"#.utf8)
        let clause = try JSONDecoder().decode(ConditionClause.self, from: earlier)
        #expect(clause.timer == .graceFor(300))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clause)) as? [String: Any]
        #expect(saved?["grace"] == nil)
        #expect((saved?["duration"] as? [String: Any])?["grace"] as? Double == 300)
    }

    @Test func withoutHistoryGraceCannotBeTold() {
        let clause = ConditionClause(tbDock, grace: 5 * 60)
        #expect(clause.evaluate(undocked) == nil)
        #expect(clause.evaluate(docked) == true)
    }

    @Test func aClauseHasOneKindOfTimerAtATime() {
        var clause = ConditionClause(tbDock, duration: 60)
        clause.timer = .graceFor(300)
        #expect(clause.duration == nil && clause.grace == 300)
        clause.timer = .holdsFor(120)
        #expect(clause.duration == 120 && clause.grace == nil)
        clause.timer = nil
        #expect(clause.duration == nil && clause.grace == nil)
    }

    @Test func roundTripsDuration() throws {
        for clause in [ConditionClause(tbDock, isNegated: true, duration: 300), ConditionClause(tbDock, grace: 300)] {
            let decoded = try JSONDecoder().decode(ConditionClause.self, from: JSONEncoder().encode(clause))
            #expect(decoded == clause)
        }
        #expect(ConditionClause.label(forDuration: 90 * 60) == "1 h 30 min")
        #expect(ConditionClause.label(forDuration: 3600) == "1 hour")
    }
}

/// The two-profile setup from the timer's motivation: at the office desk on
/// the dock, or somewhere else on site without it. Unplugging for a few
/// minutes to show a coworker something shouldn't switch.
@Suite struct InBetweenTests {
    let tbDock = NetworkCondition.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM")
    let docked = NetworkSnapshot(connections: [dock], usbDevices: [
        USBDevice(name: "40AY", manufacturer: "Lenovo", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM"),
    ])
    let undocked = NetworkSnapshot(connections: [wifi])
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var fallback: Profile { Profile(name: "Default") }
    var office: Profile { Profile(name: "Office", conditions: [ConditionClause(tbDock)], priority: 2) }
    var onSite: Profile { Profile(name: "On Site", conditions: [ConditionClause(tbDock, isNegated: true, duration: 5 * 60)], priority: 1) }

    private func minutes(_ m: Double) -> Date { t0 + m * 60 }

    @Test func staysPutWhileTheTimerRuns() {
        let profiles = [fallback, office, onSite]
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))

        let during = ProfileMatcher.autoSwitch(for: undocked, in: profiles, current: office, history: history, at: minutes(12))
        #expect(during.profile?.name == "Office")
        #expect(during.pending?.profile.name == "On Site")
        #expect(during.pending?.at == minutes(15))

        let after = ProfileMatcher.autoSwitch(for: undocked, in: profiles, current: office, history: history, at: minutes(15))
        #expect(after.profile?.name == "On Site")
        #expect(after.pending == nil)
    }

    @Test func pluggingBackInCancelsTheSwitch() {
        let profiles = [fallback, office, onSite]
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        history.record(docked, at: minutes(13))
        let back = ProfileMatcher.autoSwitch(for: docked, in: profiles, current: office, history: history, at: minutes(16))
        #expect(back.profile?.name == "Office")
        #expect(back.pending == nil)
    }

    @Test func aHigherProfileThatMatchesNowIsNotHeldUp() {
        let home = Profile(name: "Home", conditions: [ConditionClause(.ssid("Home-WiFi"))], priority: 5)
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        let result = ProfileMatcher.autoSwitch(for: undocked, in: [fallback, office, onSite, home], current: office,
                                               history: history, at: minutes(11))
        #expect(result.profile?.name == "Home")
        #expect(result.pending == nil)  // On Site wouldn't outrank Home anyway
    }

    @Test func withNothingActiveThereIsNothingToHold() {
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        let result = ProfileMatcher.autoSwitch(for: undocked, in: [fallback, office, onSite], current: nil,
                                               history: history, at: minutes(11))
        #expect(result.profile?.name == "Default")
        #expect(result.pending?.profile.name == "On Site")
    }
}

/// The office profile from grace's motivation: on the dock at the desk,
/// with the fallback everywhere else, which can't carry a "not docked for
/// 5 min" timer. Restarting the dock shouldn't switch; docking should, at once.
@Suite struct GraceTests {
    let tbDock = NetworkCondition.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM")
    let docked = NetworkSnapshot(connections: [dock], usbDevices: [
        USBDevice(name: "40AY", manufacturer: "Lenovo", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM"),
    ])
    let undocked = NetworkSnapshot(connections: [wifi])
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var home: Profile { Profile(name: "Home") }
    var office: Profile { Profile(name: "A116", conditions: [ConditionClause(tbDock, grace: 5 * 60)], priority: 5) }

    private func minutes(_ m: Double) -> Date { t0 + m * 60 }

    @Test func staysThroughAShortBreak() {
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))

        let during = ProfileMatcher.autoSwitch(for: undocked, in: [home, office], current: office, history: history, at: minutes(12))
        #expect(during.profile?.name == "A116")
        #expect(during.pending?.profile.name == "Home")
        #expect(during.pending?.at == minutes(15))
        #expect(during.checkAt == minutes(15))

        let after = ProfileMatcher.autoSwitch(for: undocked, in: [home, office], current: office, history: history, at: minutes(15))
        #expect(after.profile?.name == "Home")
        #expect(after.pending == nil)
        #expect(after.checkAt == nil)
    }

    @Test func dockingAgainInTimeKeepsIt() {
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        history.record(docked, at: minutes(13))
        let back = ProfileMatcher.autoSwitch(for: docked, in: [home, office], current: office, history: history, at: minutes(13))
        #expect(back.profile?.name == "A116")
        #expect(back.pending == nil)
        #expect(back.checkAt == nil)
    }

    @Test func aGroupWhoseGraceRunsOutFirstDoesNotHoldUpASwitch() {
        // Undocking while joining Home-WiFi: "docked with grace and on
        // Home-WiFi for 10 min" can't match before the grace ends, so it
        // mustn't keep A116 in place of Home, which matches now.
        let both = Profile(name: "Both", conditions: [ConditionClause(tbDock, grace: 5 * 60),
                                                      ConditionClause(.ssid("Home-WiFi"), duration: 10 * 60)], priority: 9)
        let homeWiFi = Profile(name: "Home Wi-Fi", conditions: [ConditionClause(.ssid("Home-WiFi"))], priority: 1)
        let plainOffice = Profile(name: "A116", conditions: [ConditionClause(tbDock)], priority: 5)
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        let result = ProfileMatcher.autoSwitch(for: undocked, in: [both, plainOffice, homeWiFi], current: plainOffice,
                                               history: history, at: minutes(10))
        #expect(result.profile?.name == "Home Wi-Fi")
        #expect(result.pending == nil)
    }

    @Test func theMenuShowsWhatItWillReallyDo() {
        // Once the grace ends, the fallback would match, but "On Site"
        // outranks it and is only waiting on its timer: A116 stays until then.
        let onSite = Profile(name: "On Site", conditions: [ConditionClause(tbDock, isNegated: true, duration: 10 * 60)], priority: 3)
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        let result = ProfileMatcher.autoSwitch(for: undocked, in: [home, office, onSite], current: office,
                                               history: history, at: minutes(11))
        #expect(result.profile?.name == "A116")
        #expect(result.pending?.profile.name == "On Site")
        #expect(result.pending?.at == minutes(20))
        #expect(result.checkAt == minutes(15))
    }

    @Test func theMenuLooksPastAGraceThatChangesNothing() {
        // Two ways to be at the desk, each with its own grace. The first to
        // run out leaves the other, so the switch comes when that one does.
        let desk = Profile(name: "A116", conditions: [
            ConditionClause(tbDock, grace: 60),
            ConditionClause(.ethernetAdapter("USB 10/100/1000 LAN"), connector: .or, grace: 5 * 60),
        ], priority: 5)
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(undocked, at: minutes(10))
        let result = ProfileMatcher.autoSwitch(for: undocked, in: [home, desk], current: desk, history: history, at: minutes(10.5))
        #expect(result.profile?.name == "A116")
        #expect(result.pending?.profile.name == "Home")
        #expect(result.pending?.at == minutes(15))
        #expect(result.checkAt == minutes(11))
    }

    @Test func aChangeNotYetSettledCountsFromNowInTheForecast() {
        // Undocked a moment ago: the history only has the docked snapshot.
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        let result = ProfileMatcher.autoSwitch(for: undocked, in: [home, office], current: office, history: history, at: minutes(10))
        #expect(result.profile?.name == "A116")
        #expect(result.pending?.profile.name == "Home")
        #expect(result.pending?.at == minutes(15))
        #expect(result.checkAt == minutes(15))
    }

    @Test func dockingSwitchesRightAway() {
        var history = SnapshotHistory()
        history.record(undocked, at: t0)
        history.record(docked, at: minutes(10))
        let result = ProfileMatcher.autoSwitch(for: docked, in: [home, office], current: home, history: history, at: minutes(10))
        #expect(result.profile?.name == "A116")
    }
}

/// Offline, the current profile is kept for `ProfileMatcher.offlineGrace`
/// — Wi-Fi rejoining shouldn't quit and relaunch apps — but not for good:
/// undocked with Wi-Fi off, the dock's profile has to go.
@Suite struct OfflineTests {
    let docked = NetworkSnapshot(connections: [dock])
    let offline = NetworkSnapshot()
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let grace = ProfileMatcher.offlineGrace

    var desk: Profile { Profile(name: "Desk", conditions: [ConditionClause(.ethernetAdapter(dock.serviceName))], priority: 1) }
    var mobile: Profile { Profile(name: "Mobile") }

    /// Docked at launch, offline from 10 s in.
    private var unpluggedAtTen: SnapshotHistory {
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        history.record(offline, at: t0 + 10)
        return history
    }

    @Test func keepsTheProfileThroughABriefDrop() {
        let during = ProfileMatcher.autoSwitch(for: offline, in: [desk, mobile], current: desk, history: unpluggedAtTen, at: t0 + 30)
        #expect(during.profile?.name == "Desk")
        #expect(during.pending?.profile.name == "Mobile")
        #expect(during.pending?.at == t0 + 10 + grace)
        #expect(during.checkAt == t0 + 10 + grace)
    }

    @Test func switchesOnceOfflineForLonger() {
        let after = ProfileMatcher.autoSwitch(for: offline, in: [desk, mobile], current: desk, history: unpluggedAtTen,
                                              at: t0 + 10 + grace)
        #expect(after.profile?.name == "Mobile")
        #expect(after.pending == nil)
        #expect(after.checkAt == nil)
    }

    @Test func withoutAFallbackItStillChecksAgain() {
        let during = ProfileMatcher.autoSwitch(for: offline, in: [desk], current: desk, history: unpluggedAtTen, at: t0 + 30)
        #expect(during.profile?.name == "Desk")
        #expect(during.pending == nil)
        #expect(during.checkAt == t0 + 10 + grace)
        let after = ProfileMatcher.autoSwitch(for: offline, in: [desk], current: desk, history: unpluggedAtTen, at: t0 + 10 + grace)
        #expect(after.profile == nil)
    }

    @Test func aDropNotYetRecordedCountsFromNow() {
        // The live snapshot is ahead of the history while it settles.
        var history = SnapshotHistory()
        history.record(docked, at: t0)
        let result = ProfileMatcher.autoSwitch(for: offline, in: [desk, mobile], current: desk, history: history, at: t0 + 600)
        #expect(result.profile?.name == "Desk")
        #expect(result.checkAt == t0 + 600 + grace)
    }

    @Test func offlineSinceLaunchIsNotHeld() {
        // e.g. auto-switch turned back on, on a profile picked by hand.
        var history = SnapshotHistory()
        history.record(offline, at: t0)
        let result = ProfileMatcher.autoSwitch(for: offline, in: [desk, mobile], current: desk, history: history, at: t0 + 5)
        #expect(result.profile?.name == "Mobile")
    }

    @Test func beforeAnythingIsRecordedOfflineCountsAsLongStanding() {
        // Started offline with nothing plugged in, then auto-switch turned on:
        // waiting from "now" would wait again at every check.
        let result = ProfileMatcher.autoSwitch(for: offline, in: [desk, mobile], current: desk, history: SnapshotHistory(), at: t0)
        #expect(result.profile?.name == "Mobile")
        #expect(result.checkAt == nil)
    }

    @Test func nothingIsHeldWithNothingActive() {
        let result = ProfileMatcher.autoSwitch(for: offline, in: [desk, mobile], current: nil, history: unpluggedAtTen, at: t0 + 30)
        #expect(result.profile?.name == "Mobile")
        #expect(result.checkAt == nil)
    }
}

@Suite struct ShellWordsTests {
    let openRGB = URL(fileURLWithPath: "/Users/me/Applications/OpenRGB.app/Contents/MacOS/OpenRGB")
    let expected = ["--server", "--server-host", "127.0.0.1", "--server-port", "6742", "--profile", "Everyday - Midnight Teal"]

    @Test func takesAPastedCommandWithLineBreaks() {
        let pasted = #"""
            /Users/me/Applications/OpenRGB.app/Contents/MacOS/OpenRGB \
              --server \
              --server-host 127.0.0.1 \
              --server-port 6742 \
              --profile "Everyday - Midnight Teal"
            """#
        #expect(ShellWords.arguments(fromCommandLine: pasted, program: openRGB) == expected)
    }

    @Test func takesJustTheArguments() {
        let pasted = "--server --server-host 127.0.0.1 --server-port 6742 --profile 'Everyday - Midnight Teal'"
        #expect(ShellWords.arguments(fromCommandLine: pasted, program: openRGB) == expected)
        // The program by name, and with Windows line endings.
        #expect(ShellWords.arguments(fromCommandLine: "OpenRGB \\\r\n--server", program: openRGB) == ["--server"])
    }

    @Test func quotingRules() {
        #expect(ShellWords.split(#"--name="Bob's PC" a\ b '' "x\"y" 'c\d'"#) == ["--name=Bob's PC", "a b", "", "x\"y", "c\\d"])
        #expect(ShellWords.split("“smart quotes” ‘too’") == ["smart quotes", "too"])
        #expect(ShellWords.split("  ") == [])
        #expect(ShellWords.split(#"--profile "Everyday"#) == nil)
    }

    @Test func joinRoundTrips() {
        let words = expected + ["", "it's", #"a"b"#, "$HOME", "plain-word_1.2:3"]
        #expect(ShellWords.split(ShellWords.join(words)) == words)
        #expect(ShellWords.join(expected) == #"--server --server-host 127.0.0.1 --server-port 6742 --profile "Everyday - Midnight Teal""#)
    }
}

@Suite struct AppFoldersTests {
    @Test func storesFoldersWithTildeAndNoTrailingSlash() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AppFolders.normalize(" ~/Applications/ ") == "~/Applications")
        #expect(AppFolders.normalize("\(home)/Applications") == "~/Applications")
        #expect(AppFolders.normalize("/opt/bin/") == "/opt/bin")
        #expect(AppFolders.normalize("/opt/../usr/local/bin") == "/usr/local/bin")
    }

    @Test func applicationsBringsAppleAppsAlong() {
        let roots = AppFolders.scanRoots(["/Applications", "~/bin", "/Applications/"]).map(\.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(roots == ["/Applications", "/System/Applications", "\(home)/bin"])
    }

    @Test func acceptsOnlyFullPathsToFolders() {
        #expect(AppFolders.isFolder("/System"))
        #expect(AppFolders.isFolder(" ~ "))
        #expect(!AppFolders.isFolder(""))
        #expect(!AppFolders.isFolder("System"))           // relative
        #expect(!AppFolders.isFolder("/bin/sh"))          // a file
        #expect(!AppFolders.isFolder("/no/such/folder"))
    }
}

@Suite struct ProfileMatcherTests {
    let fallback = Profile(name: "Default")
    let home = Profile(name: "Home", conditions: [ConditionClause(.ssid("Home-WiFi"))], priority: 1)
    let homeDesk = Profile(name: "Home Desk", conditions: [ConditionClause(.ssid("Home-WiFi")), ConditionClause(.ethernetAdapter("USB 10/100/1000 LAN"))], priority: 2)

    @Test func highestPriorityMatchWins() {
        let profiles = [fallback, home, homeDesk]
        #expect(ProfileMatcher.bestMatch(for: NetworkSnapshot(connections: [dock, wifi]), in: profiles)?.name == "Home Desk")
        #expect(ProfileMatcher.bestMatch(for: NetworkSnapshot(connections: [wifi]), in: profiles)?.name == "Home")
    }

    @Test func fallsBackWhenNothingMatches() {
        let profiles = [fallback, home]
        #expect(ProfileMatcher.bestMatch(for: .empty, in: profiles)?.name == "Default")
        #expect(ProfileMatcher.bestMatch(for: .empty, in: [home]) == nil)
    }
}

@Suite struct BooleanLogicTests {
    let homeWiFi = NetworkCondition.ssid("Home-WiFi")
    let dockAdapter = NetworkCondition.ethernetAdapter("USB 10/100/1000 LAN")
    let corpDNS = NetworkCondition.dnsDomain("corp.example.com")

    private func profile(_ clauses: ConditionClause...) -> Profile {
        Profile(name: "Test", conditions: clauses)
    }

    @Test func andBindsTighterThanOr() {
        // Home-WiFi and dock or corp DNS  ==  (Home-WiFi and dock) or corp DNS
        let p = profile(ConditionClause(homeWiFi), ConditionClause(dockAdapter), ConditionClause(corpDNS, connector: .or))
        #expect(p.matches(NetworkSnapshot(connections: [dock, wifi])))             // first group
        #expect(p.matches(NetworkSnapshot(connections: [dock], dnsDomains: ["corp.example.com"])))  // second group
        #expect(!p.matches(NetworkSnapshot(connections: [wifi])))                  // Wi-Fi alone isn't enough
        #expect(p.conditionSummary == "(Wi-Fi Network “Home-WiFi” and Ethernet Adapter “USB 10/100/1000 LAN”) or DNS Domain “corp.example.com”")
    }

    @Test func notInvertsACondition() {
        let p = profile(ConditionClause(homeWiFi), ConditionClause(dockAdapter, isNegated: true))
        #expect(p.matches(NetworkSnapshot(connections: [wifi])))         // home, undocked
        #expect(!p.matches(NetworkSnapshot(connections: [dock, wifi])))  // home, docked
        #expect(p.conditionSummary == "Wi-Fi Network “Home-WiFi” and not Ethernet Adapter “USB 10/100/1000 LAN”")
    }

    @Test func connectorOnFirstClauseIsIgnored() {
        let p = profile(ConditionClause(homeWiFi, connector: .or), ConditionClause(dockAdapter))
        #expect(p.conditionGroups.count == 1)
        #expect(!p.matches(NetworkSnapshot(connections: [wifi])))
    }

    @Test func notOnAHiddenWiFiNameIsUnknownNotTrue() {
        var hidden = wifi
        hidden.ssid = nil  // connected, but no Location access
        let p = profile(ConditionClause(homeWiFi, isNegated: true))
        #expect(p.evaluate(NetworkSnapshot(connections: [hidden])) == nil)
        #expect(!p.matches(NetworkSnapshot(connections: [hidden])))
        // With no Wi-Fi connection at all we do know: not on Home-WiFi.
        #expect(p.matches(NetworkSnapshot(connections: [dock])))
    }

    @Test func unknownDoesNotBlockAnotherGroup() {
        var hidden = wifi
        hidden.ssid = nil
        let p = profile(ConditionClause(homeWiFi), ConditionClause(corpDNS, connector: .or))
        #expect(p.matches(NetworkSnapshot(connections: [hidden], dnsDomains: ["corp.example.com"])))
        #expect(p.evaluate(NetworkSnapshot(connections: [hidden])) == nil)
    }

    @Test func aPlaceWithoutANameIsLabelledByWhereItIs() {
        let unnamed = NetworkCondition.location(name: "", latitude: 40.610736, longitude: -74.262598, radiusMeters: 150)
        #expect(unnamed.valueLabel == "40.6107, -74.2626 (±150m)")
        #expect(ConditionClause(unnamed).summary == "Place “40.6107, -74.2626 (±150m)”")
        #expect(NetworkCondition.location(name: "Home", latitude: 0, longitude: 0, radiusMeters: 100).valueLabel == "Home (±100m)")
        // Matching never looked at the name.
        let here = NetworkSnapshot(location: SimpleLocation(latitude: 40.6108, longitude: -74.2626))
        #expect(unnamed.isSatisfied(by: here))
    }

    @Test func falseInAGroupOutweighsUnknown() {
        let place = NetworkCondition.location(name: "Home", latitude: 0, longitude: 0, radiusMeters: 100)
        let p = profile(ConditionClause(place), ConditionClause(dockAdapter))
        // No location fix (unknown) and not docked (false) → definitely false.
        #expect(p.evaluate(NetworkSnapshot(connections: [wifi])) == false)
    }
}

@Suite struct GroupEditingTests {
    private func names(_ p: Profile) -> [[String]] {
        p.conditionGroups.map { $0.map(\.condition.valueLabel) }
    }

    @Test func addsToTheEndOfAGroup() {
        var p = Profile(name: "T")
        p.addCondition(.dnsDomain("a"), toGroup: 0)   // empty profile → first group
        p.addCondition(.dnsDomain("b"), toGroup: 1)   // past the end → new "or" group
        p.addCondition(.dnsDomain("c"), toGroup: 0)   // into the first group, before "b"
        #expect(names(p) == [["a", "c"], ["b"]])
    }

    @Test func removingAGroupsFirstConditionKeepsTheGroup() {
        var p = Profile(name: "T")
        p.addCondition(.dnsDomain("a"), toGroup: 0)
        p.addCondition(.dnsDomain("b"), toGroup: 1)
        p.addCondition(.dnsDomain("c"), toGroup: 1)
        p.removeCondition(id: p.conditionGroups[1][0].id)
        #expect(names(p) == [["a"], ["c"]])
    }

    @Test func removingTheVeryFirstConditionKeepsLaterGroups() {
        var p = Profile(name: "T")
        p.addCondition(.dnsDomain("a"), toGroup: 0)
        p.addCondition(.dnsDomain("b"), toGroup: 0)
        p.addCondition(.dnsDomain("c"), toGroup: 1)
        p.removeCondition(id: p.conditions[0].id)
        #expect(names(p) == [["b"], ["c"]])
    }

    @Test func removingAOneConditionGroupDropsIt() {
        var p = Profile(name: "T")
        p.addCondition(.dnsDomain("a"), toGroup: 0)
        p.addCondition(.dnsDomain("b"), toGroup: 1)
        p.addCondition(.dnsDomain("c"), toGroup: 2)
        p.removeCondition(id: p.conditionGroups[1][0].id)
        #expect(names(p) == [["a"], ["c"]])
    }
}

@Suite struct PersistenceTests {
    /// The shape profiles.json had before executables and Ethernet support.
    @Test func decodesProfilesFromPreviousVersion() throws {
        let json = """
        [{"id":"C216A875-4681-4BB4-AE20-4DCE0C9DB2BA","name":"Alpharetta","priority":0,
          "appRules":[{"bundleIdentifier":"com.apple.calculator","displayName":"Calculator","action":"launch",
                       "id":"C9DC19CA-0CA3-42CF-9EFB-762D78A02DEB"}],
          "conditions":[{"gatewayIP":{"_0":"10.0.0.1"}}]}]
        """
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(json.utf8))
        let rule = try #require(profiles.first?.appRules.first)
        #expect(rule.bundleIdentifier == "com.apple.calculator")
        #expect(rule.path == nil)
        #expect(!rule.isExecutable)
        // Bare conditions from before boolean logic become plain "and" clauses.
        let clause = try #require(profiles.first?.conditions.first)
        #expect(clause.condition == .gatewayIP("10.0.0.1"))
        #expect(clause.connector == .and)
        #expect(!clause.isNegated)
    }

    @Test func roundTripsNewConditionsAndExecutables() throws {
        let profile = Profile(
            name: "Office",
            conditions: [
                ConditionClause(.wiredNetwork(name: "Office LAN", routerMAC: "00:1a:2b:3c:4d:5e")),
                ConditionClause(.ethernetAdapter("USB 10/100/1000 LAN"), isNegated: true),
                ConditionClause(.dnsDomain("corp.example.com"), connector: .or),
                ConditionClause(.usbDevice(name: "40AY", vendorID: 6127, productID: 12457, serialNumber: "1S40AY0090USZVV1ESKM")),
                ConditionClause(.usbDevice(name: "USB Receiver", vendorID: 1133, productID: 50475, serialNumber: nil)),
                ConditionClause(.display(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: nil), isNegated: true, duration: 600),
            ],
            appRules: [AppRule(bundleIdentifier: nil, path: "/usr/local/bin/sync-notes", displayName: "sync-notes", action: .launch,
                               arguments: ["--profile", "Everyday - Midnight Teal"]),
                       AppRule(bundleIdentifier: "com.yourcompany.OpenRGB", path: "/Users/me/Applications/OpenRGB.app",
                               displayName: "OpenRGB", action: .launch, arguments: ["--server"], runsDirectly: true,
                               relaunchesOnCrash: true)]
        )
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.appRules.first?.isExecutable == true)
    }

    @Test func appBundleWithoutBundleIDIsNotAnExecutable() {
        #expect(!AppRule(bundleIdentifier: nil, path: "/Applications/Odd.app", displayName: "Odd", action: .launch).isExecutable)
    }
}
