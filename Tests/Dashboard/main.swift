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

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()

@MainActor
func capture(_ name: String, dark: Bool, compact: Bool) throws {
    let content = ContentView(routingPreview: AnyView(DemoDashboard(empty: compact)))
        .environmentObject(Shared.store).environmentObject(Shared.settings).environmentObject(Shared.usage)
        .environment(\.colorScheme, dark ? .dark : .light)
    let controller = NSHostingController(rootView: content)
    controller.sizingOptions = []
    if #available(macOS 14, *) { controller.sceneBridgingOptions = .all }
    let size = NSSize(width: compact ? 780 : 1000, height: compact ? 550 : 690)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Claude Switcher"
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentViewController = controller
    window.setContentSize(size)
    window.center()
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let deadline = Date(timeIntervalSinceNow: 0.45)
    while Date() < deadline {
        if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02),
                                     inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
        app.updateWindows()
    }
    window.displayIfNeeded()
    let url = output.appendingPathComponent(name + ".png")
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
    print(url.path)
}

precondition(RoutingDashboard.modelName("claude-fable-5-2") == "Fable 5.2")
precondition(RoutingDashboard.modelName("custom-model") == "custom-model")
try MainActor.assumeIsolated {
    try capture("routing-light", dark: false, compact: false)
    try capture("routing-dark", dark: true, compact: false)
    try capture("routing-empty", dark: false, compact: true)
}
