import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let switcherOpenBackupSignIn = Notification.Name("com.moonlitnayeem.claude-switcher.openBackupSignIn")
}

struct GraftConnectionView: View {
    private let connection = GraftConnection()
    @ObservedObject private var labels = ClaudeAccountLabels.graft
    @State private var labelTarget: ClaudeLabelTarget?
    @State private var usageTarget: ClaudeUsageTarget?
    @State private var signInTarget: BackupSignInTarget?
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
        let currentDisplay = display(profile: key)
        RoutingPanel(data: currentDisplay, enabled: Binding(get: { enabled },
                     set: { setMode($0 ? nil : key, for: key) }), canSwitch: canSet && !changingMode,
                     refresh: refreshStatus, recheck: { member in recheck(member, profile: key) },
                     useOnly: { setMode($0, for: key) },
                     openChatProfile: { openBackupChatProfile($0, profile: key) },
                     signInChatProfile: { startBackupSignIn($0, profile: key) },
                     createChatProfile: { createBackupChatProfile($0, profile: key) },
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
                let (next, readings) = await Self.fetchStatusAndUsage(using: connection)
                guard !Task.isCancelled else { return }
                if revision == modeRevision && !changingMode {
                    snapshot = next
                    usageReadings = readings
                    loaded = true
                    UsageAlertNotifier.shared.observe(display(profile: key).accounts)
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switcherOpenBackupSignIn)) { note in
            if let memberID = note.object as? String {
                startBackupSignIn(memberID, profile: key)
            }
        }
        .sheet(item: $labelTarget) { target in
            ClaudeAccountLabelEditor(id: target.id, accountName: target.name, labels: labels)
        }
        .sheet(item: $signInTarget) { target in
            BackupProfileSignInSheet(target: target) {
                Task { _ = await refreshStatus() }
            }
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
        let hasLauncher = Bundle.main.url(forResource: "graft-launch", withExtension: nil) != nil
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
            row.session = usage?.session.map(RoutingUsageMetric.init)
            row.nickname = labels.nickname(for: id)
            row.canSelect = snapshot.canSelectAccount(id, for: profile)
            if let shortcut = snapshot.chatShortcut(for: id, from: profile) {
                row.canOpenChatProfile = true
                row.chatProfileSignedIn = shortcut.accountUUID != nil
            } else if id != profile {
                row.canCreateChatProfile = hasLauncher
            }
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
        data.populateActivityFeed(history, canonical: accounts.canonical, accountName: { id in
            labels.nickname(for: id) ?? accountName(id, profile: profile)
        })
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

    nonisolated fileprivate static func fetchStatusAndUsage(
        using connection: GraftConnection
    ) async -> (GraftConnection.Snapshot, [UUID: ClaudeUsageDisplay.Reading]) {
        await Task.detached(priority: .utility) {
            let next = connection.read()
            let now = Date()
            let observed = ClaudeUsageDisplay.graftReadings(at: connection.root.appending(path: "usage-status.json"), now: now)
            let readings = Dictionary(uniqueKeysWithValues: Set(next.accountUUIDs.values).map { account in
                let relaySession = Self.relaySessionMetric(for: account, in: next, now: now)
                let relayWeekly = Self.relayWeeklyMetric(for: account, in: next, now: now)
                let relayFable = Self.relayFableMetric(for: account, in: next, now: now)
                return (account, ClaudeUsageDisplay.load(account: account,
                                                         relaySession: relaySession,
                                                         relayWeekly: relayWeekly,
                                                         relayFable: relayFable,
                                                         graftReading: observed[account], now: now))
            })
            return (next, readings)
        }.value
    }

    nonisolated fileprivate static func relaySessionMetric(for account: UUID, in snapshot: GraftConnection.Snapshot,
                                                           now: Date) -> ClaudeUsageDisplay.Metric? {
        guard let members = snapshot.status?.members else { return nil }
        let matchingIDs = Set(snapshot.accountUUIDs.compactMap { $0.value == account ? $0.key : nil })
        var freshest: ClaudeUsageDisplay.Metric?
        for report in members where matchingIDs.contains(report.id) {
            guard let limits = report.limits, (limits.fiveHourReset ?? .distantFuture) > now else { continue }
            let percent = Int((limits.fiveHour * 100).rounded())
            guard (0...100).contains(percent) else { continue }
            let candidate = ClaudeUsageDisplay.Metric(percent: percent, observedAt: limits.observed,
                                                      source: .relay, resetAt: limits.fiveHourReset)
            if freshest == nil || candidate.observedAt > freshest!.observedAt { freshest = candidate }
        }
        return freshest
    }

    nonisolated fileprivate static func relayWeeklyMetric(for account: UUID, in snapshot: GraftConnection.Snapshot,
                                                          now: Date) -> ClaudeUsageDisplay.Metric? {
        guard let members = snapshot.status?.members else { return nil }
        let matchingIDs = Set(snapshot.accountUUIDs.compactMap { $0.value == account ? $0.key : nil })
        var freshest: ClaudeUsageDisplay.Metric?
        for report in members where matchingIDs.contains(report.id) {
            guard let limits = report.limits, (limits.weekReset ?? .distantFuture) > now else { continue }
            let percent = Int((limits.week * 100).rounded())
            guard (0...100).contains(percent) else { continue }
            let candidate = ClaudeUsageDisplay.Metric(percent: percent, observedAt: limits.observed,
                                                      source: .relay, resetAt: limits.weekReset)
            if freshest == nil || candidate.observedAt > freshest!.observedAt { freshest = candidate }
        }
        return freshest
    }

    nonisolated fileprivate static func relayFableMetric(for account: UUID, in snapshot: GraftConnection.Snapshot,
                                                         now: Date) -> ClaudeUsageDisplay.Metric? {
        guard let members = snapshot.status?.members else { return nil }
        let matchingIDs = Set(snapshot.accountUUIDs.compactMap { $0.value == account ? $0.key : nil })
        var freshest: ClaudeUsageDisplay.Metric?
        for report in members where matchingIDs.contains(report.id) {
            let reset = report.limits?.fableReset ?? report.limits?.weekReset
            guard let limits = report.limits, let fable = limits.fable,
                  (reset ?? .distantFuture) > now else { continue }
            let percent = Int((fable * 100).rounded())
            guard (0...100).contains(percent) else { continue }
            let observedAt = limits.fableObserved ?? limits.observed
            let candidate = ClaudeUsageDisplay.Metric(percent: percent, observedAt: observedAt,
                                                      source: .relay, resetAt: reset)
            if freshest == nil || candidate.observedAt > freshest!.observedAt { freshest = candidate }
        }
        return freshest
    }

    @MainActor
    private func refreshStatus() async -> Bool {
        let revision = modeRevision
        let (fresh, readings) = await Self.fetchStatusAndUsage(using: connection)
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

    private func openBackupChatProfile(_ id: String, profile: String) {
        guard let app = snapshot.chatProfileApp(for: id, from: profile) else {
            message = L10n.text("No installed Claude profile was found for this backup account.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    message = L10n.text("The backup Claude profile could not be opened.")
                }
            }
        }
    }

    private func startBackupSignIn(_ id: String, profile: String) {
        guard let shortcut = snapshot.chatShortcut(for: id, from: profile) else {
            message = L10n.text("No installed Claude profile was found for this backup account.")
            return
        }
        let profileDir = connection.profileRoot.appending(path: shortcut.folder)
        signInTarget = BackupSignInTarget(id: id, accountName: accountName(id, profile: profile),
                                          appURL: shortcut.appURL, profileDir: profileDir)
    }

    private func createBackupChatProfile(_ id: String, profile: String) {
        let displayName = accountName(id, profile: profile)
        do {
            let created = try BackupProfileManager.createProfileBundle(
                accountName: displayName,
                profileRoot: connection.profileRoot
            )
            Task {
                _ = await refreshStatus()
                signInTarget = BackupSignInTarget(id: id, accountName: displayName,
                                                  appURL: created.appURL, profileDir: created.profileDir)
            }
        } catch {
            message = error.localizedDescription
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

/// Live status bar HUD for Graft-connected mode: displays real-time usage, reset countdowns,
/// routing mode switches, and one-click launchers without needing to open the main window.
@MainActor final class GraftConnectionMenuBar: NSObject, NSMenuDelegate {
    private static let badgePreference = "MenuBarShowLiveFablePercent"

    private let connection = GraftConnection()
    private var item: NSStatusItem?
    private var preference: AnyCancellable?
    private var pollTask: Task<Void, Never>?
    private var snapshot = GraftConnection.Snapshot()
    private var usageReadings: [UUID: ClaudeUsageDisplay.Reading] = [:]
    private let openWindow: () -> Void

    init(settings: AppSettings, openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
        super.init()
        if UserDefaults.standard.object(forKey: Self.badgePreference) == nil {
            UserDefaults.standard.set(true, forKey: Self.badgePreference)
        }
        preference = settings.$showInMenuBar.sink { [weak self] shown in self?.show(shown) }
    }

    var isShowing: Bool { item?.isVisible == true }

    private var showBadge: Bool {
        get { UserDefaults.standard.bool(forKey: Self.badgePreference) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.badgePreference)
            updateButtonBadge()
        }
    }

    private func show(_ visible: Bool) {
        pollTask?.cancel()
        pollTask = nil
        if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
        guard visible else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                                     accessibilityDescription: "AI Switcher")
        item.button?.imagePosition = .imageOnly
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.toolTip = "AI Switcher"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        rebuildMenu(menu)
        startPolling()
    }

    private func startPolling() {
        let conn = connection
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let (next, readings) = await GraftConnectionView.fetchStatusAndUsage(using: conn)
                guard !Task.isCancelled, let self else { return }
                self.snapshot = next
                self.usageReadings = readings
                self.updateButtonBadge()
                self.observeAlerts()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
        let conn = connection
        Task { [weak self] in
            let (next, readings) = await GraftConnectionView.fetchStatusAndUsage(using: conn)
            guard let self else { return }
            self.snapshot = next
            self.usageReadings = readings
            self.updateButtonBadge()
            if let currentMenu = self.item?.menu {
                self.rebuildMenu(currentMenu)
            }
        }
    }

    private func accountRows() -> [RoutingAccountDisplay] {
        let accounts = snapshot.accounts(for: "main")
        let labels = ClaudeAccountLabels.graft
        let now = Date()
        return accounts.members.map { id in
            let report = snapshot.report(for: id, from: "main")
            let limits = report?.limits
            let identity = snapshot.accountUUIDs[id]
            let usage = identity.flatMap { usageReadings[$0] }
            let name = snapshot.email(for: id, from: "main") ?? snapshot.names[id]
                ?? (id == "main" ? L10n.text("Main Claude profile") : id)
            var row = RoutingAccountDisplay(
                id: id, name: name, isPrimary: id == "main",
                state: "",
                weekly: usage?.weekly.map(RoutingUsageMetric.init),
                fable: usage?.fable.map(RoutingUsageMetric.init)
            )
            row.session = usage?.session.map(RoutingUsageMetric.init)
            row.nickname = labels.nickname(for: id)
            if let reset = limits?.fableRefusedUntil, reset > now { row.fableReset = reset }
            if let shortcut = snapshot.chatShortcut(for: id, from: "main") {
                row.canOpenChatProfile = true
                row.chatProfileSignedIn = shortcut.accountUUID != nil
            }
            return row
        }
    }

    private func observeAlerts() {
        let rows = accountRows()
        guard !rows.isEmpty else { return }
        UsageAlertNotifier.shared.observe(rows)
    }

    private func updateButtonBadge() {
        guard let button = item?.button else { return }
        guard showBadge else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        let rows = accountRows()
        let primaryLimited = (rows.first?.fable?.percent == 100 || rows.first?.fableReset != nil)
        if primaryLimited, let backupFable = rows.dropFirst().compactMap({ $0.fable?.percent }).first {
            button.imagePosition = .imageLeading
            button.title = " B:\(backupFable)%"
        } else if let mainFable = rows.first?.fable?.percent {
            button.imagePosition = .imageLeading
            button.title = " \(mainFable)%"
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = accountRows()
        let connected = snapshot.status?.configured == true && snapshot.status?.enabled == true
        let exclusive = snapshot.exclusiveAccount(for: "main")

        let headerText: String
        if !connected {
            headerText = L10n.text("Graft relay: waiting for connection")
        } else if let exclusive, let locked = rows.first(where: { $0.id == exclusive }) {
            headerText = L10n.format("Graft connected · Using only %@", locked.nickname ?? locked.name)
        } else {
            headerText = L10n.text("Graft connected · Automatic switching")
        }
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for row in rows {
            let role = L10n.text(row.isPrimary ? "Main" : "Backup")
            let titleItem = NSMenuItem(title: "\(role) · \(row.nickname ?? row.name)", action: nil, keyEquivalent: "")
            titleItem.isEnabled = false
            menu.addItem(titleItem)

            var parts: [String] = []
            if let s = row.session { parts.append(L10n.format("5h %ld%%", s.percent)) }
            if let w = row.weekly { parts.append(L10n.format("Week %ld%%", w.percent)) }
            if let f = row.fable {
                var text = L10n.format("Fable %ld%%", f.percent)
                if let reset = (f.resetAt ?? row.fableReset).flatMap({ RoutingUsageMetric.resetSummary($0) }) {
                    text += " (\(reset))"
                }
                parts.append(text)
            }
            let metricsText = parts.isEmpty ? L10n.text("No recent reading") : parts.joined(separator: "  ·  ")
            let metricsItem = NSMenuItem(title: "   " + metricsText, action: nil, keyEquivalent: "")
            metricsItem.isEnabled = false
            menu.addItem(metricsItem)
        }

        if snapshot.canSetRoutingMode(for: "main") {
            menu.addItem(.separator())
            let autoItem = menu.addItem(withTitle: L10n.text("Automatic switching"),
                                        action: #selector(selectAutomatic), keyEquivalent: "")
            autoItem.target = self
            autoItem.state = exclusive == nil ? .on : .off

            for row in rows where snapshot.canSelectAccount(row.id, for: "main") {
                let item = menu.addItem(
                    withTitle: L10n.format("Use only %@", row.nickname ?? row.name),
                    action: #selector(selectExclusiveAccount(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = row.id
                item.state = exclusive == row.id ? .on : .off
            }
        }

        menu.addItem(.separator())
        let openMain = menu.addItem(withTitle: L10n.text("Open Claude Desktop"),
                                    action: #selector(openMainClaude), keyEquivalent: "")
        openMain.target = self

        for row in rows where !row.isPrimary && row.canOpenChatProfile {
            let backupChat = menu.addItem(
                withTitle: L10n.format("Open Chat/Cowork on %@", row.nickname ?? row.name),
                action: #selector(openBackupChat(_:)),
                keyEquivalent: ""
            )
            backupChat.target = self
            backupChat.representedObject = row.id
            if !row.chatProfileSignedIn {
                let signIn = menu.addItem(
                    withTitle: L10n.format("Sign in %@ (without closing main)…", row.nickname ?? row.name),
                    action: #selector(signInBackupChat(_:)),
                    keyEquivalent: ""
                )
                signIn.target = self
                signIn.representedObject = row.id
            }
        }

        if GeminiDesktop.installedURL() != nil {
            let openGemini = menu.addItem(withTitle: L10n.text("Open Antigravity / Gemini"),
                                          action: #selector(openAntigravity), keyEquivalent: "")
            openGemini.target = self
        }

        menu.addItem(.separator())
        let badgeToggle = menu.addItem(withTitle: L10n.text("Show Fable % in Menu Bar"),
                                       action: #selector(toggleMenuBadge), keyEquivalent: "")
        badgeToggle.target = self
        badgeToggle.state = showBadge ? .on : .off

        let alertsToggle = menu.addItem(withTitle: L10n.text("Usage & Failover Notifications"),
                                        action: #selector(toggleAlerts), keyEquivalent: "")
        alertsToggle.target = self
        alertsToggle.state = UsageAlertNotifier.shared.alertsEnabled ? .on : .off

        menu.addItem(.separator())
        for (name, action) in [("Open AI Switcher", #selector(open)), ("Quit AI Switcher", #selector(quit))] {
            let row = menu.addItem(withTitle: L10n.text(name), action: action, keyEquivalent: "")
            row.target = self
        }
    }

    @objc private func selectAutomatic() {
        applyAccountPolicy(nil)
    }

    @objc private func selectExclusiveAccount(_ sender: NSMenuItem) {
        guard let memberID = sender.representedObject as? String else { return }
        applyAccountPolicy(memberID)
    }

    private func applyAccountPolicy(_ memberID: String?) {
        let conn = connection
        Task { [weak self] in
            guard let updated = try? await Task.detached(priority: .userInitiated, operation: {
                try conn.setExclusiveAccount(memberID, for: "main")
            }).value else { return }
            self?.snapshot = updated
            self?.updateButtonBadge()
        }
    }

    @objc private func openMainClaude() {
        Task { _ = try? await ClaudeAppLauncher.openDesktop(allowSeparateWindow: false) }
    }

    @objc private func openBackupChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let app = snapshot.chatProfileApp(for: id, from: "main") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: nil)
    }

    @objc private func signInBackupChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .switcherOpenBackupSignIn, object: id)
        }
    }

    @objc private func openAntigravity() {
        Task { try? await GeminiDesktop.openDesktop() }
    }

    @objc private func toggleMenuBadge() {
        showBadge.toggle()
    }

    @objc private func toggleAlerts() {
        UsageAlertNotifier.shared.alertsEnabled.toggle()
    }

    @objc private func open() { openWindow() }
    @objc private func quit() { AppDelegate.quit() }
}
