import Foundation

// The fixture's old relay has no activeRoutes field and never sends credentials.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let connection = GraftConnection(root: root, profileRoot: root.appending(path: "profiles"))
let snapshot = connection.read()
let cutoff = Date().addingTimeInterval(-60)
let main = snapshot.accounts(for: "main")
let studio = snapshot.profiles.last!
let lenders = main.members.dropFirst()
precondition(snapshot.settingsFound && Array(lenders) == ["backup"] && snapshot.profiles.count == 2)
precondition(snapshot.names.values.contains("Studio"))
precondition(main.members == ["main","backup"] && main.canonical("main-alias") == "main")
precondition(main.canonical(studio) == "backup" && main.canonical("retired") == "retired")
precondition(snapshot.accounts(for: studio).members == [studio])
precondition(snapshot.email(for: "main", from: "main") == "first@example.org")
precondition(snapshot.email(for: "backup", from: "main") == "second@example.org")
precondition(snapshot.email(for: studio, from: studio) == "second@example.org")
precondition(snapshot.email(for: "main", from: studio) == nil)
precondition(snapshot.accountLabels["unused"] == nil)
precondition(!snapshot.canRecheck("main-alias", from: "main"))
let unidentified = RoutingAccountIdentity(primary: "main", lenders: ["main", "one", "two", "one"], accountUUIDs: [:])
precondition(unidentified.members == ["main","one","two"])
print("The main account and each backup appear once and route aliases resolve per profile")
precondition(snapshot.status?.enabled == true && snapshot.status?.activeRoutes == nil)
let fable = snapshot.status?.recent.last
precondition(fable?.model == "claude-fable-5-2" && fable?.servedBy == lenders.first && fable?.status == 200)
precondition((fable?.at ?? .distantPast) > cutoff)
precondition(snapshot.status?.members.first(where: { $0.id == "main" })?.limits?.week == 1)
precondition(snapshot.canRecheck("backup", from: "main") && !snapshot.canRecheck("main", from: "main"))
precondition(!snapshot.canRecheck("backup", from: "foreign"))
let forbidden = try connection.recheck("backup", from: "foreign")
precondition(!forbidden)
let accepted = try connection.recheck("backup", from: "main")
precondition(accepted)
print("Graft setup, reported backup answer and scoped reset checks passed")

precondition(!snapshot.canSetRoutingMode(for: "main"))
do {
    _ = try connection.setExclusiveAccount("main", for: "main")
    preconditionFailure("A helper without account controls accepted a change")
} catch AccountControlError.unavailable {}
let restricted = try connection.setExclusiveAccount("backup", for: "main")
precondition(restricted.exclusiveAccount(for: "main") == "backup")
precondition(restricted.canSelectAccount("main", for: "main") && restricted.canSelectAccount("backup", for: "main"))
precondition(!restricted.canSelectAccount("foreign", for: "main"))
let reread = connection.read()
precondition(reread.canSetRoutingMode(for: "main") && reread.exclusiveAccount(for: "main") == "backup")
do {
    _ = try connection.setExclusiveAccount("foreign", for: "main")
    preconditionFailure("A row outside the profile's account list was accepted")
} catch AccountControlError.invalidAccount {}
let primaryOnly = try connection.setExclusiveAccount("main-alias", for: "main")
precondition(primaryOnly.exclusiveAccount(for: "main") == "main")
do {
    _ = try connection.setExclusiveAccount(nil, for: "main")
    preconditionFailure("An ignored command was shown as applied")
} catch AccountControlError.unconfirmed {}
let automatic = try connection.setExclusiveAccount(nil, for: "main")
precondition(automatic.exclusiveAccount(for: "main") == nil && automatic.canSetRoutingMode(for: "main"))
precondition(automatic.accounts(for: "main").members == main.members)
print("Account controls require a compatible helper, a configured account and the requested mode in its reply")

let disconnected = GraftConnection(root: root.appending(path: "absent"))
precondition(disconnected.read().status == nil && !disconnected.read().settingsFound)
precondition(!FileManager.default.fileExists(atPath: disconnected.root.path))
print("Disconnected reader leaves the filesystem untouched")
let inventory = root.appending(path: "pool/accounts.json")
try Data("broken".utf8).write(to: inventory)
precondition(GraftAccountLabel.assignedEntries(in: root, ids: ["backup"]).isEmpty)
try FileManager.default.removeItem(at: inventory)
precondition(GraftAccountLabel.assignedEntries(in: root, ids: ["backup"]).isEmpty)
print("Only assigned email labels are returned and stale labels disappear after a missing or damaged inventory")

// The same local identifier can refer to different accounts in the two routing modes.
let domain = "ai-switcher-fixture." + UUID().uuidString
let prefs = UserDefaults(suiteName: domain)!
defer { prefs.removePersistentDomain(forName: domain) }
let labels = ClaudeAccountLabels(scope: "graft", defaults: prefs)
let standalone = ClaudeAccountLabels(scope: "standalone", defaults: prefs)
labels.set("  School  ", for: "main")
standalone.set("Work", for: "main")
precondition(labels.nickname(for: "main") == "School" && standalone.nickname(for: "main") == "Work")
precondition(ClaudeAccountLabels(scope: "graft", defaults: prefs).nickname(for: "main") == "School")
labels.set(String(repeating: "x", count: 65), for: "main")
labels.set("multi\nline", for: "main")
precondition(labels.nickname(for: "main") == "School")
labels.set("  ", for: "main")
precondition(ClaudeAccountLabels(scope: "graft", defaults: prefs).nickname(for: "main") == nil)
print("Local account labels survive relaunch, preserve the other mode, and clear without changing accounts")
