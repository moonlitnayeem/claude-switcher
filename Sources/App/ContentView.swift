import AppKit
import SwiftUI

struct ContentView: View {
    /// Stands for Claude's own profile in the sidebar, which has no shortcut.
    static let mainProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Stands for the artifacts of every signed-in account, which belong to no
    /// one profile.
    static let artifactsID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    /// Every signed-in account's projects, and one search across their chats.
    static let projectsID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let searchID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    static let routingID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    static let openAIID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    @EnvironmentObject private var store: ShortcutStore
    @State private var selection: UUID? = ContentView.routingID
    @State private var pendingDeletion: UUID?
    @State private var problem: String?
    @State private var columns = NavigationSplitViewVisibility.all

    /// Nil in the app, which shows `Shared.artifacts`; the layout suite hands
    /// in sample rows, since the real list is asked of claude.ai.
    private let artifacts: ArtifactCenter?
    private let projects: ProjectCenter?

    private let routingPreview: AnyView?
    private let brandIcon: NSImage?

    init(selection: UUID? = ContentView.routingID, artifacts: ArtifactCenter? = nil,
         projects: ProjectCenter? = nil, routingPreview: AnyView? = nil, brandIcon: NSImage? = nil) {
        _selection = State(initialValue: selection)
        self.artifacts = artifacts
        self.projects = projects
        self.routingPreview = routingPreview
        self.brandIcon = brandIcon
    }

    var body: some View {
        // A real sidebar: full height under the titlebar, in the sidebar's
        // own material, with the title and toolbar reading as one piece over
        // the detail. A notice sits inside the detail column, never above the
        // split view: below anything, the split view draws a second titlebar
        // backdrop over the first section of the form.
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top, spacing: 0) { SwitcherBrand(icon: brandIcon) }
                .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if !GraftConnection.isEnabled { UpdateRecoveryNotice() }
                profileDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            if !GraftConnection.isEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: add) {
                        Label("New Shortcut", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New shortcut")
                    .identified("new-shortcut")
                }
            }
        }
        .confirmationDialog(deletionTitle,
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Shortcut Only") { delete(alsoProfile: false) }
            Button("Delete Shortcut and Profile", role: .destructive) { delete(alsoProfile: true) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
        .alert("The shortcut was deleted", isPresented: Binding(get: { problem != nil },
                                                               set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        // Last, so the toolbar and the dialogs hanging off this view are
        // inside it too.
        .environment(\.controlSurface, ControlSurface.window)
    }

    @ViewBuilder
    private var profileDetail: some View {
        if selection == Self.routingID {
            if let routingPreview { routingPreview }
            else if GraftConnection.isEnabled { GraftConnectionView() }
            else {
                RoutingDashboard { key in
                    selection = key == UsagePoolController.mainKey ? Self.mainProfileID : UUID(uuidString: key)
                }
            }
        } else if selection == Self.openAIID {
            OpenAIAccountsView()
        } else if selection == Self.mainProfileID {
            MainProfileDetail()
        } else if selection == Self.artifactsID {
            ArtifactsView(center: artifacts ?? Shared.artifacts)
        } else if selection == Self.projectsID {
            ProjectsView(center: projects ?? Shared.projects)
        } else if selection == Self.searchID {
            ChatSearchView(center: projects ?? Shared.projects)
        } else if let selection, let index = store.shortcuts.firstIndex(where: { $0.id == selection }) {
            ShortcutDetail(shortcut: $store.shortcuts[index],
                           requestDelete: { requestDeletion(of: selection) })
                .id(selection)
        } else {
            EmptyState(hasShortcuts: !store.shortcuts.isEmpty, add: add)
        }
    }

    /// A shortcut that was never created holds nothing, so it just goes.
    private func requestDeletion(of id: UUID) {
        guard id != Self.mainProfileID, let shortcut = store.shortcut(id) else { return }
        if store.isDraft(shortcut) {
            if selection == id { selection = nil }
            store.shortcuts.removeAll { $0.id == id }
            return
        }
        pendingDeletion = id
    }

    private func delete(alsoProfile: Bool) {
        guard let pendingDeletion else { return }
        if selection == pendingDeletion { selection = nil }
        problem = store.delete(pendingDeletion, deletingProfile: alsoProfile)
        self.pendingDeletion = nil
    }

    private var deletionMessage: String {
        guard let pendingDeletion, let shortcut = store.shortcut(pendingDeletion) else { return "" }
        return L10n.format("""
            The app is removed from %@ either way.

            Its profile folder, %@, holds that account's login and chat history. \
            Deleting it cannot be undone.
            """, Installer.installDirectory.path, shortcut.folder)
    }

    private var deletionTitle: String {
        guard let pendingDeletion, let shortcut = store.shortcut(pendingDeletion) else {
            return L10n.text("Delete this shortcut?")
        }
        return L10n.format("Delete “%@”?", shortcut.name)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Switch accounts") {
                Label("Claude Desktop", systemImage: "macwindow")
                    .identified("sidebar.routing")
                    .tag(Self.routingID)
                Label("ChatGPT & Codex", systemImage: "bubble.left.and.text.bubble.right")
                    .identified("sidebar.openai")
                    .tag(Self.openAIID)
            }

            if !GraftConnection.isEnabled {
                claudeSidebarItems
            }
        }
        .onDeleteCommand { if !GraftConnection.isEnabled, let selection { requestDeletion(of: selection) } }
    }

    @ViewBuilder private var claudeSidebarItems: some View {
        Section("Claude library") {
            Label("Artifacts", systemImage: "square.on.square")
                .identified("sidebar.artifacts")
                .tag(Self.artifactsID)
            Label("Projects", systemImage: "folder")
                .identified("sidebar.projects")
                .tag(Self.projectsID)
            Label("Search Chats", systemImage: "magnifyingglass")
                .identified("sidebar.search")
                .tag(Self.searchID)
        }

        Section("Claude profiles") {
            Label("Claude", systemImage: "house")
                .spoken("Claude", value: L10n.text("Installed normally"))
                .identified("sidebar.\(Graft.mainProfile.lastPathComponent)")
                .tag(Self.mainProfileID)

            ForEach(store.shortcuts) { shortcut in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortcut.name)
                        Text(shortcut.installedName == nil
                             ? L10n.text("Not created yet")
                             : store.label(for: shortcut.source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: shortcut.source == .own ? "circle" : "link")
                        .foregroundStyle(.secondary)
                }
                .spoken(shortcut.name, value: sidebarValue(for: shortcut))
                .identified("sidebar.\(shortcut.profileDir.lastPathComponent)")
                .tag(shortcut.id)
                .contextMenu {
                    Button(L10n.text(store.isDraft(shortcut) ? "Discard" : "Delete Shortcut…"),
                           role: .destructive) {
                        requestDeletion(of: shortcut.id)
                    }
                }
            }
        }

        Button(action: add) {
            Label("New Shortcut", systemImage: "plus")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .identified("sidebar.new-shortcut")
        .padding(.vertical, 2)
    }

    /// The foot of the sidebar. There is no About panel and no preferences
    /// window worth opening, so this is the app's only standing place to say
    /// where it came from and who pays for it — the dropdown item is seen only
    /// by people who are already in the menu bar.
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            // Here rather than across the top of the window, where one line
            // about Claude's version took the full width above every profile.
            if !GraftConnection.isEnabled {
                ClaudeUpdateStatus(stacked: true)
                Divider()
            }
            HStack(spacing: 0) {
                FooterLink("Help", icon: "questionmark.circle", url: Links.support,
                           help: "Get help with AI Switcher")
                    .identified("support")
                Spacer(minLength: 8)
                FooterLink("Source", icon: "chevron.left.forwardslash.chevron.right", url: Links.source,
                           help: Links.source.absoluteString)
                    .identified("source")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    /// What the line under the name and the symbol beside it say between
    /// them, the symbol being the only thing that marks a borrowed history.
    private func sidebarValue(for shortcut: Shortcut) -> String {
        if shortcut.installedName == nil { return L10n.text("Not created yet") }
        if shortcut.source == .own { return store.label(for: .own) }
        return L10n.format("Reads chats from %@", store.label(for: shortcut.source))
    }

    /// A new Claude starts with chats of its own, since lending usage
    /// belongs to the pool now and needs no shared history; borrowing another
    /// Claude's chats is a choice made afterwards in its detail. Only here:
    /// `Shortcut`'s own default stays `.main`, which is what every list saved
    /// before this change means by a Claude with no source written down, so
    /// none of those changes what it reads.
    private func add() {
        var shortcut = Shortcut(name: store.uniqueName(), source: .own)
        // Set once, here: an existing Claude keeps the colour it has, so
        // nobody's Dock changes under them when this rule arrived.
        shortcut.iconPreset = Shortcut.IconPreset.next(besides: Shared.usagePool.coloursInUse)
        store.shortcuts.append(shortcut)
        selection = shortcut.id
    }
}

private struct EmptyState: View {
    let hasShortcuts: Bool
    let add: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(L10n.text(hasShortcuts ? "Select a shortcut" : "No shortcuts yet"))
                .font(.title3)
                .accessibilityAddTraits(.isHeader)
            Text("Each shortcut opens Claude on its own account with its own chats,\nand can borrow another account's Claude Code chats if you choose.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasShortcuts {
                Button("New Shortcut", action: add)
                    .identified("empty.new-shortcut")
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
