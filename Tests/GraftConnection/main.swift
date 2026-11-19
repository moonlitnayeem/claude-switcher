import Foundation

// The fixture's old relay has no activeRoutes field and never sends credentials.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let connection = GraftConnection(root: root)
let snapshot = connection.read()
let cutoff = Date().addingTimeInterval(-60)
let lenders = snapshot.lenders["main"] ?? []
precondition(snapshot.settingsFound && lenders == ["backup"] && snapshot.profiles.count == 2)
precondition(snapshot.names.values.contains("Studio"))
precondition(snapshot.accountLabels == ["backup": "second@example.org"])
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

let disconnected = GraftConnection(root: root.appending(path: "absent"))
precondition(disconnected.read().status == nil && !disconnected.read().settingsFound)
precondition(!FileManager.default.fileExists(atPath: disconnected.root.path))
print("Disconnected reader leaves the filesystem untouched")
let inventory = root.appending(path: "pool/accounts.json")
try Data("broken".utf8).write(to: inventory)
precondition(GraftAccountLabel.assigned(in: root, ids: ["backup"]).isEmpty)
try FileManager.default.removeItem(at: inventory)
precondition(GraftAccountLabel.assigned(in: root, ids: ["backup"]).isEmpty)
print("Only assigned email labels are returned and stale labels disappear after a missing or damaged inventory")
