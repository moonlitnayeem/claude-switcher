import AppKit
import Combine
import SwiftUI

struct GraftConnectionView: View {
    private let connection = GraftConnection()
    @ObservedObject private var labels = ClaudeAccountLabels.graft
    @State private var labelTarget: ClaudeLabelTarget?
    @State private var usageTarget: ClaudeUsageTarget?
    @State private var usageReadings: [UUID: ClaudeUsageDisplay.Reading] = [:]
    @State private var snapshot = GraftConnection.Snapshot()
    @State private var loaded = false
    @State private var profile = "main"
    @State private var message: String?
    @State private var rechecking = false
    @State private var changingMode = false
    @State private var modeRevision = 0

    var body: some View {
        let key = snapshot.profiles.contains(profile) ? profile : "main"
        let status = snapshot.status
        let connected = status?.configured == true && status?.enabled == true
        let canSet = snapshot.canSetRoutingMode(for: key)
        let enabled = canSet && snapshot.exclusiveAccount(for: key) == nil
        RoutingPanel(data: display(profile: key), enabled: Binding(get: { enabled },
                     set: { setMode($0 ? nil : key, for: key) }), canSwitch: canSet && !changingMode,
                     refresh: refreshStatus, recheck: { member in recheck(member, profile: key) },
                     useOnly: { setMode($0, for: key) },
                     renameAccount: { id in labelTarget = ClaudeLabelTarget(id: id, name: accountName(id, profile: key)) },
                     updateUsage: { id in
                         guard let account = snapshot.accountUUIDs[id] else { return }
                         usageTarget = ClaudeUsageTarget(id: account, profile: key, member: id,
                                                       name: accountName(id, profile: key))
                     },
                     launchControls: key == "main" ? ClaudeLaunchControls() : nil) {
            if snapshot.profiles.count > 1 {
                Picker("Claude profile", selection: Binding(get: { key }, set: { profile = $0 })) {
                    ForEach(snapshot.profiles, id: \.self) { id in Text(profileName(id)).tag(id) }
                }.fixedSize().identified("routing.profile")
            } else { Label(profileName(key), systemImage: "laptopcomputer").font(.callout) }
        } accountActions: {
            Button("Manage in Graft") { openGraft() }.identified("routing.manage-graft")
        } manage: {
            Label("Connected through Graft", systemImage: "link")
                .foregroundStyle(.secondary).opacity(connected ? 1 : 0)
        }
        .task {
            while !Task.isCancelled {
                let revision = modeRevision
                let (next, readings) = await readStatusAndUsage()
                guard !Task.isCancelled else { return }
                if revision == modeRevision && !changingMode {
                    snapshot = next
                    usageReadings = readings
                    loaded = true
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        .sheet(item: $labelTarget) { target in
            ClaudeAccountLabelEditor(id: target.id, accountName: target.name, labels: labels)
        }
        .sheet(item: $usageTarget) { target in
            ClaudeUsageEditor(accountName: target.name) { values in
                try await Task.detached(priority: .userInitiated) {
                    let current = connection.read()
                    guard current.accountUUIDs[target.member] == target.id,
                          current.accounts(for: target.profile).members.contains(target.member) else {
                        throw ClaudeUsageEditorError.accountChanged
                    }
                    if let values { try ClaudeUsageDisplay.save(values, account: target.id) }
                    else { try ClaudeUsageDisplay.clear(account: target.id) }
                }.value
                modeRevision += 1
                _ = await refreshStatus()
            }
        }
        .alert("Graft connection", isPresented: Binding(get: { message != nil },
                                                        set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func profileName(_ id: String) -> String {
        if id == "main" { return L10n.text("Main Claude profile") }
        return snapshot.names[id] ?? L10n.text("Claude profile")
    }

    private func accountName(_ id: String, profile: String) -> String {
        if let email = snapshot.email(for: id, from: profile) { return email }
        if let name = snapshot.names[id] { return name }
        if id == profile || id == "main" { return profileName(id) }
        if let index = snapshot.accounts(for: profile).members.firstIndex(of: id) {
            return L10n.format("Backup %ld", index)
        }
        return L10n.text("Previously connected account")
    }

    private func display(profile: String) -> RoutingDisplay {
        let accounts = snapshot.accounts(for: profile)
        let backupIDs = accounts.members.dropFirst()
        let status = snapshot.status
        let now = Date()
        let rows = accounts.members.map { id -> RoutingAccountDisplay in
            let report = snapshot.report(for: id, from: profile)
            let limits = report?.limits
            let identity = snapshot.accountUUIDs[id]
            let usage = identity.flatMap { usageReadings[$0] }
            let name = accountName(id, profile: profile)
            let state: String
            if report?.tokenRefused == true { state = "Sign in again" }
            else if usage?.weekly?.percent == 100 { state = "Weekly limit reached" }
            else if report?.lastServed != nil { state = "Has answered requests" }
            else { state = "Saved in Graft" }
            var row = RoutingAccountDisplay(id: id, name: name, isPrimary: id == profile,
                                            state: L10n.text(state),
                                            weekly: usage?.weekly.map(RoutingUsageMetric.init),
                                            fable: usage?.fable.map(RoutingUsageMetric.init),
                                            canUpdateUsage: identity != nil)
            row.nickname = labels.nickname(for: id)
            row.canSelect = snapshot.canSelectAccount(id, for: profile)
            row.needsAttention = report?.tokenRefused == true || usage?.weekly?.percent == 100
            if let reset = limits?.fableRefusedUntil, reset > now { row.fableReset = reset }
            row.canRecheck = !rechecking && snapshot.canRecheck(id, from: profile)
            row.recheckPending = report?.fableRecheckPending == true
            return row
        }
        let history = (status?.recent ?? []).filter { $0.from == profile }
        let success = history.last { (200..<300).contains($0.status) }
        let title: String
        let detail: String
        let ready = status?.configured == true && status?.enabled == true && !backupIDs.isEmpty
        if !loaded {
            title = "Checking your connection"
            detail = "Looking for the Graft setup on this Mac."
        } else if status == nil {
            title = "Waiting for Graft"
            detail = "Open Graft to use your saved accounts. This screen will reconnect by itself."
        } else if !snapshot.settingsFound {
            title = "Waiting for account settings"
            detail = "Open Graft to check which accounts can answer for this profile."
        } else if !ready {
            title = "Switching is off"
            detail = "Use Manage in Graft to choose the accounts for this profile."
        } else if let last = history.last, (200..<300).contains(last.status),
                  backupIDs.contains(accounts.canonical(last.servedBy)), let session = last.session,
                  let choice = snapshot.chatChoices[session], accounts.canonical(choice) == accounts.canonical(last.servedBy) {
            title = "Your backup answered"
            detail = rows.first?.weekly?.percent == 100
                ? "Your main account is full. This chat has a saved backup choice in Graft."
                : "This chat is set to use its backup account in Graft."
        } else if rows.first?.weekly?.percent == 100 {
            title = "Your main account is full"
            detail = "Graft can send eligible requests to a backup. See which account answered below."
        } else {
            title = "Your accounts are connected"
            detail = "Graft handles requests for this profile. This map shows which account answered."
        }
        var data = RoutingDisplay(title: L10n.text(title), detail: L10n.text(detail), ready: ready,
                                  accounts: rows, lastAccount: success.map { accountName(accounts.canonical($0.servedBy), profile: profile) },
                                  lastModel: success?.model.map(RoutingDashboard.modelName), lastAnswered: success?.at)
        data.externallyManaged = true
        if status?.savedChoiceUnreadable == true {
            data.savedChoiceUnreadable = true
            data.routingControlHint = L10n.text("Account controls are unavailable for this connection.")
        } else if snapshot.canSetRoutingMode(for: profile) {
            data.exclusiveAccount = snapshot.exclusiveAccount(for: profile)
        } else if status == nil {
            data.routingControlHint = L10n.text("Open Graft to change which account answers.")
        } else if !snapshot.settingsFound || status?.configured != true || status?.enabled != true || status?.exclusiveAccounts != nil {
            data.routingControlHint = L10n.text("Connect this profile in Graft to change accounts here.")
        } else {
            data.routingControlHint = L10n.text("Your version of Graft can show activity but can’t change accounts here.")
        }
        data.readRecentLimits(history)
        if let last = history.last {
            let ok = (200..<300).contains(last.status)
            data.route = RouteMapSignal(phase: ok ? .answered : .failed, backup: accounts.canonical(last.servedBy) != profile,
                                        model: last.model.map(RoutingDashboard.modelName), at: last.at)
            if !ok && !data.showsRateLimit(for: last) { data.latestFailure = L10n.format("Request returned HTTP %ld", last.status) }
        }
        return data
    }

    private func setMode(_ account: String?, for profile: String) {
        guard !changingMode, snapshot.canSetRoutingMode(for: profile) else { return }
        changingMode = true
        modeRevision += 1
        Task {
            defer {
                modeRevision += 1
                changingMode = false
            }
            do {
                snapshot = try await Task.detached(priority: .userInitiated) {
                    try connection.setExclusiveAccount(account, for: profile)
                }.value
            } catch {
                let reason = error.localizedDescription
                snapshot = await Task.detached(priority: .utility) { connection.read() }.value
                message = reason
            }
        }
    }

    private func readStatusAndUsage() async -> (GraftConnection.Snapshot, [UUID: ClaudeUsageDisplay.Reading]) {
        await Task.detached(priority: .utility) {
            let next = connection.read()
            let now = Date()
            let observed = ClaudeUsageDisplay.graftReadings(at: connection.root.appending(path: "usage-status.json"), now: now)
            let readings = Dictionary(uniqueKeysWithValues: Set(next.accountUUIDs.values).map { account in
                let relayWeekly = Self.relayWeeklyMetric(for: account, in: next, now: now)
                return (account, ClaudeUsageDisplay.load(account: account, relayWeekly: relayWeekly,
                                                         graftReading: observed[account], now: now))
            })
            return (next, readings)
        }.value
    }

    nonisolated private static func relayWeeklyMetric(for account: UUID, in snapshot: GraftConnection.Snapshot,
                                                      now: Date) -> ClaudeUsageDisplay.Metric? {
        guard let members = snapshot.status?.members else { return nil }
        let matchingIDs = Set(snapshot.accountUUIDs.compactMap { $0.value == account ? $0.key : nil })
        var freshest: ClaudeUsageDisplay.Metric?
        for report in members where matchingIDs.contains(report.id) {
            guard let limits = report.limits, (limits.weekReset ?? .distantFuture) > now else { continue }
            let percent = Int((limits.week * 100).rounded())
            guard (0...100).contains(percent) else { continue }
            let candidate = ClaudeUsageDisplay.Metric(percent: percent, observedAt: limits.observed, source: .relay)
            if freshest == nil || candidate.observedAt > freshest!.observedAt { freshest = candidate }
        }
        return freshest
    }

    @MainActor
    private func refreshStatus() async -> Bool {
        let revision = modeRevision
        let (fresh, readings) = await readStatusAndUsage()
        if revision == modeRevision && !changingMode {
            modeRevision += 1
            snapshot = fresh
            usageReadings = readings
            loaded = true
        }
        return fresh.status != nil
    }

    private func recheck(_ member: String, profile: String) {
        guard !rechecking else { return }
        rechecking = true
        Task {
            let queued = await Task.detached(priority: .utility) {
                (try? connection.recheck(member, from: profile)) == true
            }.value
            _ = await refreshStatus()
            rechecking = false
            if !queued {
                message = L10n.text("The relay could not queue this Fable check. Refresh to see the latest account status.")
            }
        }
    }

    private func openGraft() {
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: "graft.claude-graft") else {
            message = L10n.text("Claude Graft needs to be installed to use this connection.")
            return
        }
        workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { message = L10n.text("Graft could not be opened.") } }
        }
    }
}

/// Continuity mode has no reason to start the native menu's profile and keychain observers.
@MainActor final class GraftConnectionMenuBar: NSObject {
    private var item: NSStatusItem?
    private var preference: AnyCancellable?
    private let openWindow: () -> Void

    init(settings: AppSettings, openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
        super.init()
        preference = settings.$showInMenuBar.sink { [weak self] shown in self?.show(shown) }
    }

    var isShowing: Bool { item?.isVisible == true }
    private func show(_ visible: Bool) {
        if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
        guard visible else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                                     accessibilityDescription: "AI Switcher")
        item.button?.toolTip = "AI Switcher"
        let menu = NSMenu()
        for (name, action) in [("Open AI Switcher", #selector(open)), ("Quit AI Switcher", #selector(quit))] {
            let row = menu.addItem(withTitle: L10n.text(name), action: action, keyEquivalent: "")
            row.target = self
        }
        item.menu = menu
        self.item = item
    }
    @objc private func open() { openWindow() }
    @objc private func quit() { AppDelegate.quit() }
}
