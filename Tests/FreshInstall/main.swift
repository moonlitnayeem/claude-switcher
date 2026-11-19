import AppKit
import Foundation

// Run on a clean macOS runner. Launching the production delegate on a developer's
// signed-in Mac would start its real account and profile observers.
let files = FileManager.default
let home = files.homeDirectoryForCurrentUser
let support = home.appendingPathComponent("Library/Application Support")
let appName = "Claude Graft.app"
let cleanPaths = [
    URL(fileURLWithPath: "/Applications").appendingPathComponent(appName),
    home.appendingPathComponent("Applications").appendingPathComponent(appName),
    support.appendingPathComponent("ClaudeGraft"),
    support.appendingPathComponent("Claude"),
    support.appendingPathComponent("ClaudeSwitcher")
]
guard cleanPaths.allSatisfy({ !files.fileExists(atPath: $0.path) }) else {
    fatalError("Use a fresh macOS runner for this check.")
}
let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard let executable = Bundle(url: app)?.executableURL else { fatalError("Missing app executable") }
let process = Process()
process.executableURL = executable
try process.run()
defer {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
}

let deadline = Date().addingTimeInterval(25)
var launched = false
while process.isRunning && Date() < deadline {
    if let running = NSRunningApplication(processIdentifier: process.processIdentifier),
       running.isFinishedLaunching, running.bundleURL?.standardizedFileURL.path == app.path {
        launched = true
        break
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
guard launched else { fatalError("AI Switcher did not complete its first launch") }
print("AI Switcher completed its first launch with no Claude Graft app or saved Graft setup.")
