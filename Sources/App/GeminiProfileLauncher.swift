import AppKit
import Foundation

struct GeminiAccountSlot: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String
    var id: Self { self }
    static let first = GeminiAccountSlot(rawValue: "first")!
    static let second = GeminiAccountSlot(rawValue: "second")!

    init() { rawValue = UUID().uuidString.lowercased() }

    init?(rawValue: String) {
        guard rawValue == "first" || rawValue == "second"
                || UUID(uuidString: rawValue)?.uuidString.lowercased() == rawValue else { return nil }
        self.rawValue = rawValue
    }
}

struct GeminiProfileIndex: Codable, Equatable {
    struct Profile: Codable, Equatable, Identifiable {
        let id: GeminiAccountSlot
        var label: String
        var removed = false

        var displayName: String {
            if !label.isEmpty { return label }
            return L10n.text(id == .second ? "Google Account 2" : "Google Account 1")
        }
    }

    private(set) var profiles: [Profile]
    private(set) var selectedID: GeminiAccountSlot?
    var available: [Profile] { profiles.filter { !$0.removed } }
    var removed: [Profile] { profiles.filter(\.removed) }
    var selected: Profile? { available.first { $0.id == selectedID } }

    init() {
        profiles = [.init(id: .first, label: ""), .init(id: .second, label: "")]
        selectedID = .first
    }

    func canUse(_ label: String, for id: GeminiAccountSlot? = nil) -> Bool {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= 48 && !profiles.contains {
            $0.id != id && $0.displayName.localizedCaseInsensitiveCompare(clean) == .orderedSame
        }
    }

    mutating func add(_ label: String) {
        guard canUse(label) else { return }
        let slot = GeminiAccountSlot()
        profiles.append(Profile(id: slot, label: label.trimmingCharacters(in: .whitespacesAndNewlines)))
        selectedID = slot
    }

    mutating func rename(_ id: GeminiAccountSlot, to label: String) {
        guard canUse(label, for: id), let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func select(_ id: GeminiAccountSlot) {
        if available.contains(where: { $0.id == id }) { selectedID = id }
    }

    mutating func setRemoved(_ removed: Bool, _ id: GeminiAccountSlot) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].removed = removed
        if !removed { selectedID = id }
        else if selectedID == id { selectedID = available.first?.id }
    }

    func nextName() -> String {
        var number = profiles.count + 1
        var proposed = L10n.format("Google Account %ld", number)
        while !canUse(proposed) {
            number += 1
            proposed = L10n.format("Google Account %ld", number)
        }
        return proposed
    }
}

enum GeminiLaunchError: LocalizedError {
    case desktopMissing
    case browserMissing
    case agyMissing
    case geminiCLIMissing
    case terminalMissing
    case invalidProfile
    case invalidProject

    var errorDescription: String? {
        switch self {
        case .desktopMissing:
            return L10n.text("Install Google Antigravity or Gemini for macOS to open the desktop app.")
        case .browserMissing:
            return L10n.text("Install Google Chrome to open isolated Gemini browser profiles, or use your default browser.")
        case .agyMissing:
            return L10n.text("Could not find the Antigravity CLI (agy). Install Antigravity or Gemini for macOS first.")
        case .geminiCLIMissing:
            return L10n.text("Install the Gemini CLI (brew install gemini-cli) to start a Gemini session in Terminal.")
        case .terminalMissing:
            return L10n.text("macOS Terminal could not be found.")
        case .invalidProfile:
            return L10n.text("This account folder could not be opened safely.")
        case .invalidProject:
            return L10n.text("This folder moved. Choose your project folder again.")
        }
    }
}

enum GeminiDesktop {
    static let bundleIDs = ["com.google.GeminiMacOS", "com.google.antigravity"]
    static let downloadURL = URL(string: "https://antigravity.google/")!
    static let geminiWebURL = URL(string: "https://gemini.google.com/app")!
    static let aiStudioURL = URL(string: "https://aistudio.google.com/")!
    static let geminiCLIDocsURL = URL(string: "https://github.com/google-gemini/gemini-cli")!

    static func installedURL() -> URL? {
        let fm = FileManager.default
        let roots = fm.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let named = roots.flatMap { root in
            ["Gemini.app", "Antigravity.app", "Google Antigravity.app"].map { root.appendingPathComponent($0) }
        }
        let registered = bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        return (named + registered).first { candidate in
            guard let id = Bundle(url: candidate)?.bundleIdentifier else { return false }
            return bundleIDs.contains(id)
        }
    }

    static func agyURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appHelpers = [
            "/Applications/Gemini.app/Contents/Helpers/agy",
            "/Applications/Antigravity.app/Contents/Helpers/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy",
        ].map(URL.init(fileURLWithPath:))
        let standard = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
        ]
        return (appHelpers + standard).first { url in
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && fm.isExecutableFile(atPath: url.path)
        }
    }

    static func geminiCLIURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/gemini"),
            URL(fileURLWithPath: "/opt/homebrew/bin/gemini"),
            URL(fileURLWithPath: "/usr/local/bin/gemini"),
        ]
        return candidates.first { url in
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && fm.isExecutableFile(atPath: url.path)
        }
    }

    @MainActor
    static func openDesktop(newInstance: Bool = false) async throws {
        guard let app = installedURL() else { throw GeminiLaunchError.desktopMissing }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}

struct GeminiProfileLauncher {
    let root: URL

    func directory(_ slot: GeminiAccountSlot, component: String) throws -> URL {
        let fm = FileManager.default
        var url = root
        for part in ["", slot.rawValue, component] {
            if !part.isEmpty { url.appendPathComponent(part, isDirectory: true) }
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                throw GeminiLaunchError.invalidProfile
            }
        }
        return url
    }

    func browserArguments(for slot: GeminiAccountSlot, destination: URL = GeminiDesktop.geminiWebURL) throws -> [String] {
        let browser = try directory(slot, component: "Browser")
        return [
            "--user-data-dir=" + browser.path,
            "--no-first-run",
            "--no-default-browser-check",
            "--new-window",
            destination.absoluteString,
        ]
    }

    @MainActor
    func openBrowser(_ slot: GeminiAccountSlot, destination: URL = GeminiDesktop.geminiWebURL) async throws {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw GeminiLaunchError.browserMissing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = try browserArguments(for: slot, destination: destination)
        _ = try await NSWorkspace.shared.openApplication(at: chrome, configuration: configuration)
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func geminiCLICommand(for slot: GeminiAccountSlot, executable: URL, project: URL) throws -> URL {
        guard project.isFileURL,
              (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw GeminiLaunchError.invalidProject
        }
        let cliHome = try directory(slot, component: "GeminiCLI")
        let launchers = try directory(slot, component: "Launchers")
        let shell = Self.quoted
        let script = """
        #!/bin/zsh
        set -eu
        /bin/unlink "$0"
        cd -- \(shell(project.path))
        exec /usr/bin/env GEMINI_CLI_HOME=\(shell(cliHome.path)) \(shell(executable.path))
        """
        let file = launchers.appendingPathComponent("GeminiCLI-" + UUID().uuidString + ".command")
        try Data(script.utf8).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    func agyCommand(for slot: GeminiAccountSlot, accountLabel: String?, executable: URL, project: URL) throws -> URL {
        guard project.isFileURL,
              (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw GeminiLaunchError.invalidProject
        }
        let launchers = try directory(slot, component: "Launchers")
        let shell = Self.quoted
        let cleanAccount = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let accountEnv = cleanAccount.isEmpty ? "" : "AGY_ACCOUNT=\(shell(cleanAccount)) "
        let script = """
        #!/bin/zsh
        set -eu
        /bin/unlink "$0"
        cd -- \(shell(project.path))
        exec /usr/bin/env \(accountEnv)\(shell(executable.path))
        """
        let file = launchers.appendingPathComponent("Antigravity-" + UUID().uuidString + ".command")
        try Data(script.utf8).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @MainActor
    func openGeminiCLI(_ slot: GeminiAccountSlot, project: URL) async throws {
        guard let binary = GeminiDesktop.geminiCLIURL() else { throw GeminiLaunchError.geminiCLIMissing }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw GeminiLaunchError.terminalMissing
        }
        let file = try geminiCLICommand(for: slot, executable: binary, project: project)
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    @MainActor
    func openAntigravityCLI(_ slot: GeminiAccountSlot, accountLabel: String?, project: URL) async throws {
        guard let binary = GeminiDesktop.agyURL() else { throw GeminiLaunchError.agyMissing }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw GeminiLaunchError.terminalMissing
        }
        let file = try agyCommand(for: slot, accountLabel: accountLabel, executable: binary, project: project)
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
