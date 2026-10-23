import Foundation

/// How `ContextSwitch --switch` / `--profile` / `--import` hand their work
/// to a running menu bar app, so its menu, active profile and settings stay
/// in sync — and its profiles: it saves them all with every change, over
/// any change made to the file under it. Distributed notifications carry a
/// request and the matching reply; both are posted with deliverImmediately,
/// since AppKit otherwise holds them for apps that aren't frontmost — and a
/// menu bar app never is. An app using other profiles replies that it
/// ignores the request.
enum RemoteCommand {
    static let requestName = Notification.Name("com.contextswitch.command.request")
    /// Not `requestName`, which a version without `--import` would take
    /// for `--switch`.
    static let importRequestName = Notification.Name("com.contextswitch.command.import")
    static let replyName = Notification.Name("com.contextswitch.command.reply")

    /// How long the command line waits for a reply.
    static let replyTimeout: TimeInterval = 5
    /// An import request older than this is dropped, so it can't be taken
    /// on after the command line has given up and said nothing was
    /// imported. Short of `replyTimeout`, to leave time for the reply.
    static let importExpiry: TimeInterval = 3
    /// How long the command line waits for the outcome of an import the app
    /// has taken on (see `Reply.Kind.accepted`), e.g. while a save is slow.
    static let acceptedTimeout: TimeInterval = 30

    struct Request {
        let id: String
        /// nil = switch to the profile that matches right now.
        let profileName: String?
        /// The profiles file the sender uses; an app using a different one
        /// (e.g. a CONTEXTSWITCH_PROFILES sandbox) ignores the request (see
        /// `ProfileStore.isProfilesFile`).
        let profilesPath: String

        var userInfo: [String: String] {
            var info = ["id": id, "profilesPath": profilesPath]
            info["profile"] = profileName
            return info
        }

        init(id: String = UUID().uuidString, profileName: String?, profilesPath: String) {
            self.id = id
            self.profileName = profileName
            self.profilesPath = profilesPath
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"], let path = info["profilesPath"] else { return nil }
            self.init(id: id, profileName: info["profile"], profilesPath: path)
        }
    }

    struct ImportRequest {
        let id: String
        let profilesPath: String
        /// For messages and the log.
        let fileName: String
        /// The file, as read: the command line has checked it already.
        let contents: Data
        let onMatch: CommandLineCommand.OnMatch
        let sentAt: Date

        var userInfo: [String: String] {
            ["id": id, "profilesPath": profilesPath, "fileName": fileName,
             "contents": contents.base64EncodedString(), "onMatch": onMatch.rawValue,
             "sentAt": String(sentAt.timeIntervalSince1970)]
        }

        init(id: String = UUID().uuidString, profilesPath: String, fileName: String, contents: Data,
             onMatch: CommandLineCommand.OnMatch, sentAt: Date = Date()) {
            self.id = id
            self.profilesPath = profilesPath
            self.fileName = fileName
            self.contents = contents
            self.onMatch = onMatch
            self.sentAt = sentAt
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"], let path = info["profilesPath"],
                  let contents = info["contents"].flatMap({ Data(base64Encoded: $0) }),
                  let onMatch = info["onMatch"].flatMap(CommandLineCommand.OnMatch.init(rawValue:)),
                  let sentAt = info["sentAt"].flatMap(TimeInterval.init)
            else { return nil }
            self.init(id: id, profilesPath: path, fileName: info["fileName"] ?? "the file", contents: contents,
                      onMatch: onMatch, sentAt: Date(timeIntervalSince1970: sentAt))
        }

        /// Too old to carry out (see `importExpiry`). The wall clock, as it
        /// keeps counting while the Mac sleeps, like the command line's wait.
        func isExpired(at now: Date) -> Bool {
            now.timeIntervalSince(sentAt) >= RemoteCommand.importExpiry
        }
    }

    struct Reply {
        enum Kind: String {
            case answer
            /// From an app using other profiles.
            case ignored
            /// An import, taken on: the answer follows.
            case accepted
        }

        let id: String
        let kind: Kind
        /// For an answer.
        let status: Int32
        let output: String

        /// Only an answer has a status: a version without the other kinds
        /// would take one for the answer.
        var userInfo: [String: String] {
            kind == .answer ? ["id": id, "status": String(status), "output": output] : ["id": id, kind.rawValue: "true"]
        }

        init(id: String, status: Int32, output: String) {
            self.id = id
            kind = .answer
            self.status = status
            self.output = output
        }

        init(ignoring id: String) {
            self.init(id: id, kind: .ignored)
        }

        init(accepting id: String) {
            self.init(id: id, kind: .accepted)
        }

        private init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
            status = 0
            output = ""
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"] else { return nil }
            if let kind = [Kind.ignored, .accepted].first(where: { info[$0.rawValue] == "true" }) {
                self.init(id: id, kind: kind)
                return
            }
            guard let status = info["status"].flatMap(Int32.init) else { return nil }
            self.init(id: id, status: status, output: info["output"] ?? "")
        }
    }

    static func post(_ name: Notification.Name, userInfo: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: userInfo, deliverImmediately: true)
    }
}
