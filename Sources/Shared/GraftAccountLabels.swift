import Foundation

/// Only assigned display names and provider identity belong in the dashboard's inventory.
struct GraftAccountLabel: Decodable {
    let id: String
    let email: String?
    let accountUuid: UUID?

    enum CodingKeys: String, CodingKey { case id, email, accountUuid }

    init(from decoder: Decoder) throws {
        let entry = try decoder.container(keyedBy: CodingKeys.self)
        id = try entry.decode(String.self, forKey: .id)
        let address = (try? entry.decode(String.self, forKey: .email))?.trimmingCharacters(in: .whitespacesAndNewlines)
        email = address?.isEmpty == false ? address : nil
        accountUuid = try? entry.decode(UUID.self, forKey: .accountUuid)
    }

    static func assignedEntries(in root: URL, ids: Set<String>) -> [Self] {
        guard !ids.isEmpty else { return [] }
        let file = root.appending(path: "pool/accounts.json")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let labels = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return labels.filter { ids.contains($0.id) }
    }

    static func profileAccount(in profile: URL) -> UUID? {
        struct Identity: Decodable { let lastKnownAccountUuid: UUID? }
        let config = profile.appending(path: "config.json")
        guard let data = try? Data(contentsOf: config, options: .mappedIfSafe),
              let identity = try? JSONDecoder().decode(Identity.self, from: data) else { return nil }
        return identity.lastKnownAccountUuid
    }
}

/// Graft reports routing handles. Several handles can spend one provider account's allowance.
struct RoutingAccountIdentity {
    private(set) var members: [String] = []
    private var aliases: [String: String] = [:]

    init(primary: String, lenders: [String], accountUUIDs: [String: UUID]) {
        var known: [UUID: String] = [:]
        for id in [primary] + lenders where aliases[id] == nil {
            if let uuid = accountUUIDs[id], let existing = known[uuid] {
                aliases[id] = existing
                continue
            }
            members.append(id)
            aliases[id] = id
            if let uuid = accountUUIDs[id] { known[uuid] = id }
        }
    }

    func canonical(_ id: String) -> String { aliases[id] ?? id }
}
