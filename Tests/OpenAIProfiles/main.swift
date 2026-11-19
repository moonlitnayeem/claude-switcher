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
print("\(checks) account profile checks passed")
