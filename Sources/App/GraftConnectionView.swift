import AppKit
import Combine
import SwiftUI

struct GraftConnectionView: View {
    private let connection = GraftConnection()
    @ObservedObject private var labels = ClaudeAccountLabels.graft
    @State private var labelTarget: ClaudeLabelTarget?
    @State private var snapshot = GraftConnection.Snapshot()
    @State private var loaded = false
    @State private var profile = "main"
    @State private var message: String?
    @State private var rechecking = false

    var body: some View {
        let key = snapshot.profiles.contains(profile) ? profile : "main"
        let status = snapshot.status
        let enabled = status?.configured == true && status?.enabled == true && !(snapshot.lenders[key] ?? []).isEmpty
        RoutingPanel(data: display(profile: key), enabled: .constant(enabled), canSwitch: false,
                     recheck: { member in recheck(member, profile: key) },
                     renameAccount: { id in labelTarget = ClaudeLabelTarget(id: id, name: accountName(id, profile: key)) }) {
            if snapshot.profiles.count > 1 {
                Picker("Claude profile", selection: Binding(get: { key }, set: { profile = $0 })) {
                    ForEach(snapshot.profiles, id: \.self) { id in Text(profileName(id)).tag(id) }
                }.fixedSize().identified("routing.profile")
            } else { Label(profileName(key), systemImage: "laptopcomputer").font(.callout) }
        } accountActions: {
            Button("Manage in Graft") { openGraft() }.identified("routing.manage-graft")
        } manage: {
            Label("Connected through Graft", systemImage: "link")
                .foregroundStyle(.secondary).opacity(enabled ? 1 : 0)
        }
        .task {
            while !Task.isCancelled {
                let next = await Task.detached(priority: .utility) { connection.read() }.value
                guard !Task.isCancelled else { return }
                snapshot = next
                loaded = true
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        .sheet(item: $labelTarget) { target in
            ClaudeAccountLabelEditor(id: target.id, accountName: target.name, labels: labels)
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
        if snapshot.lenders[profile]?.contains(id) == true, let email = snapshot.accountLabels[id] { return email }
        if let name = snapshot.names[id] { return name }
        if id == profile || id == "main" { return profileName(id) }
        if let index = snapshot.lenders[profile]?.firstIndex(of: id) {
            return L10n.format("Backup %ld", index + 1)
        }
        return L10n.text("Previously connected account")
    }

    private func display(profile: String) -> RoutingDisplay {
        let backupIDs = (snapshot.lenders[profile] ?? []).filter { $0 != profile }
        let status = snapshot.status
        let now = Date()
        let rows = ([profile] + backupIDs).map { id -> RoutingAccountDisplay in
            let report = status?.members.first { $0.id == id }
            let limits = report?.limits
            let weekIsCurrent = limits.map { ($0.weekReset ?? .distantFuture) > now } ?? false
            let week = weekIsCurrent ? limits.map { Int((min(1, max(0, $0.week)) * 100).rounded(.down)) } : nil
            let name = accountName(id, profile: profile)
            let state: String
            if report?.tokenRefused == true { state = "Sign in again" }
            else if week == 100 { state = "Weekly limit reached" }
            else if report?.lastServed != nil { state = "Has answered requests" }
            else { state = "Saved in Graft" }
            var row = RoutingAccountDisplay(id: id, name: name, isPrimary: id == profile,
                                            state: L10n.text(state), weeklyUsed: week)
            row.nickname = labels.nickname(for: id)
            row.needsAttention = report?.tokenRefused == true || week == 100
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
                  backupIDs.contains(last.servedBy), let session = last.session,
                  snapshot.chatChoices[session] == last.servedBy {
            title = "Your backup answered"
            detail = rows.first?.weeklyUsed == 100
                ? "Your main account is full. This chat has a saved backup choice in Graft."
                : "This chat is set to use its backup account in Graft."
        } else if rows.first?.weeklyUsed == 100 {
            title = "Your main account is full"
            detail = "Graft can send eligible requests to a backup. See which account answered below."
        } else {
            title = "Your accounts are connected"
            detail = "Graft handles requests for this profile. This map shows which account answered."
        }
        var data = RoutingDisplay(title: L10n.text(title), detail: L10n.text(detail), ready: ready,
                                  accounts: rows, lastAccount: success.map { accountName($0.servedBy, profile: profile) },
                                  lastModel: success?.model.map(RoutingDashboard.modelName), lastAnswered: success?.at)
        data.externallyManaged = true
        if let last = history.last {
            let ok = (200..<300).contains(last.status)
            data.route = RouteMapSignal(phase: ok ? .answered : .failed, backup: last.servedBy != profile,
                                        model: last.model.map(RoutingDashboard.modelName), at: last.at)
            if !ok { data.latestFailure = L10n.format("Request returned HTTP %ld", last.status) }
        }
        return data
    }

    private func recheck(_ member: String, profile: String) {
        guard !rechecking else { return }
        rechecking = true
        Task {
            let queued = await Task.detached(priority: .utility) {
                (try? connection.recheck(member, from: profile)) == true
            }.value
            rechecking = false
            if !queued { message = L10n.text("Graft could not queue that check. Refresh the account in Graft.") }
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
