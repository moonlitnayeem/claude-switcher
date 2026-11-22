import AppKit
import SwiftUI

let files = FileManager.default
let fixtures = files.temporaryDirectory.appendingPathComponent("switcher-demo-\(UUID().uuidString)")
try files.createDirectory(at: fixtures, withIntermediateDirectories: true)
defer { try? files.removeItem(at: fixtures) }
Graft.applicationSupportOverride = fixtures
Installer.installDirectoryOverride = fixtures.appendingPathComponent("Applications")
Installer.registersWithLaunchServices = false
Graft.runningClaudesOverride = { [] }
Shared.usage.mayPromptUnasked = false

// The sidebar checks Claude Desktop's version on appearance. Keep that check inside the fixture.
final class FixtureUpdateResponse: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let fixtureSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureUpdateResponse.self]
    return URLSession(configuration: configuration)
}()

guard CommandLine.arguments.count == 3,
      let brandIcon = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
    fatalError("Pass the path to the bundled AppIcon.icns after the output directory.")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let demoDefaultsName = "ai-switcher-preview-" + UUID().uuidString
let demoDefaults = UserDefaults(suiteName: demoDefaultsName)!
defer { demoDefaults.removePersistentDomain(forName: demoDefaultsName) }
demoDefaults.set("Personal", forKey: "openai.firstLabel")
demoDefaults.set("Studio", forKey: "openai.secondLabel")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()

@MainActor
func capture(_ name: String, dark: Bool, compact: Bool, movie: Bool = false, openAI: Bool = false) throws {
    let frames = DemoFrames()
    let demo = movie ? AnyView(DemoRoutingSequence(frames: frames)) : AnyView(DemoDashboard(empty: compact))
    let content = ContentView(selection: openAI ? ContentView.openAIID : ContentView.routingID, routingPreview: demo, brandIcon: brandIcon)
        .defaultAppStorage(demoDefaults)
        .environmentObject(Shared.store).environmentObject(Shared.settings).environmentObject(Shared.usage)
        .environment(\.colorScheme, dark ? .dark : .light)
    let controller = NSHostingController(rootView: content)
    controller.sizingOptions = []
    if #available(macOS 14, *) { controller.sceneBridgingOptions = .all }
    let size = NSSize(width: compact ? 780 : 1000, height: compact ? 550 : 820)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "AI Switcher"
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentViewController = controller
    window.setContentSize(size)
    window.center()
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    func update(until deadline: Date) {
        while Date() < deadline {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02),
                                     inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
        }
        window.displayIfNeeded()
    }
    func record(_ url: URL) throws {
        let screenshot = Process()
        screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try screenshot.run()
        screenshot.waitUntilExit()
        guard screenshot.terminationStatus == 0,
              let image = NSImage(contentsOf: url), image.size.width >= size.width - 2 else {
            throw NSError(domain: "DashboardFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The fixture window could not be captured at its requested size."])
        }
    }
    update(until: Date(timeIntervalSinceNow: 0.42))
    if movie {
        let folder = output.appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let began = Date()
        for i in 0..<56 {
            if i == 17 { frames.step = .backup }
            if i == 38 { frames.step = .done }
            update(until: max(Date(timeIntervalSinceNow: 0.035), began.addingTimeInterval(Double(i) / 8)))
            try record(folder.appendingPathComponent(String(format: "%03d.png", i)))
        }
        print(folder.path)
    } else {
        let url = output.appendingPathComponent(name + ".png")
        try record(url)
        print(url.path)
    }
}

// Rotation is ambient. A moving dot represents a real attempt or a just-observed reply.
let tick = Date(timeIntervalSinceReferenceDate: 64)
let idle = OrbitFrame(at: tick, moving: true, signal: nil, traceBegan: nil)
let quarterTurn = OrbitFrame(at: tick.addingTimeInterval(8), moving: true, signal: nil, traceBegan: nil)
precondition(abs(quarterTurn.angle - idle.angle - .pi / 2) < 0.0001 && idle.pulse == nil && quarterTurn.pulse == nil)
let sending = RouteMapSignal(phase: .sending, backup: true, model: "Fable 5.2", at: tick)
let midRequest = OrbitFrame(at: tick.addingTimeInterval(1.2), moving: true, signal: sending, traceBegan: nil)
precondition(abs((midRequest.pulse ?? -1) - 0.5) < 0.0001)
let still = OrbitFrame(at: tick.addingTimeInterval(8), moving: false, signal: sending, traceBegan: nil)
precondition(still.angle == 0 && still.pulse == nil)
let answered = RouteMapSignal(phase: .answered, backup: true, model: nil, at: tick)
precondition(OrbitFrame(at: tick.addingTimeInterval(8), moving: true, signal: answered, traceBegan: nil).pulse == nil)

precondition(RoutingDashboard.modelName("claude-fable-5-2") == "Fable 5.2")
precondition(RoutingDashboard.modelName("claude-mythos-5-2") == "Mythos 5.2")
precondition(RoutingDashboard.modelName("custom-model") == "custom-model")
do {
    let now = Date()
    var mainOK = RoutingAccountDisplay(id: "main", name: "main@example.org", isPrimary: true, state: "Signed in",
                                       fable: RoutingUsageMetric(percent: 40, observedAt: now, source: "Graft relay"))
    let backupFull = RoutingAccountDisplay(id: "b1", name: "full@example.org", isPrimary: false, state: "Signed in",
                                           fable: RoutingUsageMetric(percent: 100, observedAt: now, source: "Graft relay"),
                                           canOpenChatProfile: true)
    let backupReady = RoutingAccountDisplay(id: "b2", name: "ready@example.org", isPrimary: false, state: "Signed in",
                                            fable: RoutingUsageMetric(percent: 70, observedAt: now, source: "Graft relay"),
                                            canOpenChatProfile: true)
    let okDisplay = RoutingDisplay(title: "Ready", detail: "", accounts: [mainOK, backupFull, backupReady])
    precondition(!okDisplay.primaryFableLimited)
    mainOK.fable = RoutingUsageMetric(percent: 100, observedAt: now, source: "Graft relay")
    let limitedDisplay = RoutingDisplay(title: "Full", detail: "", accounts: [mainOK, backupFull, backupReady])
    precondition(limitedDisplay.primaryFableLimited && limitedDisplay.preferredBackupChatProfile?.id == "b2")
    let noProfileDisplay = RoutingDisplay(title: "Full", detail: "", accounts: [
        mainOK,
        RoutingAccountDisplay(id: "b3", name: "none@example.org", isPrimary: false, state: "Signed in", canOpenChatProfile: false),
    ])
    precondition(noProfileDisplay.preferredBackupChatProfile == nil)
    precondition(RoutingUsageMetric.resetSummary(now.addingTimeInterval(2 * 3600 + 15 * 60), now: now)?.contains("2") == true)

    var feedDisplay = limitedDisplay
    feedDisplay.populateActivityFeed([
        PoolRouting(at: now.addingTimeInterval(-10), from: "main", servedBy: "main", status: 200,
                    passedOver: [], session: "s1", model: "claude-opus-5-5"),
        PoolRouting(at: now, from: "main", servedBy: "b2", status: 200,
                    passedOver: [PoolPass(id: "main", reason: .full)], session: "s1", model: "claude-fable-5-2"),
    ], canonical: { $0 }, accountName: { $0 })
    precondition(feedDisplay.recentEvents.count == 2 && feedDisplay.recentEvents.first?.isBackup == true)
    precondition(feedDisplay.replyCounts.map(\.count).reduce(0, +) == 2)

    var gemini = GeminiProfileIndex()
    precondition(gemini.available.count == 2 && gemini.selected?.id == .first)
    gemini.add("Work")
    precondition(gemini.available.count == 3 && gemini.selected?.displayName == "Work")
    let tempRoot = FileManager.default.temporaryDirectory.appending(path: "gemini-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let geminiLauncher = GeminiProfileLauncher(root: tempRoot.appending(path: "profiles"))
    let browserArgs = try geminiLauncher.browserArguments(for: .first)
    precondition(browserArgs.contains(where: { $0.hasPrefix("--user-data-dir=") }))
    let agyScript = try geminiLauncher.agyCommand(for: gemini.selected!.id, accountLabel: "work-acct",
                                                  executable: URL(fileURLWithPath: "/usr/bin/true"), project: tempRoot)
    let agyText = try String(contentsOf: agyScript, encoding: .utf8)
    precondition(agyText.contains("AGY_ACCOUNT='work-acct'"))
    let cliScript = try geminiLauncher.geminiCLICommand(for: .first,
                                                        executable: URL(fileURLWithPath: "/usr/bin/true"), project: tempRoot)
    let cliText = try String(contentsOf: cliScript, encoding: .utf8)
    precondition(cliText.contains("GEMINI_CLI_HOME="))
}
try MainActor.assumeIsolated {
    try capture("routing-light", dark: false, compact: false)
    try capture("routing-dark", dark: true, compact: false)
    try capture("routing-empty", dark: false, compact: true)
    try capture("openai-accounts", dark: false, compact: false, openAI: true)
    if ProcessInfo.processInfo.environment["SWITCHER_ROUTING_FRAMES"] == "1" {
        try capture("routing-frames", dark: true, compact: false, movie: true)
    }
}
