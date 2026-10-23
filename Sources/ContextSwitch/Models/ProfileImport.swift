import Foundation

/// Profiles read from a file to import: an export, or a profiles.json
/// (see `ProfileStore.readImport`).
struct ProfileImport {
    var profiles: [Profile]
    /// Left out: saved by a newer version, or mistyped by hand.
    var unreadable: [ProfileStore.UnreadableProfile] = []

    /// What importing does to your profiles.
    struct Merge {
        /// Yours, with the imported ones in.
        var profiles: [Profile]
        /// The imported profiles as they end up, in the file's order.
        var imported: [Profile] = []
        /// Yours that imported ones replaced, as they were, by the ID they keep.
        var replaced: [Profile.ID: Profile] = [:]
    }

    /// For each imported profile, the one of `existing` it matches, if any:
    /// the one with its ID (it was exported from it, say), or else one with
    /// its name. Each matches one imported profile at most.
    func matches(in existing: [Profile]) -> [Profile?] {
        var claimed = Set<Profile.ID>()
        var matches: [Profile?] = profiles.map { imported in
            guard let mine = existing.first(where: { $0.id == imported.id }), claimed.insert(mine.id).inserted else { return nil }
            return mine
        }
        for index in profiles.indices where matches[index] == nil {
            if let mine = existing.filter({ !claimed.contains($0.id) }).profile(named: profiles[index].name) {
                claimed.insert(mine.id)
                matches[index] = mine
            }
        }
        return matches
    }

    /// `existing` with the imported profiles in. One that matches one of
    /// yours (see `matches`) replaces it if `replacing`, keeping its ID and
    /// place; the others are added, with new IDs if theirs are taken (or
    /// `reserved`, e.g. by profiles that couldn't be read). Each is renamed
    /// (e.g. "Office 2") if its name is taken: by a profile it doesn't
    /// replace, or an imported one before it, replacements first.
    func merged(into existing: [Profile], replacing: Bool, reserving reserved: Set<Profile.ID> = []) -> Merge {
        var merge = Merge(profiles: existing)
        var results = profiles
        var added = Array(profiles.indices)
        if replacing {
            for (index, mine) in matches(in: existing).enumerated() {
                guard let mine else { continue }
                results[index].id = mine.id
                merge.replaced[mine.id] = mine
                added.removeAll { $0 == index }
            }
        }
        // The names of the profiles replaced are free.
        var taken = existing.filter { merge.replaced[$0.id] == nil }
        for index in results.indices where !added.contains(index) {
            results[index].name = taken.uniqueName(for: results[index].name)
            taken.append(results[index])
        }
        for index in added {
            if reserved.contains(results[index].id) || taken.contains(where: { $0.id == results[index].id }) {
                results[index] = results[index].withNewIDs()
            }
            results[index].name = taken.uniqueName(for: results[index].name)
            taken.append(results[index])
        }
        let replacements = Dictionary(results.indices.filter { !added.contains($0) }.map { (results[$0].id, results[$0]) },
                                      uniquingKeysWith: { first, _ in first })
        merge.profiles = existing.map { replacements[$0.id] ?? $0 } + added.map { results[$0] }
        merge.imported = results
        return merge
    }
}
