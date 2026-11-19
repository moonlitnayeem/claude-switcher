import Foundation

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("AI-Switcher-Accounts-" + UUID().uuidString)
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }
var checks = 0
func check(_ result: Bool, _ description: String) {
    guard result else { fatalError(description) }
    checks += 1
}
let manager = OpenAIProfileLauncher(root: scratch.appendingPathComponent("Local profiles"))
let a = try manager.chatArguments(for: .first)
let b = try manager.chatArguments(for: .second)
let again = try manager.chatArguments(for: .first)
check(a == again, "the same account opens the same browser profile")
check(a != b && a.first?.hasPrefix("--user-data-dir=") == true, "different accounts use different browser folders")
check(a.last == "https://chatgpt.com/" && b.last == a.last, "both accounts open the official ChatGPT site")
let fake = scratch.appendingPathComponent("Codex's test CLI")
let script = #"""
#!/bin/sh
set -eu
test -z "${OPENAI_API_KEY:-}" && test -z "${CODEX_ACCESS_TOKEN:-}" || exit 40
[ "$1" = "-c" ] && [ "$2" = 'cli_auth_credentials_store="file"' ] || exit 41
shift 2
case "$*" in
  "login status") test -f "$CODEX_HOME/signed-in" ;;
  "login") touch "$CODEX_HOME/signed-in"; echo login >> "$CODEX_HOME/check.log" ;;
  "--help") echo "--no-daemon" ;;
  "--no-daemon") pwd -P >> "$CODEX_HOME/check.log" ;;
  *) exit 42 ;;
esac
"""#
try Data(script.utf8).write(to: fake)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
let firstProject = scratch.appendingPathComponent("Project's $(never-executed)")
let secondProject = scratch.appendingPathComponent("Another project")
for url in [firstProject, secondProject] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
func run(_ executable: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    var environment = ProcessInfo.processInfo.environment
    environment["OPENAI_API_KEY"] = "synthetic-token-never-use"
    environment["CODEX_ACCESS_TOKEN"] = "synthetic-token-never-use"
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let firstLaunch = try manager.codexCommand(for: .first, executable: fake, project: firstProject)
let repeatLaunch = try manager.codexCommand(for: .first, executable: fake, project: secondProject)
let otherLaunch = try manager.codexCommand(for: .second, executable: fake, project: firstProject)
check(firstLaunch != repeatLaunch && firstLaunch != otherLaunch, "quickly opening multiple windows preserves each choice")
for command in [firstLaunch, repeatLaunch, otherLaunch] {
    check(try run(command) == 0, "Terminal launches Codex without inheriting credentials")
    check(!fm.fileExists(atPath: command.path), "each temporary launcher removes itself")
}
func log(_ slot: OpenAIAccountSlot) throws -> [String] {
    let file = try manager.directory(slot, component: "Codex").appendingPathComponent("check.log")
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
}
func physicalPath(_ url: URL) -> String {
    let path = realpath(url.path, nil)!
    defer { free(path) }
    return String(cString: path)
}
let firstPath = physicalPath(firstProject)
let secondPath = physicalPath(secondProject)
check(try log(.first) == ["login", firstPath, secondPath], "a returning account keeps its own login and opens the selected project")
check(try log(.second) == ["login", firstPath], "a second account signs in independently")
let relocated = scratch.appendingPathComponent("Symlink")
try fm.createSymbolicLink(at: relocated, withDestinationURL: scratch)
var rejected = false
do { _ = try OpenAIProfileLauncher(root: relocated).chatArguments(for: .first) } catch { rejected = true }
check(rejected, "a symbolic link cannot substitute another user's profile folder")
var index = OpenAIProfileIndex(legacyFirst: "Home", legacySecond: "Studio", legacySelection: "second")
check(index.available.map(\.displayName) == ["Home", "Studio"] && index.selectedID == .second,
      "the upgrade keeps the original sign-ins, names and selected account")
check(try manager.chatArguments(for: index.available[0].id) == a && manager.chatArguments(for: index.available[1].id) == b,
      "upgrading uses the original browser directories for both accounts")
for number in 3...32 { index.add("Profile \(number)") }
check(index.available.count == 32 && Set(index.available.map(\.id)).count == 32,
      "people can keep adding independently identified accounts")
let third = index.available[2]
let thirdChat = try manager.chatArguments(for: third.id)
let thirdCodex = try manager.directory(third.id, component: "Codex")
check(thirdChat != a && thirdChat != b && thirdCodex.path.contains(third.id.rawValue),
      "an added account has its own persistent browser and Codex directories")
let sameProject = try manager.codexCommand(for: third.id, executable: fake, project: firstProject)
check(try run(sameProject) == 0 && log(third.id) == ["login", firstPath],
      "an additional account can work directly on the same local project files in its own session")
index.rename(third.id, to: "  School  ")
let renamedChat = try manager.chatArguments(for: third.id)
check(index.available[2].displayName == "School" && renamedChat == thirdChat,
      "renaming keeps the established account’s sign-in locations")
index.add("SCHOOL")
check(index.available.count == 32 && !index.canUse(" ") && !index.canUse(String(repeating: "x", count: 49)),
      "duplicate, empty and oversized account names cannot be added")
index.select(third.id)
index.setRemoved(true, third.id)
check(index.available.count == 31 && index.selectedID == .first && index.removed.first?.id == third.id,
      "removing a selected name chooses another visible account")
let replay = try JSONDecoder().decode(OpenAIProfileIndex.self, from: JSONEncoder().encode(index))
check(replay == index, "selection, names and removed accounts survive relaunch")
index.setRemoved(false, third.id)
let restoredChat = try manager.chatArguments(for: third.id)
check(index.selectedID == third.id && index.selected?.label == "School" && restoredChat == thirdChat,
      "restoring a name restores its sign-ins and selects that account")
for profile in index.available { index.setRemoved(true, profile.id) }
check(index.selected == nil && index.available.isEmpty, "removing the final account leaves an empty list")
index.add("New")
check(index.selected?.label == "New" && index.removed.count == 32, "adding works after the last removal and preserves other sign-ins")
check(OpenAIAccountSlot(rawValue: "../other") == nil
        && (try? JSONDecoder().decode(OpenAIAccountSlot.self, from: Data(#""../other""#.utf8))) == nil,
      "persisted account IDs cannot point outside a profile directory")
let desktopProject = scratch.appendingPathComponent("Room + Café? a&b#1%")
try fm.createDirectory(at: desktopProject, withIntermediateDirectories: true)
let nativeLink = try OpenAIDesktop.projectURL(desktopProject)
let linkParts = URLComponents(url: nativeLink, resolvingAgainstBaseURL: false)
check(linkParts?.scheme == "codex" && linkParts?.host == "threads" && linkParts?.path == "/new",
      "desktop opens a fresh native Codex composer")
let targetItems = linkParts?.queryItems ?? []
let decodedFolder = targetItems.first?.value.map { URL(fileURLWithPath: $0, isDirectory: true) }
check(targetItems.count == 1 && targetItems.first?.name == "path"
      && decodedFolder.flatMap { fm.fileExists(atPath: $0.path) ? physicalPath($0) : nil } == physicalPath(desktopProject),
      "the native handoff supplies only the selected local folder, with no prompt or account override")
check(nativeLink.absoluteString.contains("%2B") && nativeLink.absoluteString.contains("%26")
      && nativeLink.absoluteString.contains("%23") && nativeLink.absoluteString.contains("%25"),
      "project names with form punctuation survive the desktop app URL parser")
check((try? OpenAIDesktop.projectURL(fake)) == nil && (try? OpenAIDesktop.projectURL(scratch.appendingPathComponent("missing"))) == nil,
      "desktop rejects missing folders and non-folder selections")
var refusedApp = false
do { try OpenAIDesktop.verify(fake) } catch { refusedApp = true }
check(refusedApp, "the desktop launcher rejects an unsigned target")
if ProcessInfo.processInfo.environment["AI_SWITCHER_VERIFY_DESKTOP"] == "1" {
    guard let app = OpenAIDesktop.installedURL() else { fatalError("The official desktop app could not be located") }
    try OpenAIDesktop.verify(app)
    check(Bundle(url: app)?.bundleIdentifier == OpenAIDesktop.bundleID, "the installed native app matches the expected OpenAI signature and bundle")
    print("Verified desktop app:", app.lastPathComponent)
}
print("\(checks) account profile checks passed")
