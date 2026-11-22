import AppKit
import Foundation

/// Manages saved backup accounts and lender lists inside an existing Graft directory
/// (`~/Library/Application Support/ClaudeGraft`), allowing unlimited Claude accounts
/// to be signed in, attached, detached, or forgotten directly from AI Switcher.
struct GraftAccountInventory {
    struct StoredCandidate: Identifiable, Equatable {
        let id: String
        let label: String
    }

    let root: URL

    init(root: URL = Graft.applicationSupport.appending(path: Graft.legacyFolderName)) {
        self.root = root
    }

    var accountsURL: URL { root.appending(path: "pool/accounts.json") }
    var sharingURL: URL { root.appending(path: "usage-sharing.json") }

    func readAccounts() -> [PoolAccount] {
        guard let data = try? Data(contentsOf: accountsURL),
              let decoded = try? JSONDecoder().decode([PoolAccount].self, from: data) else {
            return []
        }
        return decoded
    }

    func readSharing() -> UsageSharing {
        guard let data = try? Data(contentsOf: sharingURL),
              let decoded = try? JSONDecoder().decode(UsageSharing.self, from: data) else {
            return UsageSharing()
        }
        return decoded
    }

    func availableToAttach(for profile: String, snapshot: GraftConnection.Snapshot) -> [StoredCandidate] {
        let current = Set([profile] + (snapshot.lenders[profile] ?? []))
        let accounts = readAccounts()
        let takenUUIDs = Set(current.compactMap { snapshot.accountUUIDs[$0]?.uuidString.lowercased() })
        var items: [StoredCandidate] = []
        for account in accounts where !current.contains(account.id) {
            if let uuid = account.accountUuid?.lowercased(), takenUUIDs.contains(uuid) { continue }
            items.append(StoredCandidate(id: account.id, label: account.email ?? account.id))
        }
        for (shortcutID, name) in snapshot.names.sorted(by: { $0.value < $1.value })
        where shortcutID != profile && !current.contains(shortcutID) {
            if let uuid = snapshot.accountUUIDs[shortcutID]?.uuidString.lowercased(), takenUUIDs.contains(uuid) {
                continue
            }
            items.append(StoredCandidate(id: shortcutID, label: name))
        }
        return items
    }

    func unusedAccounts() -> [PoolAccount] {
        let sharing = readSharing()
        let linked = Set(sharing.lenders.values.flatMap { $0 })
        return readAccounts().filter { !linked.contains($0.id) }
    }

    @discardableResult
    func saveSignedInAccount(_ incoming: PoolAccount, attachTo profile: String) throws -> PoolAccount {
        Graft.enterStateLock()
        defer { Graft.leaveStateLock() }

        var accounts = readAccounts()
        var stored = incoming
        if let uuid = incoming.accountUuid?.lowercased(),
           let existingIndex = accounts.firstIndex(where: { $0.accountUuid?.lowercased() == uuid }) {
            stored.id = accounts[existingIndex].id
            stored.iconPreset = accounts[existingIndex].iconPreset
            accounts[existingIndex] = stored
        } else {
            stored.iconPreset = Shortcut.IconPreset.next(besides: accounts.compactMap(\.iconPreset))
            accounts.append(stored)
        }
        try UsagePool.writePrivate(JSONEncoder().encode(accounts), to: accountsURL)

        var sharing = readSharing()
        var lenders = sharing.lenders[profile] ?? []
        if !lenders.contains(stored.id), stored.id != profile {
            lenders.append(stored.id)
            sharing.lenders[profile] = lenders
            try UsagePool.writePrivate(JSONEncoder().encode(sharing), to: sharingURL)
        }
        return stored
    }

    func attachExisting(_ memberID: String, to profile: String) throws {
        guard memberID != profile else { return }
        Graft.enterStateLock()
        defer { Graft.leaveStateLock() }

        var sharing = readSharing()
        var lenders = sharing.lenders[profile] ?? []
        guard !lenders.contains(memberID) else { return }
        lenders.append(memberID)
        sharing.lenders[profile] = lenders
        try UsagePool.writePrivate(JSONEncoder().encode(sharing), to: sharingURL)
    }

    func detach(_ memberID: String, from profile: String) throws {
        guard memberID != profile else { return }
        Graft.enterStateLock()
        defer { Graft.leaveStateLock() }

        var sharing = readSharing()
        guard var lenders = sharing.lenders[profile], lenders.contains(memberID) else { return }
        lenders.removeAll { $0 == memberID }
        sharing.lenders[profile] = lenders.isEmpty ? nil : lenders
        try UsagePool.writePrivate(JSONEncoder().encode(sharing), to: sharingURL)
    }

    func forgetUnused(_ accountID: String) throws {
        Graft.enterStateLock()
        defer { Graft.leaveStateLock() }

        let sharing = readSharing()
        let linked = Set(sharing.lenders.values.flatMap { $0 })
        guard !linked.contains(accountID) else { return }
        let remaining = readAccounts().filter { $0.id != accountID }
        try UsagePool.writePrivate(JSONEncoder().encode(remaining), to: accountsURL)
    }

    /// Quietly restarts only the Claude Graft menu-bar controller (never touching
    /// `graft-relay` or `Claude.app`) so Graft reloads `accounts.json` and
    /// `usage-sharing.json` and pushes the updated account pool to the running relay.
    @MainActor
    static func reloadGraftControllerIfRunning() async {
        let bundleID = "graft.claude-graft"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let appURL = running.first?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return
        }
        if !running.isEmpty {
            for instance in running {
                _ = instance.terminate()
            }
            for _ in 0..<30 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        try? await Task.sleep(nanoseconds: 600_000_000)
    }
}
