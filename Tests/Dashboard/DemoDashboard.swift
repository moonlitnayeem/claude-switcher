import SwiftUI

struct DemoDashboard: View {
    let empty: Bool
    @State private var enabled = true
    @State private var queued = false

    var body: some View {
        let primary = RoutingAccountDisplay(id: "personal", name: "alex@example.com", isPrimary: true,
                                            state: L10n.text("Signed in"), weeklyUsed: empty ? nil : 96,
                                            fableReset: empty ? nil : Date(timeIntervalSince1970: 1_783_555_200),
                                            canRecheck: enabled, recheckPending: queued)
        let backup = RoutingAccountDisplay(id: "studio", name: "studio@example.org", isPrimary: false,
                                           state: L10n.text("Signed in"), weeklyUsed: 24)
        let snapshot = RoutingDisplay(
            title: L10n.text(enabled ? (empty ? "Add a backup account" : "Ready to switch") : "Switching is off"),
            detail: L10n.text(enabled
                ? (empty ? "Connect another account to start switching Claude Code requests."
                         : "Claude Code uses your primary account first. When it reaches a limit, an available backup can take over.")
                : "Turn it on to use backup accounts for Claude Code requests."),
            ready: enabled && !empty, accounts: empty ? [primary] : [primary, backup],
            lastAccount: empty ? nil : backup.name, lastModel: empty ? nil : "Fable 5.2",
            lastAnswered: empty ? nil : Date(timeIntervalSince1970: 1_783_348_200))
        RoutingPanel(data: snapshot, enabled: $enabled, canSwitch: true, recheck: { _ in queued = true }) {
            Label("Claude", systemImage: "laptopcomputer").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        } accountActions: {
            Menu { Text("Sign In to Another Account…") } label: {
                Label(empty ? "Add an Account" : "Add Another Account", systemImage: "plus")
            }.menuStyle(.borderlessButton).fixedSize().identified("shared-usage.add")
        } manage: { Button("Profile settings") {}.identified("routing.settings") }
    }
}
