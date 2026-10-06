import Foundation

/// How `ContextSwitch --switch` / `--profile` hand their work to a running
/// menu bar app, so its menu, active profile and settings stay in sync.
/// Distributed notifications carry a request and the matching reply; both
/// are posted with deliverImmediately, since AppKit otherwise holds them
/// for apps that aren't frontmost — and a menu bar app never is.
enum RemoteCommand {
    static let requestName = Notification.Name("com.contextswitch.command.request")
    static let replyName = Notification.Name("com.contextswitch.command.reply")

    struct Request {
        let id: String
        /// nil = switch to the profile that matches the current network.
        let profileName: String?
        /// The profiles file the sender uses; an app using a different one
        /// (e.g. a CONTEXTSWITCH_PROFILES sandbox) ignores the request.
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

    struct Reply {
        let id: String
        let status: Int32
        let output: String

        var userInfo: [String: String] { ["id": id, "status": String(status), "output": output] }

        init(id: String, status: Int32, output: String) {
            self.id = id
            self.status = status
            self.output = output
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"],
                  let status = info["status"].flatMap(Int32.init) else { return nil }
            self.init(id: id, status: status, output: info["output"] ?? "")
        }
    }

    static func post(_ name: Notification.Name, userInfo: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: userInfo, deliverImmediately: true)
    }
}
