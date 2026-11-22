import AppKit
import Foundation
import SwiftUI
import WebKit

struct BackupSignInTarget: Identifiable {
    let id: String
    let accountName: String
    let appURL: URL
    let profileDir: URL
}

enum BackupProfileError: LocalizedError {
    case missingLauncher
    case invalidName
    case writeFailed(String)
    case backupNotRunning
    case deliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingLauncher:
            return L10n.text("This copy of AI Switcher is missing its launcher binary.")
        case .invalidName:
            return L10n.text("Could not determine a valid profile folder name for this backup account.")
        case .writeFailed(let detail):
            return L10n.format("Could not create the backup Claude profile app: %@", detail)
        case .backupNotRunning:
            return L10n.text("Open the backup Claude window first so it can receive the sign-in callback.")
        case .deliveryFailed(let detail):
            return L10n.format("Could not deliver the sign-in callback to the backup window: %@", detail)
        }
    }
}

enum BackupProfileManager {
    static func sanitizedAppName(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Claude Backup" : String(cleaned.prefix(60))
    }

    static func uniqueFolderName(for raw: String, in profileRoot: URL) -> String {
        let stem = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let base = "Claude-" + (stem.isEmpty ? "backup" : String(stem.prefix(24)))
        let fm = FileManager.default
        if !fm.fileExists(atPath: profileRoot.appending(path: base).path) { return base }
        for index in 2...99 {
            let candidate = "\(base)-\(index)"
            if !fm.fileExists(atPath: profileRoot.appending(path: candidate).path) { return candidate }
        }
        return "Claude-\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func createProfileBundle(accountName: String, profileRoot: URL) throws -> (appURL: URL, profileDir: URL) {
        guard let launcher = Bundle.main.url(forResource: "graft-launch", withExtension: nil) else {
            throw BackupProfileError.missingLauncher
        }
        let folder = uniqueFolderName(for: accountName, in: profileRoot)
        guard Graft.validateFolder(folder) == nil else { throw BackupProfileError.invalidName }
        let profileDir = profileRoot.appending(path: folder)
        let fm = FileManager.default
        let userApps = fm.homeDirectoryForCurrentUser.appending(path: "Applications")
        try fm.createDirectory(at: userApps, withIntermediateDirectories: true)
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)

        var appName = sanitizedAppName(for: accountName)
        var targetApp = userApps.appending(path: "\(appName).app")
        if fm.fileExists(atPath: targetApp.path) {
            appName = "\(appName) Backup"
            targetApp = userApps.appending(path: "\(appName).app")
        }

        let tempRoot = fm.temporaryDirectory.appending(path: "switcher-backup-app-\(UUID().uuidString)")
        let staged = tempRoot.appending(path: targetApp.lastPathComponent)
        defer { try? fm.removeItem(at: tempRoot) }

        do {
            let macOS = staged.appending(path: "Contents/MacOS")
            let resources = staged.appending(path: "Contents/Resources")
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let execURL = macOS.appending(path: "launcher")
            try fm.copyItem(at: launcher, to: execURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

            if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
                try? fm.copyItem(at: icon, to: resources.appending(path: "icon.icns"))
            }
            let config = GraftConfig(profileDir: profileDir.path)
            try JSONEncoder().encode(config).write(to: resources.appending(path: "switcher.json"))

            let bundleID = "com.moonlitnayeem.claude-switcher.backup." + UUID().uuidString.lowercased()
            let plist: [String: Any] = [
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "launcher",
                "CFBundleIconFile": "icon",
                "CFBundleIdentifier": bundleID,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": appName,
                "CFBundleDisplayName": appName,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "NSHighResolutionCapable": true,
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try plistData.write(to: staged.appending(path: "Contents/Info.plist"))

            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", staged.path]
            try sign.run()
            sign.waitUntilExit()
            guard sign.terminationStatus == 0 else {
                throw BackupProfileError.writeFailed("codesign exited with \(sign.terminationStatus)")
            }
            if fm.fileExists(atPath: targetApp.path) {
                try fm.removeItem(at: targetApp)
            }
            try fm.moveItem(at: staged, to: targetApp)
            return (targetApp, profileDir)
        } catch let error as BackupProfileError {
            throw error
        } catch {
            throw BackupProfileError.writeFailed(error.localizedDescription)
        }
    }

    static func runningClaudePID(for profileDir: URL) -> pid_t? {
        let resolved = profileDir.resolvingSymlinksInPath().path
        let raw = profileDir.path
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,args="]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.drop(while: \.isWhitespace)
            let pidPart = trimmed.prefix(while: \.isNumber)
            guard let pid = pid_t(pidPart) else { continue }
            let cmd = String(trimmed.dropFirst(pidPart.count).drop(while: \.isWhitespace))
            guard Graft.isClaudeProcess(cmd) else { continue }
            if cmd.contains("--user-data-dir=\(resolved)") || cmd.contains("--user-data-dir=\(raw)") {
                return pid
            }
        }
        return nil
    }

    static func deliverClaudeCallback(_ url: URL, to profileDir: URL) throws {
        guard let pid = runningClaudePID(for: profileDir) else {
            throw BackupProfileError.backupNotRunning
        }
        let gurlClass: AEEventClass = 0x4755_524C // 'GURL'
        let getURLEvent: AEEventID = 0x4755_524C  // 'GURL'
        let directObject: AEKeyword = 0x2D2D_2D2D // '----'
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: gurlClass,
            eventID: getURLEvent,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: directObject)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 5)
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        } catch {
            throw BackupProfileError.deliveryFailed(error.localizedDescription)
        }
    }
}

struct BackupProfileSignInSheet: View {
    let target: BackupSignInTarget
    let onCompleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BackupSignInWebController()
    @State private var urlInput = ""
    @State private var statusMessage: String?
    @State private var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("Sign in to %@", target.accountName))
                        .font(.headline)
                    Text("Complete sign-in here so the callback goes straight to your backup Claude window without closing main Claude.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if signedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout.weight(.semibold))
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Button {
                    launchBackupWindow()
                } label: {
                    Label("1. Open Backup Window", systemImage: "macwindow.badge.plus")
                }
                .controlSize(.small)

                Button {
                    pasteLoginLink()
                } label: {
                    Label("2. Paste Login Link from Browser", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)

                TextField("https://claude.ai/… or claude://…", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { openInputURL() }

                Button("Load") { openInputURL() }
                    .controlSize(.small)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let message = statusMessage ?? browser.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BackupSignInWebView(controller: browser)
                .frame(minWidth: 640, minHeight: 430)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary, lineWidth: 1))
        }
        .padding(16)
        .frame(width: 720, height: 560)
        .onAppear {
            browser.onClaudeCallback = { callbackURL in
                deliver(callbackURL)
            }
            launchBackupWindow()
            browser.load(URL(string: "https://claude.ai/login")!)
        }
        .task {
            while !Task.isCancelled {
                let hasAccount = GraftAccountLabel.profileAccount(in: target.profileDir) != nil
                if hasAccount && !signedIn {
                    signedIn = true
                    statusMessage = L10n.text("Backup Claude window is now signed in.")
                    onCompleted()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func launchBackupWindow() {
        if BackupProfileManager.runningClaudePID(for: target.profileDir) != nil {
            statusMessage = L10n.text("Backup Claude window is running. Click Sign in there, copy the browser’s login URL, and click Paste Login Link above.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target.appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    statusMessage = error.localizedDescription
                } else {
                    statusMessage = L10n.text("Opened backup Claude window. Click Sign in there, copy the browser’s login URL, and click Paste Login Link above.")
                }
            }
        }
    }

    private func pasteLoginLink() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            statusMessage = L10n.text("Copy the login URL from your browser’s address bar first.")
            return
        }
        urlInput = raw
        openInputURL()
    }

    private func openInputURL() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            statusMessage = L10n.text("Enter a valid https:// or claude:// URL.")
            return
        }
        if scheme == "claude" {
            deliver(url)
        } else if scheme == "https" || scheme == "http" {
            statusMessage = nil
            browser.load(url)
        } else {
            statusMessage = L10n.text("Enter a valid https:// or claude:// URL.")
        }
    }

    private func deliver(_ url: URL) {
        do {
            try BackupProfileManager.deliverClaudeCallback(url, to: target.profileDir)
            statusMessage = L10n.text("Delivered sign-in callback directly to your backup Claude window.")
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

@MainActor
final class BackupSignInWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var statusMessage: String?
    var onClaudeCallback: ((URL) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "claude" {
            decisionHandler(.cancel)
            onClaudeCallback?(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.scheme?.lowercased() == "claude" {
                onClaudeCallback?(url)
            } else {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }
}

private struct BackupSignInWebView: NSViewRepresentable {
    @ObservedObject var controller: BackupSignInWebController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
