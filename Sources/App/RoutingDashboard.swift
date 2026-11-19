import SwiftUI

/// Only display data crosses into the dashboard. Credentials and conversation contents stay in the controller.
struct RoutingAccountDisplay: Identifiable {
    let id: String
    var name: String
    var isPrimary: Bool
    var state: String
    var needsAttention = false
    var weeklyUsed: Int?
    var fableReset: Date?
    var canRecheck = false
    var recheckPending = false
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
}

struct RoutingDashboard: View {
    let manage: (String) -> Void
    @EnvironmentObject private var store: ShortcutStore
    @EnvironmentObject private var usage: UsageMonitor
    @ObservedObject private var pool = Shared.usagePool
    @State private var profile = UsagePoolController.mainKey

    private var profiles: [String] {
        [UsagePoolController.mainKey] + store.shortcuts.filter { !store.isDraft($0) }.map(UsagePoolController.key)
    }

    var body: some View {
        // A deleted profile falls back to the main Claude even if the dashboard stayed open.
        let key = profiles.contains(profile) ? profile : UsagePoolController.mainKey
        RoutingPanel(data: display(for: key), enabled: Binding(
            get: { pool.automaticSwitchingEnabled(for: key) },
            set: { pool.setAutomaticSwitching($0, for: key) }
        ), canSwitch: UsagePoolController.isSupported, recheck: pool.recheckFable) {
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
        .onAppear { pool.watch() }
        .onDisappear { pool.unwatch() }
    }

    private func name(_ key: String) -> String {
        if let uuid = pool.accountUuid(of: key),
           let email = pool.accounts.first(where: { $0.accountUuid == uuid })?.email {
            return email
        }
        return pool.name(of: key)
    }

    private func display(for key: String) -> RoutingDisplay {
        let lenders = pool.lenders(of: key)
        var identities = Set<String>()
        let rows = ([key] + lenders).map { id -> RoutingAccountDisplay in
            let unique = identities.insert(pool.accountUuid(of: id) ?? id).inserted
            return account(id, primary: key, distinct: unique)
        }
        let history = (pool.status?.recent ?? []).filter { $0.from == key }
        let last = history.last { (200..<300).contains($0.status) }
        let summary = readiness(for: key, lenders: lenders, rows: rows)
        var result = RoutingDisplay(title: L10n.text(summary.0), detail: L10n.text(summary.1), ready: summary.2,
                                    accounts: rows, lastAccount: last.map { name($0.servedBy) },
                                    lastModel: last?.model.map(Self.modelName), lastAnswered: last?.at)
        if let failed = history.last, !(200..<300).contains(failed.status) {
            let model = failed.model.map(Self.modelName) ?? "Claude Code"
            result.latestFailure = failed.status == 429
                ? L10n.format("%@ reached a limit on the latest request.", model)
                : L10n.format("%@ returned an error on the latest request (%ld).", model, failed.status)
        }
        return result
    }

    private func readiness(for key: String, lenders: [String], rows: [RoutingAccountDisplay]) -> (String, String, Bool) {
        guard UsagePoolController.isSupported else {
            return ("Unavailable on this Mac", "Automatic switching requires macOS 15 or later.", false)
        }
        guard pool.automaticSwitchingEnabled(for: key) else {
            return ("Switching is off", "Turn it on to use backup accounts for Claude Code requests.", false)
        }
        guard !lenders.isEmpty else {
            return ("Add a backup account", "Connect another account to start switching Claude Code requests.", false)
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
            return ("Ready to switch", "Claude Code uses your primary account first. When it reaches a limit, an available backup can take over.", true)
        default:
            return ("Connecting", "Waiting for the routing service and this Claude profile to connect.", false)
        }
    }

    private func account(_ id: String, primary: String, distinct: Bool) -> RoutingAccountDisplay {
        let report = pool.status?.members.first { $0.id == id }
        let limits = report?.limits
        let live = pool.profile(of: id).flatMap(usage.entry(for:))?.currentUsage
        // A 429 without utilization headers can leave a zero placeholder in the relay.
        let week: Int? = live?.week ?? limits.flatMap { value in
            guard value.weekReset.map({ $0 > Date() }) ?? (value.week > 0) else { return nil }
            return Int((min(1, max(0, value.week)) * 100).rounded())
        }
        var row = RoutingAccountDisplay(id: id, name: name(id), isPrimary: id == primary,
                                         state: "Checking login", weeklyUsed: week)
        if !distinct {
            row.state = "Already listed"
            row.needsAttention = true
        } else if report?.tokenRefused == true || pool.lending[id] == .expired {
            row.state = "Sign in again"
            row.needsAttention = true
        } else if pool.lending[id] == .signedOut {
            row.state = "Signed out"
            row.needsAttention = true
        } else if pool.lending[id] == .unreadable {
            row.state = "Keychain locked"
            row.needsAttention = true
        } else if !PoolPolicy.hasRoom(limits, now: Date()) {
            row.state = "Usage limit reached"
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
            row.canRecheck = distinct && eligibleLogin && PoolPolicy.hasRoom(limits, now: Date())
                && pool.automaticSwitchingEnabled(for: primary)
            row.recheckPending = report?.fableRecheckPending == true || pool.sendingFableRechecks.contains(id)
        }
        row.state = L10n.text(row.state)
        return row
    }

    static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", ["fable","opus","sonnet","haiku"].contains(parts[1]),
              Int(parts[2]) != nil else { return id }
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }
        guard !version.isEmpty else { return id }
        return parts[1].capitalized + " " + version.joined(separator: ".")
    }
}

private let pine = Color(red: 0.10, green: 0.23, blue: 0.19)
private let mint = Color(red: 0.71, green: 0.91, blue: 0.76)

/// Two paths join at the same destination, at both sidebar and illustration sizes.
struct SwitcherMark: View {
    var body: some View {
        Canvas { context, size in
            let u = min(size.width, size.height) / 40
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x*u, y: y*u) }
            var path = Path()
            path.move(to: point(8, 29)); path.addLine(to: point(13, 29))
            path.addCurve(to: point(27, 11), control1: point(20, 29), control2: point(20, 11))
            path.addLine(to: point(32, 11))
            context.stroke(path, with: .color(mint), style: StrokeStyle(lineWidth: 4*u, lineCap: .round))
            var echo = Path()
            echo.move(to: point(8, 11)); echo.addLine(to: point(13, 11))
            echo.addQuadCurve(to: point(18, 15), control: point(16, 11))
            echo.move(to: point(22, 25)); echo.addQuadCurve(to: point(28, 29), control: point(25, 29))
            echo.addLine(to: point(32, 29))
            context.stroke(echo, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: 4*u, lineCap: .round))
        }.accessibilityHidden(true)
    }
}

struct SwitcherBrand: View {
    var body: some View {
        HStack(spacing: 9) {
            SwitcherMark().frame(width: 34, height: 34)
                .background(pine, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Claude Switcher").font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 0)
        }.padding(.horizontal, 17).padding(.vertical, 14)
    }
}

private struct RoutingDiagram: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w*x, y: h*y) }
            for i in 0..<12 {
                for j in 0..<7 {
                    let point = p(CGFloat(i)/11, CGFloat(j)/6)
                    context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 1.5, height: 1.5)),
                                 with: .color(mint.opacity(0.20)))
                }
            }
            for (index, height) in [0.22, 0.50, 0.78].enumerated() {
                let start = p(0.04, height)
                var path = Path(); path.move(to: start)
                path.addLine(to: p(0.22, height))
                path.addCurve(to: p(0.60, 0.5), control1: p(0.40, height), control2: p(0.40, 0.5))
                path.addLine(to: p(0.86, 0.50))
                let paint = index == 0 ? mint : mint.opacity(0.30)
                context.stroke(path, with: .color(paint), style: StrokeStyle(lineWidth: index == 0 ? 2.2 : 1.3, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: start.x-3, y: start.y-3, width: 6, height: 6)), with: .color(paint))
            }
            let end = p(0.86, 0.5)
            for (radius, opacity) in [(12.0, 0.10), (7.5, 0.21), (3.5, 1.0)] {
                context.fill(Path(ellipseIn: CGRect(x: end.x-radius, y: end.y-radius, width: 2*radius, height: 2*radius)),
                             with: .color(mint.opacity(opacity)))
            }
        }.accessibilityHidden(true)
    }
}

struct RoutingPanel<Profile: View, AccountActions: View, Manage: View>: View {
    let data: RoutingDisplay
    @Binding var enabled: Bool
    let canSwitch: Bool
    let recheck: (String) -> Void
    @ViewBuilder let profile: () -> Profile
    @ViewBuilder let accountActions: () -> AccountActions
    @ViewBuilder let manage: () -> Manage
    @Environment(\.colorScheme) private var scheme

    private var canvas: Color {
        scheme == .dark ? Color(red: 0.105, green: 0.12, blue: 0.115) : Color(red: 0.965, green: 0.967, blue: 0.950)
    }
    private var paper: Color {
        scheme == .dark ? Color(red: 0.14, green: 0.155, blue: 0.15) : Color(red: 1, green: 1, blue: 0.99)
    }
    private var accent: Color { scheme == .dark ? mint : Color(red: 0.13, green: 0.36, blue: 0.26) }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 580
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 17 : 22) {
                    HStack(alignment: .center) {
                        Text("Routing").font(.system(size: compact ? 29 : 34, weight: .semibold))
                            .accessibilityAddTraits(.isHeader).identified("routing.dashboard")
                        Spacer(minLength: 8)
                        profile()
                    }
                    hero(compact: compact, width: geo.size.width)
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            heading("Accounts")
                            Spacer(minLength: 4)
                            accountActions().tint(accent)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(data.accounts.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().padding(.leading, 16) }
                                accountRow(item, compact: geo.size.width < 480)
                            }
                            if data.accounts.count <= 1 {
                                Divider()
                                HStack(spacing: 9) {
                                    Image(systemName: "person.crop.circle.badge.plus")
                                    Text("Add another signed-in account to give this profile a backup.")
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }.font(.callout).foregroundStyle(.secondary).padding(13)
                            }
                        }.card(paper)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            heading("Routing activity")
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

    private func hero(compact: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                Label("Automatic switching", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(mint)
                Spacer(minLength: 8)
                Text(enabled ? "On" : "Off").font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.86)).accessibilityHidden(true)
                Toggle("Automatic switching", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                    .tint(Color(red: 0.38, green: 0.71, blue: 0.48))
                    .environment(\.colorScheme, .dark).disabled(!canSwitch)
                    .accessibilityLabel("Automatic switching").identified("routing.automatic")
                    .help("Allow this profile to use the accounts listed below for Claude Code requests.")
            }
            Rectangle().fill(mint.opacity(0.22)).frame(height: 1)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(data.title).font(.system(size: compact ? 23 : 28, weight: .medium, design: .rounded))
                        .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Text(data.detail).font(.callout).foregroundStyle(Color.white.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if width >= 470 {
                    RoutingDiagram().frame(width: compact ? 89 : 142, height: compact ? 52 : 62)
                        .opacity(data.ready ? 1 : 0.65)
                }
            }
        }
        .padding(compact ? 16 : 19)
        .background(LinearGradient(colors: [pine, Color(red: 0.12, green: 0.29, blue: 0.23)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func accountRow(_ item: RoutingAccountDisplay, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.isPrimary ? "person.crop.circle" : "square.stack.3d.up")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(accent)
                .frame(width: 33, height: 33)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    .truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 5) {
                    Text(L10n.text(item.isPrimary ? "Primary" : "Backup"))
                    Text("·").accessibilityHidden(true)
                    Text(item.state).foregroundStyle(item.needsAttention ? Color.primary : .secondary)
                }.font(.caption).foregroundStyle(.secondary)
                if compact { weekly(item) }
                if let reset = item.fableReset {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.format("Fable resets %@", reset.formatted(date: .abbreviated, time: .shortened)))
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
            }
            Spacer(minLength: 2)
            if !compact { weekly(item).padding(.top, 1) }
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func weekly(_ item: RoutingAccountDisplay) -> some View {
        if let percent = item.weeklyUsed {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.format("%ld%% weekly used", percent)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                GeometryReader { geo in
                    Capsule().fill(accent.opacity(0.13)).overlay(alignment: .leading) {
                        Capsule().fill(percent >= 95 ? (scheme == .dark ? Color.orange : Color.brown) : accent)
                            .frame(width: geo.size.width * CGFloat(min(100, max(0, percent))) / 100)
                    }
                }.frame(width: 94, height: 4).accessibilityHidden(true)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = data.latestFailure {
                Label(failure, systemImage: "exclamationmark.circle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if data.lastAnswered != nil { Divider() }
            }
            if let at = data.lastAnswered, let name = data.lastAccount {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle").foregroundStyle(accent).accessibilityHidden(true)
                    Text("Last successful request").font(.callout.weight(.medium))
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
