import Foundation

/// Graft keeps ownership of the already-connected profiles. This reader only needs
/// its profile lists, assigned account labels and the socket used by its own dashboard.
struct GraftConnection {
    static let preference = "UseExistingGraftConnection"
    static let isEnabled = UserDefaults.standard.bool(forKey: preference)

    struct Profile: Decodable {
        let id: UUID
        let name: String
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
        var chatChoices: [String: String] = [:]
        var status: PoolStatus?
        var settingsFound = false

        var profiles: [String] {
            ["main"] + lenders.keys.filter { $0 != "main" }.sorted {
                (names[$0] ?? $0).localizedStandardCompare(names[$1] ?? $1) == .orderedAscending
            }
        }

        func canRecheck(_ member: String, from profile: String, now: Date = Date()) -> Bool {
            guard let status, status.configured, status.enabled, member != profile,
                  lenders[profile]?.contains(member) == true,
                  let report = status.members.first(where: { $0.id == member }),
                  !report.tokenRefused, report.fableRecheckPending != true,
                  let limits = report.limits, let until = limits.fableRefusedUntil, until > now
            else { return false }
            return PoolPolicy.hasRoom(limits, now: now)
        }
    }

    let root: URL
    init(root: URL = Graft.applicationSupport.appending(path: Graft.legacyFolderName)) {
        self.root = root
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
            result.accountLabels = GraftAccountLabel.assigned(in: root, ids: Set(decoded.lenders.values.joined()))
        }
        if let shortcuts = try? Data(contentsOf: root.appending(path: "shortcuts.json")),
           let profiles = try? JSONDecoder().decode([Profile].self, from: shortcuts) {
            for profile in profiles { result.names[profile.id.uuidString] = profile.name }
        }
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
