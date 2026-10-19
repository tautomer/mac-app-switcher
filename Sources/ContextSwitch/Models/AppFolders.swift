import Foundation

/// The folders the "add app" picker lists apps and executables from, kept
/// as the user sees them, e.g. "~/Applications" or "/opt/bin".
enum AppFolders {
    static let defaults = ["/Applications"]

    /// How a folder is stored and shown: "~" for the home folder, no
    /// trailing slash.
    static func normalize(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return (URL(fileURLWithPath: expanded).standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    static func url(for folder: String) -> URL {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// An existing folder, given by a full path or one starting with "~".
    static func isFolder(_ path: String) -> Bool {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        return (path.hasPrefix("/") || path.hasPrefix("~"))
            && FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The folders to scan, de-duplicated. "/Applications" brings
    /// "/System/Applications" with it: Finder shows Apple's own apps
    /// (Calculator, Notes…) in /Applications, but they live there.
    static func scanRoots(_ folders: [String]) -> [URL] {
        var seen = Set<String>()
        return folders.flatMap { folder -> [URL] in
            let url = url(for: folder)
            return url.path == "/Applications" ? [url, URL(fileURLWithPath: "/System/Applications")] : [url]
        }
        .filter { seen.insert($0.path).inserted }
    }
}
