import Foundation

enum AccountControlError: LocalizedError {
    case unavailable, invalidAccount, unconfirmed

    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("Account controls are unavailable for this connection.")
        case .invalidAccount: return L10n.text("This account is no longer on the list for this profile.")
        case .unconfirmed: return L10n.text("The connection could not confirm your account choice. Check the current setting and try again.")
        }
    }
}

extension PoolStatus {
    func canSetAccountPolicy(for profile: String) -> Bool {
        configured && enabled && exclusiveAccounts != nil &&
            (members.contains { $0.id == profile } || exclusiveAccounts?[profile] != nil)
    }

    func confirmAccountPolicy(_ member: String?, for profile: String) throws {
        guard canSetAccountPolicy(for: profile), accountPolicyError == nil,
              exclusiveAccounts?[profile] == member else { throw AccountControlError.unconfirmed }
    }
}

/// Graft owns this connection. A change takes effect only if its running helper acknowledges it.
struct GraftConnection {
    static let preference = "UseExistingGraftConnection"
    static let isEnabled = UserDefaults.standard.bool(forKey: preference)

    struct Profile: Decodable {
        let id: UUID
        let name: String
        let installedName: String?
        let folder: String?
    }

    struct ShortcutProfile: Equatable {
        let id: String
        let name: String
        let installedName: String?
        let folder: String
        let accountUUID: UUID?
        let appURL: URL
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
        var shortcutProfiles: [ShortcutProfile] = []
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

        func canSetRoutingMode(for profile: String) -> Bool {
            settingsFound && profiles.contains(profile) && status?.canSetAccountPolicy(for: profile) == true
        }

        func selectableMember(_ id: String, for profile: String) -> String? {
            let accounts = accounts(for: profile)
            let row = accounts.canonical(id)
            guard canSetRoutingMode(for: profile), accounts.members.contains(row) else { return nil }
            guard let eligible = status?.selectableAccounts else { return row }
            return eligible[profile]?.first { accounts.canonical($0) == row }
        }

        func canSelectAccount(_ id: String, for profile: String) -> Bool {
            selectableMember(id, for: profile) != nil
        }

        func exclusiveAccount(for profile: String) -> String? {
            status?.exclusiveAccounts?[profile].map { accounts(for: profile).canonical($0) }
        }

        func email(for id: String, from profile: String) -> String? {
            let ids = [profile] + (lenders[profile] ?? [])
            guard ids.contains(id) else { return nil }
            if let email = accountLabels[id] { return email }
            guard let uuid = accountUUIDs[id] else { return nil }
            return ids.lazy.filter { accountUUIDs[$0] == uuid }.compactMap { accountLabels[$0] }.first
        }

        func report(for member: String, from profile: String) -> PoolMemberStatus? {
            let handle = selectableMember(member, for: profile) ?? member
            return status?.members.first { $0.id == handle }
        }

        /// Older Graft helpers report the usage readings but give no reason for declining a recheck.
        func recheckFeedback(for member: String, from profile: String, declined: Bool = false, now: Date = Date()) -> String? {
            guard let status, status.configured, status.enabled, member != profile,
                  accounts(for: profile).members.dropFirst().contains(member),
                  let report = report(for: member, from: profile), !report.tokenRefused,
                  report.fableRecheckPending != true, let limits = report.limits else { return nil }
            if !PoolPolicy.hasRoom(limits, now: now) {
                return L10n.text("Graft reports an account-wide limit. Each model can also have its own limit.")
            }
            if limits.week >= PoolPolicy.weekCeiling, (limits.weekReset ?? .distantFuture) > now {
                return L10n.text(declined
                    ? "Graft may skip a check when overall weekly use reaches 99%. Fable has a separate allowance."
                    : "At least 99% of this account’s weekly usage is spent. Each model can also have its own limit.")
            }
            if limits.fiveHour >= PoolPolicy.fiveHourCeiling, (limits.fiveHourReset ?? .distantFuture) > now {
                return L10n.text(declined
                    ? "Graft may skip a check when overall five-hour use reaches 98%. Fable has a separate allowance."
                    : "At least 98% of this account’s five-hour usage is spent. Each model can also have its own limit.")
            }
            return nil
        }

        func canRecheck(_ member: String, from profile: String, now: Date = Date()) -> Bool {
            guard let status, status.configured, status.enabled, member != profile,
                  accounts(for: profile).members.dropFirst().contains(member),
                  status.selectableAccounts == nil || selectableMember(member, for: profile) != nil,
                  let report = report(for: member, from: profile),
                  !report.tokenRefused, report.fableRecheckPending != true,
                  let limits = report.limits, let until = limits.fableRefusedUntil, until > now
            else { return false }
            return PoolPolicy.hasRoom(limits, now: now)
        }

        func chatShortcut(for member: String, from profile: String) -> ShortcutProfile? {
            guard member != profile else { return nil }
            let candidates = shortcutProfiles.filter { $0.id != profile }
            if let direct = candidates.first(where: { $0.id == member }) { return direct }
            if let uuid = accountUUIDs[member],
               let matched = candidates.first(where: { $0.accountUUID == uuid }) {
                return matched
            }
            if let email = email(for: member, from: profile)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !email.isEmpty,
               let byName = candidates.first(where: {
                   $0.accountUUID == nil &&
                   ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email ||
                    $0.installedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email)
               }) {
                return byName
            }
            return nil
        }

        func chatProfileApp(for member: String, from profile: String) -> URL? {
            chatShortcut(for: member, from: profile)?.appURL
        }
    }

    let root: URL
    let profileRoot: URL
    let appDirectories: [URL]
    init(root: URL = Graft.applicationSupport.appending(path: Graft.legacyFolderName),
         profileRoot: URL? = nil,
         appDirectories: [URL]? = nil) {
        self.root = root
        self.profileRoot = profileRoot ?? root.deletingLastPathComponent()
        self.appDirectories = appDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
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
                guard let folder = profile.folder, Graft.validateFolder(folder) == nil else { continue }
                let directory = profileRoot.appending(path: folder).resolvingSymlinksInPath()
                guard Graft.samePath(directory.deletingLastPathComponent(), profileRoot) else { continue }
                let accountUUID = GraftAccountLabel.profileAccount(in: directory)
                if referenced.contains(key) { result.accountUUIDs[key] = accountUUID }
                if let appURL = installedApp(for: profile, profileDirectory: directory) {
                    result.shortcutProfiles.append(ShortcutProfile(
                        id: key, name: profile.name, installedName: profile.installedName,
                        folder: folder, accountUUID: accountUUID, appURL: appURL
                    ))
                }
            }
        }
        let knownFolders = Set(result.shortcutProfiles.map(\.folder))
        for discovered in discoveredShortcutBundles(excludingFolders: knownFolders) {
            result.shortcutProfiles.append(discovered)
        }
        result.accountUUIDs["main"] = GraftAccountLabel.profileAccount(in: profileRoot.appending(path: "Claude"))
        result.status = try? send(PoolCommand())
        return result
    }

    private func discoveredShortcutBundles(excludingFolders: Set<String>) -> [ShortcutProfile] {
        let fm = FileManager.default
        var seenFolders = excludingFolders
        var found: [ShortcutProfile] = []
        for directory in appDirectories {
            guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for bundle in items.sorted(by: { $0.path < $1.path }) where bundle.pathExtension == "app" {
                guard let target = bundleProfileDirectory(bundle)?.resolvingSymlinksInPath(),
                      Graft.samePath(target.deletingLastPathComponent(), profileRoot) else { continue }
                let folder = target.lastPathComponent
                guard folder != "Claude", Graft.validateFolder(folder) == nil,
                      seenFolders.insert(folder).inserted else { continue }
                let baseName = bundle.deletingPathExtension().lastPathComponent
                let accountUUID = GraftAccountLabel.profileAccount(in: target)
                found.append(ShortcutProfile(id: "bundle:\(folder)", name: baseName,
                                             installedName: baseName, folder: folder,
                                             accountUUID: accountUUID, appURL: bundle))
            }
        }
        return found
    }

    private func bundleProfileDirectory(_ bundle: URL) -> URL? {
        let resources = bundle.appending(path: "Contents/Resources")
        for filename in ["graft.json", "switcher.json"] {
            let file = resources.appending(path: filename)
            guard let data = try? Data(contentsOf: file),
                  let config = try? JSONDecoder().decode(GraftConfig.self, from: data) else { continue }
            return URL(fileURLWithPath: config.profileDir)
        }
        return nil
    }

    private func installedApp(for profile: Profile, profileDirectory: URL) -> URL? {
        let names = [profile.installedName, profile.name].compactMap { $0 }.filter { !$0.isEmpty }
        for directory in appDirectories {
            for name in names {
                let candidate = directory.appending(path: "\(name).app")
                if describesProfile(candidate, profileDirectory) { return candidate }
            }
        }
        let fm = FileManager.default
        for directory in appDirectories {
            guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            if let found = items.sorted(by: { $0.path < $1.path })
                .first(where: { describesProfile($0, profileDirectory) }) {
                return found
            }
        }
        return nil
    }

    private func describesProfile(_ bundle: URL, _ expectedProfile: URL) -> Bool {
        guard bundle.pathExtension == "app" else { return false }
        let resources = bundle.appending(path: "Contents/Resources")
        for filename in ["graft.json", "switcher.json"] {
            let file = resources.appending(path: filename)
            guard let data = try? Data(contentsOf: file),
                  let config = try? JSONDecoder().decode(GraftConfig.self, from: data) else { continue }
            if Graft.samePath(URL(fileURLWithPath: config.profileDir), expectedProfile) { return true }
        }
        return false
    }

    func recheck(_ member: String, from profile: String) throws -> Bool {
        let snapshot = read()
        guard snapshot.canRecheck(member, from: profile),
              let report = snapshot.report(for: member, from: profile) else { return false }
        let updated = try send(PoolCommand(recheckFable: report.id))
        return updated.members.first(where: { $0.id == report.id })?.fableRecheckPending == true
    }

    func setExclusiveAccount(_ member: String?, for profile: String) throws -> Snapshot {
        var snapshot = read()
        guard snapshot.canSetRoutingMode(for: profile) else { throw AccountControlError.unavailable }
        let selected = member.flatMap { snapshot.selectableMember($0, for: profile) }
        if member != nil && selected == nil { throw AccountControlError.invalidAccount }
        let change = PoolAccountPolicyChange(profile: profile, mode: selected == nil ? .automatic : .only, member: selected)
        let updated = try send(PoolCommand(accountPolicy: change))
        try updated.confirmAccountPolicy(selected, for: profile)
        snapshot.status = updated
        return snapshot
    }

    private func send(_ command: PoolCommand) throws -> PoolStatus {
        let socket = root.appending(path: "pool/relay.sock")
        return try PoolSocket.send(command, to: socket.path, timeout: 2)
    }
}
