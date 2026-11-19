import AppKit

enum ClaudeAppLauncher {
    static let bundleID = "com.anthropic.claudefordesktop"

    enum DesktopTarget: Equatable { case running(pid_t), launch, confirmMainWindow }

    enum Failure: LocalizedError {
        case desktopMissing, couldNotFocus, cliMissing, terminalMissing
        var errorDescription: String? {
            let key: String
            switch self {
            case .desktopMissing: key = "Claude Desktop could not be found. Install Claude Desktop and try again."
            case .couldNotFocus: key = "Claude Desktop could not be brought forward. Try opening it again."
            case .cliMissing: key = "The Claude Code command-line app could not be found on this Mac."
            case .terminalMissing: key = "macOS Terminal could not be found."
            }
            return L10n.text(key)
        }
    }

    static func desktopTarget(_ instances: [(id: pid_t, command: String)]) -> DesktopTarget {
        // Shortcuts run the same signed app on a different user-data-dir. Activating by bundle ID
        // alone can bring a completely different account forward.
        if let main = instances.first(where: {
            !$0.command.isEmpty && (!$0.command.contains("--user-data-dir") || Graft.carriesDataDir($0.command, Graft.mainProfile))
        }) {
            return .running(main.id)
        }
        return instances.isEmpty ? .launch : .confirmMainWindow
    }

    static func installedDesktop(_ candidates: [URL]) -> URL? {
        candidates.first { Bundle(url: $0)?.bundleIdentifier == bundleID }
    }

    /// False asks the UI to confirm opening a separate main window beside another profile.
    @MainActor static func openDesktop(allowSeparateWindow: Bool = false) async throws -> Bool {
        let active = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        let pids = active.map(\.processIdentifier)
        let instances = await Task.detached(priority: .userInitiated) {
            pids.map { pid in (id: pid, command: Graft.output("/bin/ps", ["-p", String(pid), "-o", "command="])
                .trimmingCharacters(in: .whitespacesAndNewlines)) }
        }.value
        switch desktopTarget(instances) {
        case .running(let pid):
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID,
                  Graft.reveal(pid: pid) else { throw Failure.couldNotFocus }
            return true
        case .confirmMainWindow where !allowSeparateWindow:
            return false
        default:
            let preferred = URL(fileURLWithPath: "/Applications/Claude.app")
            let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            guard let url = installedDesktop([preferred, registered, Graft.claudeApp].compactMap { $0 })
            else { throw Failure.desktopMissing }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        }
    }

    static func cliURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        let directories = [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
                           URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".claude/local")]
            + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        return directories.map { $0.appendingPathComponent("claude") }.first {
            (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func terminalCommand(executable: URL, project: URL, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let file = directory.appendingPathComponent("AI Switcher - Claude " + UUID().uuidString + ".command")
        let script = """
        #!/bin/zsh
        set -eu
        /bin/unlink "$0"
        cd -- \(quote(project.path))
        exec \(quote(executable.path))
        """
        try Data(script.utf8).write(to: file, options: .withoutOverwriting)
        do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        return file
    }

    @MainActor static func openCLI(project: URL) async throws {
        guard let executable = cliURL() else { throw Failure.cliMissing }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { throw Failure.terminalMissing }
        let script = try terminalCommand(executable: executable, project: project)
        do { _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init()) }
        catch { try? FileManager.default.removeItem(at: script); throw error }
    }
}
