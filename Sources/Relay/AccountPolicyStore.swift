import Foundation

/// The relay owns these restrictions. Membership, permission to lend and
/// credentials still come exclusively from its existing configuration.
struct AccountPolicyStore {
    struct Selection: Codable, Equatable {
        let member: String
        let profileAccount: String
        let memberAccount: String
    }

    private let file: URL
    private(set) var selections: [String: Selection] = [:]
    private(set) var readError: String?

    init(directory: URL) {
        file = directory.appending(path: "account-policy.json")
        do {
            let data = try Data(contentsOf: file)
            let saved = try JSONDecoder().decode([String: Selection].self, from: data)
            guard saved.allSatisfy({ profile, choice in
                [profile, choice.member, choice.profileAccount, choice.memberAccount].allSatisfy(Self.validID)
            }) else { throw CocoaError(.fileReadCorruptFile) }
            selections = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A relay that has never received a restriction starts in Automatic.
        } catch {
            readError = "The relay could not read its saved account choices. Model requests are paused."
        }
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 &&
            value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }

    mutating func save(_ selection: Selection?, for profile: String) -> String? {
        if let readError { return readError }
        var updated = selections
        updated[profile] = selection
        do {
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            selections = updated
            return nil
        } catch {
            return "The relay could not save that choice. Your previous choice is still in effect."
        }
    }
}
