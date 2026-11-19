import SwiftUI

struct DemoDashboard: View {
    let empty: Bool
    var active = true
    var tryingBackup = true
    @State private var start = Date().addingTimeInterval(-0.3)
    @State private var enabled = true
    @State private var queued = false
    @State private var removed = false
    @State private var editingLabel: ClaudeLabelTarget?
    @StateObject private var labels = ClaudeAccountLabels(scope: "fixture", defaults: UserDefaults(suiteName: "switcher-fixture-" + UUID().uuidString)!)

    var body: some View {
        let hasBackup = !empty && !removed
        let primary = RoutingAccountDisplay(id: "personal", name: "alex@example.com", isPrimary: true,
                                            state: L10n.text("Signed in"), weeklyUsed: empty ? nil : 96,
                                            fableReset: empty ? nil : Date(timeIntervalSince1970: 1_783_555_200),
                                            canRecheck: enabled, recheckPending: queued,
                                            nickname: labels.nickname(for: "personal"))
        let backup = RoutingAccountDisplay(id: "studio", name: "studio@example.org", isPrimary: false,
                                           state: L10n.text("Signed in"), weeklyUsed: 24,
                                           nickname: labels.nickname(for: "studio"))
        let route: RouteMapSignal? = !hasBackup || !enabled ? nil : RouteMapSignal(
            phase: active ? .sending : .answered, backup: tryingBackup, model: "Fable 5.2", at: start, mainLimited: tryingBackup)
        let snapshot = RoutingDisplay(
            title: L10n.text(enabled ? (!hasBackup ? "Add a backup account" : "Ready to switch") : "Switching is off"),
            detail: L10n.text(enabled
                ? (!hasBackup ? "Add another account so Claude has somewhere to go when your main account runs out."
                         : "Claude uses your main account first. If it runs out, a backup can answer.")
                : "Turn it on to use backup accounts for Claude Code requests."),
            ready: enabled && hasBackup, accounts: hasBackup ? [primary, backup] : [primary],
            lastAccount: empty ? nil : backup.name, lastModel: empty ? nil : "Fable 5.2",
            lastAnswered: empty ? nil : Date(timeIntervalSince1970: 1_783_348_200), route: route)
        RoutingPanel(data: snapshot, enabled: $enabled, canSwitch: true, recheck: { _ in queued = true },
                     removeBackup: { _ in removed = true },
                     renameAccount: { id in editingLabel = ClaudeLabelTarget(id: id, name: id == primary.id ? primary.name : backup.name) },
                     launchControls: ClaudeLaunchControls(openDesktop: { _ in true }, openTerminal: {})) {
            Label("Claude", systemImage: "laptopcomputer").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        } accountActions: {
            Menu {
                if removed { Button(backup.name) { removed = false } }
                Text("Sign In to Another Account…")
            } label: { Label("Add backup", systemImage: "plus") }
                .menuStyle(.button).controlSize(.small).fixedSize().identified("shared-usage.add")
        } manage: { Button("Profile settings") {}.identified("routing.settings") }
        .sheet(item: $editingLabel) { item in
            ClaudeAccountLabelEditor(id: item.id, accountName: item.name, labels: labels)
        }
    }
}


// Frame-driven only in the capture fixture, so the recorded example keeps the same timing on slower Macs.
final class DemoFrames: ObservableObject {
    enum Step { case main, backup, done }
    @Published var step = Step.main
}

struct DemoRoutingSequence: View {
    @ObservedObject var frames: DemoFrames
    var body: some View {
        DemoDashboard(empty: false, active: frames.step != .done, tryingBackup: frames.step != .main)
            .id(frames.step)
    }
}
