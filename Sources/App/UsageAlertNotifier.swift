import Foundation
import UserNotifications

@MainActor
final class UsageAlertNotifier: ObservableObject {
    static let shared = UsageAlertNotifier()
    static let preferenceKey = "UsageAlertsEnabled"

    @Published var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: Self.preferenceKey)
            if alertsEnabled { requestAuthorizationIfNeeded() }
        }
    }

    private var engine = UsageAlertEngine()
    private var requestedAuthorization = false
    private let stateKey = "UsageAlertEngineNotifiedKeys"

    private init() {
        if UserDefaults.standard.object(forKey: Self.preferenceKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.preferenceKey)
        }
        self.alertsEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        if let saved = UserDefaults.standard.stringArray(forKey: stateKey) {
            engine.notifiedKeys = Set(saved)
        }
    }

    private var isLiveAppBundle: Bool {
        Bundle.main.bundleIdentifier == "com.moonlitnayeem.claude-switcher"
    }

    func observe(_ accounts: [RoutingAccountDisplay], now: Date = Date()) {
        let samples = accounts.map { row in
            UsageAlertAccountSample(
                id: row.id,
                name: row.nickname ?? row.name,
                isPrimary: row.isPrimary,
                fablePercent: row.fable?.percent,
                fableReset: row.fable?.resetAt ?? row.fableReset,
                weeklyPercent: row.weekly?.percent,
                weeklyReset: row.weekly?.resetAt,
                sessionPercent: row.session?.percent,
                sessionReset: row.session?.resetAt
            )
        }
        let events = engine.evaluate(samples, now: now)
        UserDefaults.standard.set(Array(engine.notifiedKeys), forKey: stateKey)
        guard alertsEnabled, isLiveAppBundle, !events.isEmpty else { return }
        requestAuthorizationIfNeeded()
        for event in events {
            post(event)
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard isLiveAppBundle, !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(_ event: UsageAlertEvent) {
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .primaryFableFull:
            content.title = L10n.text("Main reached its Fable limit")
            content.body = L10n.text("Claude Code switched to your backup automatically. Open AI Switcher to launch Chat or Cowork on your backup.")
        case .primaryWeeklyFull:
            content.title = L10n.text("Main reached its weekly limit")
            content.body = L10n.text("Claude Code switched to your backup automatically.")
        case .backupFable85:
            content.title = L10n.format("Backup Fable at %ld%%", event.percent)
            content.body = L10n.format("%@ has used %ld%% of its Fable allowance.", event.accountName, event.percent)
        case .backupFable95:
            content.title = L10n.format("Backup Fable nearly full (%ld%%)", event.percent)
            content.body = L10n.format("%@ has used %ld%% of its Fable allowance.", event.accountName, event.percent)
        case .backupFableFull:
            content.title = L10n.text("Backup reached its Fable limit")
            content.body = L10n.format("%@ reached 100%% of its Fable allowance.", event.accountName)
        case .fableReset:
            content.title = L10n.text("Fable allowance reset")
            content.body = L10n.format("%@ has fresh Fable allowance available again.", event.accountName)
        case .weeklyReset:
            content.title = L10n.text("Weekly allowance reset")
            content.body = L10n.format("%@ has fresh weekly allowance available again.", event.accountName)
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: event.dedupeKey, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
