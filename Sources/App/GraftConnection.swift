import Foundation

/// Graft keeps ownership of the already-connected profiles. This reader only needs
/// its assigned accounts, the desktop profiles’ public account IDs and the status socket.
struct GraftConnection {
    static let preference = "UseExistingGraftConnection"
    static let isEnabled = UserDefaults.standard.bool(forKey: preference)

    struct Profile: Decodable {
        let id: UUID
        let name: String
        let folder: String?
    }

    struct Assignments: Decodable {
        struct Choice: Decodable { let to: String }
        let lenders: [String: [String]]
        let assignments: [String: Choice]?
    }

    struct Snapshot {
        var lenders: [String: [String]] = [:]
        var names: [String: String] = [:]
        var accountLabels: [String: String] = [:]
        var accountUUIDs: [String: UUID] = [:]
        var chatChoices: [String: String] = [:]
        var status: PoolStatus?
        var settingsFound = false

        var profiles: [String] {
            ["main"] + lenders.keys.filter { $0 != "main" }.sorted {
                (names[$0] ?? $0).localizedStandardCompare(names[$1] ?? $1) == .orderedAscending
            }
        }

        func accounts(for profile: String) -> RoutingAccountIdentity {
            RoutingAccountIdentity(primary: profile, lenders: lenders[profile] ?? [], accountUUIDs: accountUUIDs)
        }

        func email(for id: String, from profile: String) -> String? {
            let ids = [profile] + (lenders[profile] ?? [])
            guard ids.contains(id) else { return nil }
            if let email = accountLabels[id] { return email }
            guard let uuid = accountUUIDs[id] else { return nil }
            return ids.lazy.filter { accountUUIDs[$0] == uuid }.compactMap { accountLabels[$0] }.first
        }

        func canRecheck(_ member: String, from profile: String, now: Date = Date()) -> Bool {
            guard let status, status.configured, status.enabled, member != profile,
                  accounts(for: profile).members.dropFirst().contains(member),
                  let report = status.members.first(where: { $0.id == member }),
                  !report.tokenRefused, report.fableRecheckPending != true,
                  let limits = report.limits, let until = limits.fableRefusedUntil, until > now
            else { return false }
            return PoolPolicy.hasRoom(limits, now: now)
        }
    }

    let root: URL
    let profileRoot: URL
    init(root: URL = Graft.applicationSupport.appending(path: Graft.legacyFolderName), profileRoot: URL? = nil) {
        self.root = root
        self.profileRoot = profileRoot ?? root.deletingLastPathComponent()
    }

    var settingsExist: Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "usage-sharing.json").path)
    }

    func read() -> Snapshot {
        var result = Snapshot()
        if let saved = try? Data(contentsOf: root.appending(path: "usage-sharing.json")),
           let decoded = try? JSONDecoder().decode(Assignments.self, from: saved) {
            result.lenders = decoded.lenders
            result.chatChoices = decoded.assignments?.mapValues(\.to) ?? [:]
            result.settingsFound = true
            let assigned = Set(decoded.lenders.values.joined())
            for item in GraftAccountLabel.assignedEntries(in: root, ids: assigned) {
                result.accountLabels[item.id] = item.email
                result.accountUUIDs[item.id] = item.accountUuid
            }
        }
        let referenced = Set(result.lenders.keys).union(result.lenders.values.joined())
        if let shortcuts = try? Data(contentsOf: root.appending(path: "shortcuts.json")),
           let profiles = try? JSONDecoder().decode([Profile].self, from: shortcuts) {
            for profile in profiles {
                let key = profile.id.uuidString
                result.names[key] = profile.name
                guard referenced.contains(key), let folder = profile.folder, Graft.validateFolder(folder) == nil else { continue }
                let directory = profileRoot.appending(path: folder).resolvingSymlinksInPath()
                guard Graft.samePath(directory.deletingLastPathComponent(), profileRoot) else { continue }
                result.accountUUIDs[key] = GraftAccountLabel.profileAccount(in: directory)
            }
        }
        result.accountUUIDs["main"] = GraftAccountLabel.profileAccount(in: profileRoot.appending(path: "Claude"))
        result.status = try? send(PoolCommand())
        return result
    }

    func recheck(_ member: String, from profile: String) throws -> Bool {
        guard read().canRecheck(member, from: profile) else { return false }
        let updated = try send(PoolCommand(recheckFable: member))
        return updated.members.first(where: { $0.id == member })?.fableRecheckPending == true
    }

    private func send(_ command: PoolCommand) throws -> PoolStatus {
        let socket = root.appending(path: "pool/relay.sock")
        return try PoolSocket.send(command, to: socket.path, timeout: 2)
    }
}
