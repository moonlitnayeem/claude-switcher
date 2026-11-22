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

precondition(automatic.report(for: "backup", from: "main")?.id == studio)
precondition(automatic.canRecheck("backup", from: "main"))
let aliasRechecked = try connection.recheck("backup", from: "main")
precondition(aliasRechecked)
print("Rechecking a reset at 99% weekly use targets the active handle for the displayed backup.")

let refusedRecheck = try connection.recheck("backup", from: "main")
precondition(!refusedRecheck)
let declined = connection.read()
precondition(declined.recheckFeedback(for: "backup", from: "main", declined: true)?.contains("may skip a check") == true)
precondition(declined.recheckFeedback(for: "backup", from: "main")?.contains("At least 99%") == true)
precondition(declined.recheckFeedback(for: "backup", from: "foreign") == nil)
let nextWeek = Date().addingTimeInterval(7 * 24 * 60 * 60)
precondition(declined.recheckFeedback(for: "backup", from: "main", now: nextWeek) == nil)
precondition(snapshot.recheckFeedback(for: "backup", from: "main") == nil)
var shortWindow = declined
let active = shortWindow.status!.members.firstIndex { $0.id == studio }!
shortWindow.status?.members[active].limits?.week = 0.2
shortWindow.status?.members[active].limits?.fiveHour = 0.98
shortWindow.status?.members[active].limits?.fiveHourReset = Date().addingTimeInterval(3600)
shortWindow.status?.members[active].limits?.fableRefusedUntil = nil
precondition(shortWindow.recheckFeedback(for: "backup", from: "main")?.contains("98%") == true)
shortWindow.status?.members[active].limits?.fiveHour = 1
precondition(shortWindow.recheckFeedback(for: "backup", from: "main")?.contains("account-wide limit") == true)
print("The dashboard distinguishes five-hour and weekly usage, an account-wide limit and a declined reset check.")

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

try checkClaudeUsageDisplay(in: root.appending(path: "display-fixture"))

// Backup Chat/Cowork profile app matching: matches by account UUID or unsigned-in email, never unrelated bundles.
do {
    let chatRoot = root.appending(path: "chat-profile-fixture")
    let appsDir = chatRoot.appending(path: "Apps")
    let profilesDir = chatRoot.appending(path: "profiles")
    let graftDir = chatRoot.appending(path: "ClaudeGraft")
    let fm = FileManager.default
    try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: profilesDir.appending(path: "Claude-backup"), withIntermediateDirectories: true)
    try fm.createDirectory(at: profilesDir.appending(path: "Claude-other"), withIntermediateDirectories: true)
    try fm.createDirectory(at: graftDir.appending(path: "pool"), withIntermediateDirectories: true)

    let backupUUID = UUID()
    let otherUUID = UUID()
    let backupShortcutID = UUID()
    let otherShortcutID = UUID()

    // Install a Graft shortcut bundle for Claude-backup (unsigned-in yet -> matched by email).
    let backupApp = appsDir.appending(path: "backup@example.org.app")
    try fm.createDirectory(at: backupApp.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
    let backupConfig = try JSONEncoder().encode(GraftConfig(profileDir: profilesDir.appending(path: "Claude-backup").path))
    try backupConfig.write(to: backupApp.appending(path: "Contents/Resources/graft.json"))

    // Install a shortcut for Claude-other signed into otherUUID with a misleading name matching backup's email.
    let otherApp = appsDir.appending(path: "Other.app")
    try fm.createDirectory(at: otherApp.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
    let otherConfig = try JSONEncoder().encode(GraftConfig(profileDir: profilesDir.appending(path: "Claude-other").path))
    try otherConfig.write(to: otherApp.appending(path: "Contents/Resources/graft.json"))
    try Data("{\"lastKnownAccountUuid\":\"\(otherUUID.uuidString)\"}".utf8)
        .write(to: profilesDir.appending(path: "Claude-other/config.json"))

    // Write usage-sharing, pool/accounts.json, and shortcuts.json.
    try Data("{\"lenders\":{\"main\":[\"account:\(backupUUID.uuidString)\"]},\"assignments\":{}}".utf8)
        .write(to: graftDir.appending(path: "usage-sharing.json"))
    try Data("[{\"id\":\"account:\(backupUUID.uuidString)\",\"accountUuid\":\"\(backupUUID.uuidString)\",\"email\":\"backup@example.org\"}]".utf8)
        .write(to: graftDir.appending(path: "pool/accounts.json"))
    let shortcutsJSON = """
    [
      {"id":"\(otherShortcutID.uuidString)","name":"backup@example.org","installedName":"Other","folder":"Claude-other"},
      {"id":"\(backupShortcutID.uuidString)","name":"backup@example.org","installedName":"backup@example.org","folder":"Claude-backup"}
    ]
    """
    try Data(shortcutsJSON.utf8).write(to: graftDir.appending(path: "shortcuts.json"))

    let chatConn = GraftConnection(root: graftDir, profileRoot: profilesDir, appDirectories: [appsDir])
    let snap = chatConn.read()
    let backupKey = "account:\(backupUUID.uuidString)"
    precondition(snap.chatProfileApp(for: "main", from: "main") == nil)
    precondition(snap.chatProfileApp(for: backupKey, from: "main").map { Graft.samePath($0, backupApp) } == true)

    // Once signed in with backupUUID, UUID matching takes priority even if renamed.
    try Data("{\"lastKnownAccountUuid\":\"\(backupUUID.uuidString)\"}".utf8)
        .write(to: profilesDir.appending(path: "Claude-backup/config.json"))
    let renamedApp = appsDir.appending(path: "Backup Renamed.app")
    try fm.moveItem(at: backupApp, to: renamedApp)
    let snapSignedIn = chatConn.read()
    precondition(snapSignedIn.chatProfileApp(for: backupKey, from: "main").map { Graft.samePath($0, renamedApp) } == true)
    print("Backup Chat/Cowork profile lookup resolves unsigned-in email matches and signed-in renamed bundles safely")
}
