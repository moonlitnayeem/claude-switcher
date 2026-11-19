import Foundation

struct Query: Decodable {
    let root: String
    let candidates: [String]
    let expected: String?
}

struct ShortcutProfile: Decodable {
    let id: UUID
    let folder: String?
}

struct Candidate: Encodable {
    let canonical: String
    let labelMatches: Bool?
}

let query = try JSONDecoder().decode(Query.self, from: FileHandle.standardInput.readDataToEndOfFile())
let root = URL(fileURLWithPath: query.root, isDirectory: true)
let support = root.deletingLastPathComponent()
let entries = GraftAccountLabel.assignedEntries(in: root, ids: Set(query.candidates))
var identities = [String: UUID]()
for entry in entries { identities[entry.id] = entry.accountUuid }
identities["main"] = GraftAccountLabel.profileAccount(in: support.appending(path: "Claude"))

let shortcuts = root.appending(path: "shortcuts.json")
if let data = try? Data(contentsOf: shortcuts),
   let profiles = try? JSONDecoder().decode([ShortcutProfile].self, from: data) {
    for id in query.candidates {
        guard let key = UUID(uuidString: id), let folder = profiles.first(where: { $0.id == key })?.folder,
              !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("/"), !folder.contains(":") else { continue }
        let profile = support.appending(path: folder).resolvingSymlinksInPath()
        guard profile.deletingLastPathComponent().path == support.resolvingSymlinksInPath().path else { continue }
        identities[id] = GraftAccountLabel.profileAccount(in: profile)
    }
}
let accounts = RoutingAccountIdentity(primary: "main", lenders: query.candidates, accountUUIDs: identities)
var matches = [String: Bool]()
if let expected = query.expected {
    for entry in entries {
        guard let email = entry.email, !email.isEmpty else { continue }
        let key = accounts.canonical(entry.id)
        matches[key] = matches[key] == true || email.caseInsensitiveCompare(expected) == .orderedSame
    }
}
let answers = query.candidates.map { id in
    let key = accounts.canonical(id)
    return Candidate(canonical: key, labelMatches: matches[key])
}
FileHandle.standardOutput.write(try JSONEncoder().encode(answers))
