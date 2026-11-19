import Foundation

/// The inventory belongs to Graft. Only display labels for accounts currently
/// assigned as backups leave this projection. Its credential fields have no model here.
struct GraftAccountLabel: Decodable {
    let id: String
    let email: String?

    static func assigned(in root: URL, ids: Set<String>) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let file = root.appending(path: "pool/accounts.json")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let labels = try? JSONDecoder().decode([Self].self, from: data) else { return [:] }
        var assigned: [String: String] = [:]
        for label in labels where ids.contains(label.id) {
            if let email = label.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                assigned[label.id] = email
            }
        }
        return assigned
    }
}
