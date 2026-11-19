import AppKit
import Foundation
import SwiftUI

enum Links {
    static let owner = "moonlitnayeem"
    static let source = URL(string: "https://github.com/\(owner)/claude-switcher")!
    static let site = source
    static let releases = source.appendingPathComponent("releases")
    static let support = source.appendingPathComponent("issues")
    static let newIssue = support.appendingPathComponent("new")
    static let upstream = URL(string: "https://github.com/aaditya-v-more/claude-graft")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// A quiet text link for the sidebar's footer. Underlined only under the
/// pointer, because two permanently underlined words at the foot of a sidebar
/// read as an error message rather than an invitation.
struct FooterLink: View {
    let title: String
    let icon: String
    let url: URL
    let help: String

    @State private var hovering = false

    init(_ title: String, icon: String, url: URL, help: String) {
        self.title = L10n.text(title)
        self.icon = icon
        self.url = url
        self.help = L10n.text(help)
    }

    var body: some View {
        Button { Links.open(url) } label: {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .underline(hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The Help menu. SwiftUI's own offers a single item that says help isn't
/// available, which on a Mac reads as an app nobody looks after.
struct GraftHelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L10n.text("Claude Switcher Help")) { Links.open(Links.site) }
            Button(L10n.text("Download Updates…")) { Links.open(Links.releases) }
            Button(L10n.text("Report a Problem…")) { Links.open(Links.newIssue) }
            Divider()
            Button(L10n.text("View Source on GitHub")) { Links.open(Links.source) }
            Button(L10n.text("Original Claude Graft project")) { Links.open(Links.upstream) }
        }
    }
}
