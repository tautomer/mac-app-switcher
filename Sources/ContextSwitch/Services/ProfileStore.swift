import Foundation
import Combine

/// Persists profiles as JSON under
/// ~/Library/Application Support/ContextSwitch/profiles.json
final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ContextSwitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profiles.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else {
            profiles = ProfileStore.defaultProfiles()
            save()
            return
        }
        profiles = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    private static func defaultProfiles() -> [Profile] {
        [Profile(name: "Default", conditions: [], appRules: [], priority: 0)]
    }
}
