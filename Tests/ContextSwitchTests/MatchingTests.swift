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
                ConditionClause(.display(name: "LG ULTRAWIDE", vendorID: 7789, modelID: 30625, serialNumber: nil), isNegated: true),
            ],
            appRules: [AppRule(bundleIdentifier: nil, path: "/usr/local/bin/sync-notes", displayName: "sync-notes", action: .launch)]
        )
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.appRules.first?.isExecutable == true)
    }

    @Test func appBundleWithoutBundleIDIsNotAnExecutable() {
        #expect(!AppRule(bundleIdentifier: nil, path: "/Applications/Odd.app", displayName: "Odd", action: .launch).isExecutable)
    }
}
