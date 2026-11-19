import AppKit
import Foundation

enum OpenAIAccountSlot: String, CaseIterable, Identifiable {
    case first, second
    var id: Self { self }
    var title: String { self == .first ? OpenAICopy.text("Account 1") : OpenAICopy.text("Account 2") }
}

enum OpenAICopy {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "OpenAIAccounts")
    }
}

enum OpenAILaunchError: LocalizedError {
    case browserMissing, codexMissing, terminalMissing, invalidProfile

    var errorDescription: String? {
        switch self {
        case .browserMissing: return OpenAICopy.text("Install Google Chrome to use separate ChatGPT windows, or open ChatGPT in your usual browser.")
        case .codexMissing: return OpenAICopy.text("Install the Codex command-line app to start a session in Terminal.")
        case .terminalMissing: return OpenAICopy.text("macOS Terminal could not be found.")
        case .invalidProfile: return OpenAICopy.text("This account folder could not be opened safely.")
        }
    }
}

struct OpenAIProfileLauncher {
    static let chatURL = URL(string: "https://chatgpt.com/")!
    static let helpURL = URL(string: "https://help.openai.com/en/articles/20001068-using-multiple-chatgpt-accounts-on-web-and-mobile")!
    static let cliURL = URL(string: "https://developers.openai.com/codex/cli/")!

    let root: URL

    func directory(_ slot: OpenAIAccountSlot, component: String) throws -> URL {
        let fm = FileManager.default
        var url = root
        for part in ["", slot.rawValue, component] {
            if !part.isEmpty { url.appendPathComponent(part, isDirectory: true) }
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw OpenAILaunchError.invalidProfile }
        }
        return url
    }

    static func codexURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let installed = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
        let candidates = [home.appendingPathComponent(".local/bin/codex"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                          URL(fileURLWithPath: "/usr/local/bin/codex")] + installed.flatMap { path in
            ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"].map {
                URL(fileURLWithPath: path).appendingPathComponent($0)
            }
        }
        return candidates.first { url in
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && fm.isExecutableFile(atPath: url.path)
        }
    }

    func chatArguments(for slot: OpenAIAccountSlot) throws -> [String] {
        let browser = try directory(slot, component: "Browser")
        return ["--user-data-dir=" + browser.path, "--no-first-run", "--no-default-browser-check",
                "--new-window", Self.chatURL.absoluteString]
    }

    @MainActor
    func openChat(_ slot: OpenAIAccountSlot) async throws {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        else { throw OpenAILaunchError.browserMissing }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = try chatArguments(for: slot)
        _ = try await NSWorkspace.shared.openApplication(at: chrome, configuration: configuration)
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func codexCommand(for slot: OpenAIAccountSlot, executable: URL, project: URL) throws -> URL {
        let codexHome = try directory(slot, component: "Codex")
        let launchers = try directory(slot, component: "Launchers")
        let shell = Self.quoted
        // Terminal may start from an existing login shell. Pass a small, explicit environment
        // so a shell's API key, daemon address or profile cannot select a different account.
        let script = """
        #!/bin/zsh
        set -eu
        /bin/unlink "$0"
        run_codex() {
          /usr/bin/env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL="${SHELL:-/bin/zsh}" \\
            TERM="${TERM:-xterm-256color}" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \\
            PATH="$PATH" CODEX_HOME=\(shell(codexHome.path)) \\
            \(shell(executable.path)) -c 'cli_auth_credentials_store="file"' "$@"
        }
        cd -- \(shell(codexHome.path))
        if ! run_codex login status >/dev/null 2>&1; then
          run_codex login
        fi
        cd -- \(shell(project.path))
        if run_codex --help | /usr/bin/grep -Fq -- '--no-daemon'; then
          run_codex --no-daemon
        else
          run_codex
        fi
        """
        // Terminal opens documents asynchronously. A unique launcher preserves the selected
        // folder even when two windows for the same account are opened in quick succession.
        let file = launchers.appendingPathComponent("Codex-" + UUID().uuidString + ".command")
        try Data(script.utf8).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @MainActor
    func openCodex(_ slot: OpenAIAccountSlot, project: URL) async throws {
        guard let binary = Self.codexURL() else { throw OpenAILaunchError.codexMissing }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { throw OpenAILaunchError.terminalMissing }
        let file = try codexCommand(for: slot, executable: binary, project: project)
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
