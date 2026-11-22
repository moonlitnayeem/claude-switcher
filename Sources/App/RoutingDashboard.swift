import SwiftUI
import UniformTypeIdentifiers

/// Only display data crosses into the dashboard. Credentials and conversation contents stay in the controller.
struct RoutingAccountDisplay: Identifiable {
    let id: String
    var name: String
    var isPrimary: Bool
    var state: String
    var needsAttention = false
    var weekly: RoutingUsageMetric?
    var fable: RoutingUsageMetric?
    var canUpdateUsage = false
    var fableReset: Date?
    var canRecheck = false
    var recheckPending = false
    var nickname: String? = nil
    var canSelect = true
    var canOpenChatProfile = false
}

struct RoutingUsageMetric {
    var percent: Int
    var observedAt: Date
    var source: String

    init(percent: Int, observedAt: Date, source: String) {
        self.percent = percent
        self.observedAt = observedAt
        self.source = source
    }

    init(_ metric: ClaudeUsageDisplay.Metric) {
        self.init(percent: metric.percent, observedAt: metric.observedAt,
                  source: L10n.text(metric.source.rawValue))
    }
}

struct RoutingDisplay {
    var title: String
    var detail: String
    var ready = false
    var accounts: [RoutingAccountDisplay]
    var lastAccount: String?
    var lastModel: String?
    var lastAnswered: Date?
    var latestFailure: String?
    var recentModelLimits: [RoutingModelLimit] = []
    var route: RouteMapSignal?
    var externallyManaged = false
    var exclusiveAccount: String?
    var routingControlHint: String?
    var savedChoiceUnreadable = false
}

struct RoutingModelLimit: Identifiable {
    let id: String
    let at: Date
}

extension RoutingDisplay {
    var primaryFableLimited: Bool {
        guard let primary = accounts.first else { return false }
        return primary.fable?.percent == 100 || primary.fableReset != nil
    }

    var preferredBackupChatProfile: RoutingAccountDisplay? {
        let backups = accounts.dropFirst().filter(\.canOpenChatProfile)
        return backups.first { !$0.needsAttention && $0.fable?.percent != 100 && $0.fableReset == nil } ?? backups.first
    }

    mutating func readRecentLimits(_ history: [PoolRouting]) {
        recentModelLimits = PoolRouting.latestModelRateLimits(in: history).compactMap { event in
            event.model.map { RoutingModelLimit(id: $0, at: event.at) }
        }
    }

    func showsRateLimit(for event: PoolRouting) -> Bool {
        recentModelLimits.contains { $0.id == event.model && $0.at == event.at }
    }
}

extension PoolStatus {
    var savedChoiceUnreadable: Bool { exclusiveAccounts == nil && accountPolicyError != nil }
}

struct RoutingDashboard: View {
    let manage: (String) -> Void
    @EnvironmentObject private var store: ShortcutStore
    @EnvironmentObject private var usage: UsageMonitor
    @ObservedObject private var pool = Shared.usagePool
    @State private var profile = UsagePoolController.mainKey
    @ObservedObject private var labels = ClaudeAccountLabels.standalone
    @State private var editingLabel: ClaudeLabelTarget?
    @State private var changingMode = false
    @State private var routingError: String?

    private var profiles: [String] {
        [UsagePoolController.mainKey] + store.shortcuts.filter { !store.isDraft($0) }.map(UsagePoolController.key)
    }

    var body: some View {
        // A deleted profile falls back to the main Claude even if the dashboard stayed open.
        let key = profiles.contains(profile) ? profile : UsagePoolController.mainKey
        RoutingPanel(data: display(for: key), enabled: Binding(
            get: { pool.canSetRoutingMode(for: key) && pool.exclusiveAccount(for: key) == nil && pool.automaticSwitchingEnabled(for: key) },
            set: { setMode($0 ? nil : key, for: key) }
        ), canSwitch: pool.canSetRoutingMode(for: key) && !changingMode, refresh: {
            await pool.refreshRelayStatus()
        }, recheck: pool.recheckFable,
                     useOnly: { setMode($0, for: key) },
                     openChatProfile: { openBackupChatProfile($0, primary: key) },
                     removeBackup: { pool.removeDisplayedBackup($0, from: key) },
                     renameAccount: { id in editingLabel = ClaudeLabelTarget(id: id, name: name(id)) },
                     launchControls: key == UsagePoolController.mainKey ? ClaudeLaunchControls() : nil) {
            if profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { key }, set: { profile = $0 })) {
                    ForEach(profiles, id: \.self) { item in Text(pool.name(of: item)).tag(item) }
                }.fixedSize().identified("routing.profile")
            } else {
                Label(pool.name(of: key), systemImage: "laptopcomputer")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityLabel("Profile").accessibilityValue(pool.name(of: key))
            }
        } accountActions: {
            if UsagePoolController.isSupported { RoutingAccountActions(claude: key) }
        } manage: {
            if pool.lendingPaused {
                Button("Unlock Keychain") { pool.openKeychain(interactive: true) }
                    .identified("routing.keychain")
            }
            Button("Profile settings") { manage(key) }
                .identified("routing.settings")
        }
        .sheet(item: $editingLabel) { item in
            ClaudeAccountLabelEditor(id: item.id, accountName: item.name, labels: labels)
        }
        .alert("Couldn’t change accounts", isPresented: Binding(get: { routingError != nil },
                                                               set: { if !$0 { routingError = nil } })) {
            Button("OK") { routingError = nil }
        } message: { Text(routingError ?? "") }
        .onAppear { pool.watch() }
        .onDisappear { pool.unwatch() }
    }

    private func setMode(_ account: String?, for profile: String) {
        guard !changingMode, pool.canSetRoutingMode(for: profile) else { return }
        changingMode = true
        Task {
            defer { changingMode = false }
            do { try await pool.setExclusiveAccount(account, for: profile) }
            catch { routingError = error.localizedDescription }
        }
    }

    private func name(_ key: String) -> String {
        if let email = pool.accounts.first(where: { pool.sameIdentity(key, $0.id) })?.email {
            return email
        }
        return pool.name(of: key)
    }

    private func chatShortcut(for id: String, primary: String) -> Shortcut? {
        guard id != primary else { return nil }
        let candidates = store.shortcuts.filter { !store.isDraft($0) && UsagePoolController.key(for: $0) != primary }
            .filter { ProfileOpener.bundle(for: $0) != nil }
        if let direct = candidates.first(where: { UsagePoolController.key(for: $0) == id }) { return direct }
        if let accountUUID = pool.accounts.first(where: { pool.sameIdentity(id, $0.id) })?.accountUuid?.lowercased(),
           let matched = candidates.first(where: {
               GraftAccountLabel.profileAccount(in: $0.profileDir)?.uuidString.lowercased() == accountUUID
           }) {
            return matched
        }
        let email = name(id).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return nil }
        return candidates.first { shortcut in
            guard GraftAccountLabel.profileAccount(in: shortcut.profileDir) == nil else { return false }
            let shortcutName = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let installedName = shortcut.installedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return shortcutName == email || installedName == email
        }
    }

    private func openBackupChatProfile(_ id: String, primary: String) {
        guard let shortcut = chatShortcut(for: id, primary: primary) else {
            routingError = L10n.text("No installed Claude profile was found for this backup account.")
            return
        }
        ProfileOpener.open(profile: shortcut.profileDir, shortcut: shortcut) { error in
            if let error { routingError = error.localizedDescription }
        }
    }

    private func display(for key: String) -> RoutingDisplay {
        let available = pool.members(of: key)
        let ids = available.isEmpty ? [key] : available
        let rows = ids.map { account($0, primary: key) }
        let history = (pool.status?.recent ?? []).filter { $0.from == key }
        let last = history.last { (200..<300).contains($0.status) }
        let summary = readiness(for: key, rows: rows)
        var result = RoutingDisplay(title: L10n.text(summary.0), detail: L10n.text(summary.1), ready: summary.2,
                                    accounts: rows, lastAccount: last.map { name($0.servedBy) },
                                    lastModel: last?.model.map(Self.modelName), lastAnswered: last?.at)
        if pool.status?.savedChoiceUnreadable == true {
            result.savedChoiceUnreadable = true
            result.routingControlHint = L10n.text("Account controls are unavailable for this connection.")
        } else if pool.canSetRoutingMode(for: key) {
            if let selected = pool.exclusiveAccount(for: key) {
                result.exclusiveAccount = rows.first { pool.sameIdentity($0.id, selected) }?.id ?? selected
            }
        } else {
            result.routingControlHint = L10n.text("Connect this profile to the relay to change accounts here.")
        }
        if let live = pool.status?.activeRoutes?.filter({ $0.from == key }).max(by: { $0.startedAt < $1.startedAt }) {
            result.route = RouteMapSignal(phase: .sending, backup: !pool.sameIdentity(live.member, key),
                                          model: live.model.map(Self.modelName), at: live.startedAt,
                                          mainLimited: rows.first?.weekly?.percent == 100 ||
                                            (PoolRequest.usesIncludedAllowance(live.model) && rows.first?.fable?.percent == 100))
        } else if let recent = history.last {
            result.route = RouteMapSignal(phase: (200..<300).contains(recent.status) ? .answered : .failed,
                                          backup: !pool.sameIdentity(recent.servedBy, key), model: recent.model.map(Self.modelName), at: recent.at)
        }
        result.readRecentLimits(history)
        if let failed = history.last, !(200..<300).contains(failed.status), !result.showsRateLimit(for: failed) {
            let model = failed.model.map(Self.modelName) ?? "Claude Code"
            result.latestFailure = failed.status == 429
                ? L10n.format("%@ reached a limit on the latest request.", model)
                : L10n.format("%@ returned an error on the latest request (%ld).", model, failed.status)
        }
        return result
    }

    private func readiness(for key: String, rows: [RoutingAccountDisplay]) -> (String, String, Bool) {
        guard UsagePoolController.isSupported else {
            return ("Unavailable on this Mac", "Automatic switching requires macOS 15 or later.", false)
        }
        guard pool.automaticSwitchingEnabled(for: key) else {
            return ("Switching is off", "Turn it on to use backup accounts for Claude Code requests.", false)
        }
        guard rows.count > 1 else {
            return ("Add a backup account", "Add another account so Claude has somewhere to go when your main account runs out.", false)
        }
        if pool.lendingPaused {
            return ("Keychain access needed", "Unlock the keychain to refresh the accounts available for switching.", false)
        }
        if let problem = pool.problem {
            return ("Routing needs attention", problem, false)
        }
        switch pool.environment[key] {
        case .waiting:
            return ("Waiting for Claude", "Routing starts the next time this Claude profile opens.", false)
        case .conflict(let source, _) where source == ClaudeCodeEnvironment.legacyGraftConflict:
            return ("Claude Graft manages this profile", "Turn off this profile’s shared usage in Claude Graft to connect it here.", false)
        case .conflict:
            return ("Another connection is configured", "Review this profile’s Claude Code connection in its settings.", false)
        case .unreadable:
            return ("Connection unavailable", "The profile’s Claude Code connection settings could not be read.", false)
        case .on where pool.status?.enabled == true && pool.status?.configured == true:
            if rows.dropFirst().allSatisfy(\.needsAttention) {
                return ("Check backup accounts", "The relay is connected. Review the account status below.", false)
            }
            guard rows.dropFirst().contains(where: { !$0.needsAttention && pool.lending[$0.id] == .ready }) else {
                return ("Checking account access", "The relay is connected and is checking the backup accounts.", false)
            }
            return ("Ready to switch", "Claude uses your main account first. If it runs out, a backup can answer.", true)
        default:
            return ("Connecting", "Waiting for the routing service and this Claude profile to connect.", false)
        }
    }

    private func account(_ id: String, primary: String) -> RoutingAccountDisplay {
        let report = pool.status?.members.first { $0.id == id }
        let limits = report?.limits
        let now = Date()
        var row = RoutingAccountDisplay(id: id, name: name(id), isPrimary: id == primary, state: "Checking login")
        if let entry = pool.profile(of: id).flatMap(usage.entry(for:)),
           let live = entry.currentUsage, let observed = entry.refreshed,
           (0 ..< 5 * 3600).contains(now.timeIntervalSince(observed)) {
            let source = L10n.text(entry.isLive ? "Claude usage service" : "Claude profile record")
            if live.weeklyReadingPresent, (0...100).contains(live.week), (live.weekReset ?? .distantFuture) > now {
                row.weekly = RoutingUsageMetric(percent: live.week, observedAt: observed, source: source)
            }
            if let percent = live.fable, (0...100).contains(percent), (live.fableReset ?? .distantFuture) > now {
                row.fable = RoutingUsageMetric(percent: percent, observedAt: observed, source: source)
            }
        }
        if let limits {
            let relaySource = L10n.text(ClaudeUsageDisplay.Source.relay.rawValue)
            if (0 ..< 5 * 3600).contains(now.timeIntervalSince(limits.observed)),
               (limits.weekReset ?? .distantFuture) > now {
                let percent = Int((limits.week * 100).rounded())
                if (0...100).contains(percent), row.weekly == nil || limits.observed > row.weekly!.observedAt {
                    row.weekly = RoutingUsageMetric(percent: percent, observedAt: limits.observed, source: relaySource)
                }
            }
            let fableAt = limits.fableObserved ?? limits.observed
            if let fable = limits.fable, (0 ..< 5 * 3600).contains(now.timeIntervalSince(fableAt)),
               (limits.fableReset ?? limits.weekReset ?? .distantFuture) > now {
                let percent = Int((fable * 100).rounded())
                if (0...100).contains(percent), row.fable == nil || fableAt > row.fable!.observedAt {
                    row.fable = RoutingUsageMetric(percent: percent, observedAt: fableAt, source: relaySource)
                }
            }
        }
        if report?.tokenRefused == true || pool.lending[id] == .expired {
            row.state = "Sign in again"
            row.needsAttention = true
        } else if pool.lending[id] == .signedOut {
            row.state = "Signed out"
            row.needsAttention = true
        } else if pool.lending[id] == .unreadable {
            row.state = "Keychain locked"
            row.needsAttention = true
        } else if row.weekly?.percent == 100 {
            row.state = "Weekly limit reached"
            row.needsAttention = true
        } else if pool.lending[id] == .ready {
            row.state = "Signed in"
        } else if pool.lenders(of: primary).isEmpty {
            row.state = "Profile account"
        }
        if let until = limits?.fableRefusedUntil, until > Date() {
            row.fableReset = until
            // The primary uses its original request bearer. Only a backup needs a lendable login.
            let eligibleLogin = row.isPrimary || (pool.lending[id] == .ready && report?.tokenRefused != true)
            row.canRecheck = eligibleLogin && PoolPolicy.hasRoom(limits, now: Date())
                && pool.automaticSwitchingEnabled(for: primary)
            row.recheckPending = report?.fableRecheckPending == true || pool.sendingFableRechecks.contains(id)
        }
        row.nickname = labels.nickname(for: id)
        row.canSelect = pool.canSelectAccount(id, for: primary)
        row.canOpenChatProfile = chatShortcut(for: id, primary: primary) != nil
        row.state = L10n.text(row.state)
        return row
    }

    static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", ["fable", "mythos", "opus", "sonnet", "haiku"].contains(parts[1]),
              Int(parts[2]) != nil else { return id }
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }
        guard !version.isEmpty else { return id }
        return parts[1].capitalized + " " + version.joined(separator: ".")
    }
}

struct SwitcherBrand: View {
    var icon: NSImage?

    private static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon ?? Self.appIcon)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            Text("AI Switcher").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
        }.padding(.horizontal, 17).padding(.vertical, 14)
    }
}

struct RoutingPanel<Profile: View, AccountActions: View, Manage: View>: View {
    let data: RoutingDisplay
    @Binding var enabled: Bool
    let canSwitch: Bool
    let refresh: () async -> Bool
    let recheck: (String) -> Void
    let useOnly: (String) -> Void
    var openChatProfile: ((String) -> Void)? = nil
    var removeBackup: ((String) -> Void)? = nil
    var renameAccount: ((String) -> Void)? = nil
    var updateUsage: ((String) -> Void)? = nil
    var launchControls: ClaudeLaunchControls? = nil
    @ViewBuilder let profile: () -> Profile
    @ViewBuilder let accountActions: () -> AccountActions
    @ViewBuilder let manage: () -> Manage
    @Environment(\.colorScheme) private var scheme
    @State private var refreshing = false
    @State private var refreshResult: String?

    private var canvas: Color {
        scheme == .dark ? Color(red: 0.065, green: 0.078, blue: 0.103) : Color(red: 0.955, green: 0.964, blue: 0.975)
    }
    private var paper: Color {
        scheme == .dark ? Color(red: 0.106, green: 0.122, blue: 0.157) : .white
    }
    private var accent: Color { scheme == .dark ? OrbitInk.aqua : Color(red: 0.075, green: 0.35, blue: 0.39) }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 580
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 17 : 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center) {
                            Text("Claude Desktop").font(.system(size: compact ? 27 : 32, weight: .bold, design: .rounded))
                                .accessibilityAddTraits(.isHeader).identified("routing.dashboard")
                            Spacer(minLength: 8)
                            profile()
                        }
                        let subtitle: LocalizedStringKey = data.externallyManaged
                            ? "Claude Code uses Graft for this connection" : "Claude Code account map"
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                launchControls
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                                launchControls
                            }
                        }
                    }
                    RoutingOrbitCard(data: data, enabled: $enabled, canSwitch: canSwitch, compact: compact)
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            heading("Your accounts")
                            Spacer(minLength: 4)
                            Button {
                                guard !refreshing else { return }
                                refreshing = true
                                Task { @MainActor in
                                    let received = await refresh()
                                    refreshResult = received
                                        ? L10n.format("Relay status refreshed at %@.", Date().formatted(date: .omitted, time: .standard))
                                        : L10n.text("Couldn’t refresh the relay status. Check the connection and try again.")
                                    refreshing = false
                                }
                            } label: {
                                Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                            }
                            .disabled(refreshing).identified("routing.refresh")
                            .help("Read the latest account status from the relay. Use Recheck Fable after resetting its limit.")
                            accountActions().tint(accent)
                        }
                        if let refreshResult {
                            Text(refreshResult).font(.caption).foregroundStyle(.secondary)
                                .identified("routing.refresh-result")
                        }
                        Text(data.routingControlHint ?? L10n.text("These controls apply to new Claude Code requests in this profile."))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if data.primaryFableLimited, let backup = data.preferredBackupChatProfile, let openChatProfile {
                            backupChatBanner(for: backup, action: openChatProfile)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(data.accounts.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().padding(.leading, 16) }
                                accountRow(item, compact: geo.size.width < 480)
                            }
                            if data.accounts.count <= 1 {
                                Divider()
                                HStack(spacing: 9) {
                                    Image(systemName: "person.crop.circle.badge.plus").accessibilityHidden(true)
                                    Text("Add another signed-in account to give this profile a backup.")
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }.font(.callout).foregroundStyle(.secondary).padding(13)
                            }
                        }.card(paper)
                        if data.externallyManaged {
                            Text("Usage readings update this dashboard. Graft still decides where to send each request.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            heading("Recent activity")
                            Spacer(minLength: 0)
                            manage().font(.callout).buttonStyle(RoutingTextButtonStyle(color: accent))
                        }
                        activity.card(paper)
                    }
                }
                .frame(maxWidth: 860).padding(compact ? 18 : 26)
                .frame(maxWidth: .infinity)
            }.background(canvas)
        }
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }

    private func backupChatBanner(for backup: RoutingAccountDisplay,
                                  action: @escaping (String) -> Void) -> some View {
        let targetName = backup.nickname ?? backup.name
        let copy = HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Main reached its Fable limit").font(.callout.weight(.semibold))
                Text("Claude Code switches automatically. Open your backup profile for Chat and Cowork.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let button = Button {
            action(backup.id)
        } label: {
            Label("Open Chat/Cowork on backup", systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.borderedProminent).controlSize(.small).tint(accent)
        .help(L10n.format("Open %@ in a separate Claude window for Chat and Cowork.", targetName))
        .accessibilityLabel(L10n.format("Open Chat and Cowork on backup %@", targetName))
        .identified("routing.open-backup-chat")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                copy
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 8) {
                copy
                button
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .card(paper)
        .identified("routing.backup-chat-banner")
    }

    private func accountRow(_ item: RoutingAccountDisplay, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.isPrimary ? "person.fill" : "person.2.fill")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(accent)
                .frame(width: 33, height: 33)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.nickname ?? item.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    .truncationMode(.middle).textSelection(.enabled)
                if item.nickname != nil {
                    Text(item.name).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                HStack(spacing: 5) {
                    Text(L10n.text(item.isPrimary ? "Main" : "Backup"))
                    Text("·").accessibilityHidden(true)
                    Text(item.state).foregroundStyle(item.needsAttention ? Color.primary : .secondary)
                }.font(.caption).foregroundStyle(.secondary)
                if let reset = item.fableReset {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.format("Saved Fable reset time · %@", reset.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                        if item.recheckPending {
                            Text("Recheck queued for next Fable request").font(.caption).foregroundStyle(accent)
                        } else if item.canRecheck {
                            Button("Recheck Fable") { recheck(item.id) }.font(.caption)
                                .buttonStyle(RoutingTextButtonStyle(color: accent))
                                .help("Try this account again on the next Fable request.")
                                .accessibilityLabel(L10n.format("Recheck Fable for %@", item.name))
                                .identified("routing.recheck.\(item.id)")
                        }
                    }.padding(.top, 2)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { rowActions(item) }
                    VStack(alignment: .leading, spacing: 6) { rowActions(item) }
                }.padding(.top, 4)
                let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 9))
                                     : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                layout {
                    usageBar("Overall weekly", metric: item.weekly, id: "routing.weekly.\(item.id)")
                    usageBar("Fable usage", metric: item.fable, id: "routing.fable.\(item.id)")
                }.padding(.top, 6)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func rowActions(_ item: RoutingAccountDisplay) -> some View {
        let selected = data.exclusiveAccount == item.id
        Button {
            useOnly(item.id)
        } label: {
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
                Text(selected ? "Selected account" : "Use only this account")
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .tint(selected ? accent : nil)
        .disabled(!canSwitch || !item.canSelect || selected)
        .help(item.canSelect || selected ? L10n.text("Use this account for new Claude Code requests in this profile.") :
                L10n.text("The relay cannot use this account yet. Check its sign-in."))
        .accessibilityLabel(selected ? L10n.format("Selected account, %@", item.nickname ?? item.name)
                                     : L10n.format("Use only %@", item.nickname ?? item.name))
        .identified("routing.only.\(item.id)")
        if !item.isPrimary && item.canOpenChatProfile, let openChatProfile {
            Button {
                openChatProfile(item.id)
            } label: {
                Label(data.primaryFableLimited ? "Open Chat/Cowork on backup" : "Open Chat/Cowork",
                      systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(data.primaryFableLimited ? accent : nil)
            .help(L10n.format("Open %@ in a separate Claude window for Chat and Cowork.", item.nickname ?? item.name))
            .accessibilityLabel(L10n.format("Open Chat and Cowork on backup %@", item.nickname ?? item.name))
            .identified("routing.open-chat.\(item.id)")
        }
        if let renameAccount {
            Button("Rename label") { renameAccount(item.id) }
                .accessibilityLabel(L10n.format("Rename label for %@", item.name))
                .help("Give this account a name in AI Switcher.")
                .identified("routing.rename.\(item.id)")
                .font(.caption).buttonStyle(RoutingTextButtonStyle(color: accent))
        }
        if item.canUpdateUsage, let updateUsage {
            Button("Update from Claude…") { updateUsage(item.id) }
                .accessibilityLabel(L10n.format("Update usage from Claude for %@", item.name))
                .identified("routing.update-usage.\(item.id)")
                .font(.caption).buttonStyle(RoutingTextButtonStyle(color: accent))
        }
        if !item.isPrimary, let removeBackup {
            Button("Remove backup") { removeBackup(item.id) }
                .accessibilityLabel(L10n.format("Remove %@ as a backup", item.name))
                .help("Stop using this backup for this profile. Its sign-in stays saved.")
                .identified("routing.remove.\(item.id)")
                .font(.caption).buttonStyle(RoutingTextButtonStyle(color: accent))
        }
    }

    private func usageBar(_ title: String, metric: RoutingUsageMetric?, id: String) -> some View {
        let value = metric.map { L10n.format("%ld%% used", $0.percent) } ?? L10n.text("No recent reading")
        let source = metric.map { L10n.format("%@ · %@", $0.source,
                                                $0.observedAt.formatted(date: .abbreviated, time: .shortened)) }
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(L10n.text(title)).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(value).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title)).fontWeight(.semibold)
                    Text(value).foregroundStyle(.secondary)
                }
            }.font(.caption)
            GeometryReader { size in
                Capsule().fill(accent.opacity(0.15)).overlay(alignment: .leading) {
                    if let metric {
                        Capsule().fill(metric.percent >= 95 ? (scheme == .dark ? Color.orange : Color.brown) : accent)
                            .frame(width: size.size.width * CGFloat(metric.percent) / 100)
                    }
                }
            }.frame(height: 4)
            if let source { Text(source).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .spoken(L10n.text(title), value: [value, source].compactMap { $0 }.joined(separator: ", "))
        .identified(id)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = data.latestFailure {
                Label(failure, systemImage: "exclamationmark.circle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if data.lastAnswered != nil { Divider() }
            }
            ForEach(data.recentModelLimits) { limit in
                Label(L10n.format("%@ hit a limit on its last request · %@",
                                  RoutingDashboard.modelName(limit.id),
                                  limit.at.formatted(date: .abbreviated, time: .shortened)),
                      systemImage: "exclamationmark.circle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !data.recentModelLimits.isEmpty && data.lastAnswered != nil { Divider() }
            if let at = data.lastAnswered, let name = data.lastAccount {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle").foregroundStyle(accent).accessibilityHidden(true)
                    Text("Last reply").font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text([data.lastModel, name].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Label("No successful request recorded", systemImage: "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClaudeLaunchControls: View {
    var openDesktop: @MainActor (Bool) async throws -> Bool = { try await ClaudeAppLauncher.openDesktop(allowSeparateWindow: $0) }
    var openTerminal: @MainActor () async throws -> Void = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Open in Terminal")
        panel.message = L10n.text("Pick a project folder. Claude Code in Terminal uses its own sign-in and settings. Desktop account switching applies only in Claude Desktop.")
        if panel.runModal() == .OK, let folder = panel.url {
            try await ClaudeAppLauncher.openCLI(project: folder)
        }
    }

    private enum Notice: Identifiable {
        case separateWindow, failure(String)
        var id: String {
            switch self { case .separateWindow: return "separate"; case .failure(let message): return message }
        }
    }

    @State private var notice: Notice?
    @State private var opening = false

    var body: some View {
        HStack(spacing: 5) {
            Button { launchDesktop() } label: {
                Label("Open Claude Desktop", systemImage: "macwindow")
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .identified("routing.launch.desktop")
            Menu {
                Button("Open Claude Code in Terminal…") {
                    Task { do { try await openTerminal() } catch { notice = .failure(error.localizedDescription) } }
                }.identified("routing.launch.cli")
            } label: {
                Text("More")
            }.menuStyle(.button).controlSize(.small)
                .help("More ways to open Claude").accessibilityLabel("More ways to open Claude")
                .identified("routing.launch.options")
        }.disabled(opening)
        .alert(item: $notice) { notice in
            switch notice {
            case .separateWindow:
                return Alert(title: Text("Open the main Claude Desktop window?"),
                             message: Text("A different Claude profile is open. This opens the main profile in its own window."),
                             primaryButton: .default(Text("Open main window")) { launchDesktop(allowSeparateWindow: true) },
                             secondaryButton: .cancel())
            case .failure(let message):
                return Alert(title: Text("Could not open Claude"), message: Text(message),
                             dismissButton: .default(Text("OK")))
            }
        }
    }

    private func launchDesktop(allowSeparateWindow: Bool = false) {
        guard !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            do {
                if try await !openDesktop(allowSeparateWindow) { notice = .separateWindow }
            } catch { notice = .failure(error.localizedDescription) }
        }
    }
}

private struct RoutingTextButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(color).opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private extension View {
    func card(_ fill: Color) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1) }
    }
}
