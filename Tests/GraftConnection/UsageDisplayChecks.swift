import Foundation

func checkClaudeUsageDisplay(in support: URL) throws {
    typealias Display = ClaudeUsageDisplay
    let original = Graft.applicationSupportOverride
    Graft.applicationSupportOverride = support
    defer { Graft.applicationSupportOverride = original }
    let example = """
    No usage yet. 100% of your weekly limit is available.
    Current session
    Starts with your first message
    0% used
    This week
    Resets Wednesday 1:00 AM
    0% used
    Fable
    Up to 50% of your weekly limit
    Resets Wednesday 1:00 AM
    0% used
    Limit resets
    """
    precondition(Display.parse(example) == .init(weekly: 0, fable: 0))
    let separated = """
    Current session
    97% used
    This week
    Resets Wednesday 1:00 AM
    32% used
    Fable
    Up to 50% of your weekly limit
    Usage credits
    68% used
    """
    precondition(Display.parse(separated) == .init(weekly: 32, fable: nil))
    precondition(Display.parse("This week\n100% available\nFable\n18 % used") == .init(weekly: nil, fable: 18))
    precondition(Display.parse("Fable\n101% used\nCurrent session\n0% used").isEmpty)
    precondition(Display.parse("Fable\n-1% used\nThis week\n1.5% used").isEmpty)
    precondition(Display.parse("This week\n20% used\nThis week\n25% used\nFable\n7% used") == .init(weekly: nil, fable: 7))
    let account = UUID(), otherAccount = UUID()
    let now = Date().addingTimeInterval(-300)
    let earlier = now.addingTimeInterval(-60)
    let later = now.addingTimeInterval(60)
    try Display.save(Display.parse(example), account: account, source: .claudeUsagePage, observedAt: earlier)
    try Display.save(.init(weekly: nil, fable: 7), account: account, observedAt: now)
    try Display.save(.init(weekly: 99, fable: 99), account: account, observedAt: earlier.addingTimeInterval(-1))
    let local = Display.load(account: account, now: later)
    precondition(local.weekly == .init(percent: 0, observedAt: earlier, source: .claudeUsagePage))
    precondition(local.fable == .init(percent: 7, observedAt: now, source: .copiedFromClaude))
    precondition(Display.load(account: otherAccount, now: later) == .init())
    let freshRelay = Display.Metric(percent: 76, observedAt: now, source: .relay)
    let freshRelayFable = Display.Metric(percent: 9, observedAt: later, source: .relay)
    let combined = Display.load(account: account, relayWeekly: freshRelay, now: later)
    precondition(combined.weekly == freshRelay && combined.fable == local.fable)
    let combinedFable = Display.load(account: account, relayWeekly: freshRelay, relayFable: freshRelayFable, now: later)
    precondition(combinedFable.weekly == freshRelay && combinedFable.fable == freshRelayFable)
    let staleRelayFable = Display.Metric(percent: 3, observedAt: earlier, source: .relay)
    precondition(Display.load(account: account, relayFable: staleRelayFable, now: later).fable == local.fable)
    let tied = Display.Metric(percent: 76, observedAt: earlier, source: .relay)
    precondition(Display.load(account: account, relayWeekly: tied, now: later).weekly == local.weekly)
    let staleTime = earlier.addingTimeInterval(5 * 60 * 60)
    precondition(Display.load(account: account, relayWeekly: tied, now: staleTime) == .init(weekly: nil, fable: local.fable))
    precondition(Display.load(account: account, relayWeekly: freshRelay, now: now.addingTimeInterval(5 * 60 * 60)) == .init())
    precondition(Display.load(account: otherAccount, relayWeekly: .init(percent: 0, observedAt: later, source: .relay), now: now) == .init())
    let file = Graft.graftFolder.appending(path: "display-usage/").appending(path: account.uuidString.lowercased() + ".json")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    precondition(mode == 0o600)
    do {
        try Display.save(.init(weekly: -1, fable: 101), account: account)
        preconditionFailure("An impossible percentage must not replace an earlier reading")
    } catch {}
    try Display.clear(account: otherAccount)
    precondition(Display.load(account: account, now: later) == local)
    try Display.clear(account: account)
    try Display.clear(account: account)
    precondition(Display.load(account: account, now: later) == .init())
    try checkGraftObservations(in: support, account: account, now: now)
    print("Weekly and Fable readings stay in their own account and expire separately. Limit descriptions and usage credits supply no percentage.")
}

private func checkGraftObservations(in folder: URL, account: UUID, now: Date) throws {
    typealias Display = ClaudeUsageDisplay
    let report = folder.appending(path: "usage-status.json")
    let clock = ISO8601DateFormatter()
    let time = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    let sample: [String: Any] = ["accountUuid": account.uuidString, "live": true,
                                 "refreshedAt": clock.string(from: time), "week": 0, "fable": 0,
                                 "weekReset": clock.string(from: time.addingTimeInterval(1200))]
    func read(_ rows: [[String: Any]]) throws -> [UUID: Display.Reading] {
        let data = try JSONSerialization.data(withJSONObject: ["profiles": rows, "checkedAt": clock.string(from: time)])
        try data.write(to: report, options: .atomic)
        return Display.graftReadings(at: report, now: time)
    }
    func changed(_ updates: [String: Any]) -> [String: Any] { sample.merging(updates) { _, new in new } }
    let zero = Display.Metric(percent: 0, observedAt: time, source: .graftUsage)
    let base = try read([sample])
    precondition(base[account] == .init(weekly: zero, fable: zero))
    let other = UUID()
    let different = try read([changed(["accountUuid": other.uuidString])])
    precondition(different[account] == nil && different[other]?.fable == zero)
    let untrusted = try read([sample.filter { $0.key != "accountUuid" }, changed(["live": false]),
                              changed(["live": 1]), changed(["note": "Showing a stored reading"]),
                              changed(["refreshedAt": clock.string(from: time.addingTimeInterval(-18_000))]),
                              changed(["refreshedAt": clock.string(from: time.addingTimeInterval(60))]),
                              changed(["refreshedAt": clock.string(from: time) + "invalid"]),
                              changed(["name": account.uuidString, "accountUuid": "unknown"])])
    precondition(untrusted.isEmpty)
    let noWeek = try read([changed(["weekReset": clock.string(from: time)])])
    precondition(noWeek[account] == .init(weekly: nil, fable: zero))
    let noFable = try read([changed(["fableReset": "unknown"])])
    precondition(noFable[account] == .init(weekly: zero, fable: nil))
    let badWeekly = try read([changed(["week": 101])])
    let badFable = try read([changed(["fable": true])])
    let notNumbers = try read([changed(["week": 1.5, "fable": "0"])])
    precondition(badWeekly[account]?.weekly == nil && badWeekly[account]?.fable == zero)
    precondition(badFable[account]?.weekly == zero && badFable[account]?.fable == nil)
    precondition(notNumbers.isEmpty)
    try Display.save(.init(weekly: 15, fable: 43), account: account, source: .claudeUsagePage, observedAt: time)
    let older = changed(["refreshedAt": clock.string(from: time.addingTimeInterval(-60)), "week": 70, "fable": 88])
    let oldReport = try read([older])
    let fromPage = Display.load(account: account, graftReading: oldReport[account], now: time)
    precondition(fromPage.weekly?.percent == 15 && fromPage.fable?.percent == 43)
    let justFable = sample.filter { $0.key != "week" }
    let mixed = try read([justFable, older])
    precondition(mixed[account]?.weekly?.percent == 70 && mixed[account]?.fable == zero)
    try Display.clear(account: account)
    try Display.save(.init(weekly: 15, fable: 43), account: account, observedAt: time.addingTimeInterval(-30))
    let afterSample = Display.load(account: account, graftReading: mixed[account], now: time)
    precondition(afterSample.weekly?.percent == 15 && afterSample.fable == zero)
    try Display.clear(account: account)
    let afterClear = Display.load(account: account, graftReading: mixed[account], now: time)
    precondition(afterClear == mixed[account])
    print("Only fresh measurements tied to the observed account can replace a usage-page figure in the same window.")
}
